#!/usr/bin/env bash
# tests/fm-backend-t3.test.sh - fake-T3-server tests for the T3 Code GUI-host
# adapter (bin/backends/t3.sh) and the spawn, control, peek, and teardown paths
# that dispatch through it.
#
# The server is tests/t3-fake-server.py, a small HTTP server speaking the
# three orchestration surfaces the adapter drives with the response shapes
# observed on T3 Code v0.0.42; `t3` is a fake CLI that mints bearer tokens the
# server accepts and logs every invocation. Nothing here needs a real T3 Code
# install: the live evidence lives in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found (required by the T3 adapter tests)"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-backend-t3-tests)
FAKE="$TMP_ROOT/fake-t3"
mkdir -p "$FAKE"
: > "$FAKE/tokens"
: > "$FAKE/dispatch.log"
: > "$FAKE/http.log"
python3 "$ROOT/tests/t3-fake-server.py" "$FAKE" &
SERVER_PID=$!
stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap 'stop_server; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do
  [ -f "$FAKE/origin" ] && break
  sleep 0.1
done
[ -f "$FAKE/origin" ] || { echo "fake T3 server did not start" >&2; exit 1; }
ORIGIN=$(cat "$FAKE/origin")

# A T3 home holding only the model manifest the adapter's default-model
# fallback reads; server discovery is overridden through FM_T3_ORIGIN.
T3HOME="$TMP_ROOT/t3home"
mkdir -p "$T3HOME/userdata"
printf '{"manifest":{"providers":{"claudeAgent":{"defaults":{"chat":"claude-manifest-default"}}}}}\n' \
  > "$T3HOME/userdata/model-manifest.json"

uuid() {
  python3 -c 'import uuid; print(uuid.uuid4())'
}

# --- fake t3 CLI and treehouse -------------------------------------------------

make_t3_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/t3" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_T3_FAKE_LOG:?}"
TOKENS="${FM_T3_FAKE_TOKENS:?}"
{
  printf 't3'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-} ${2:-} ${3:-}" in
  "auth session issue")
    n=$(( $(cat "$TOKENS.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$TOKENS.count"
    tok="tok-$n-$RANDOM$RANDOM$RANDOM"
    printf '%s\n' "$tok" >> "$TOKENS"
    printf '{"sessionId":"sess-%s","token":"%s","expiresAt":"2099-01-01T00:00:00.000Z","scopes":["orchestration:read","orchestration:operate"],"method":"bearer-access-token","subject":"cli-issued-session"}\n' "$n" "$tok"
    exit 0
    ;;
  "auth session revoke")
    exit 0
    ;;
esac
exit 2
SH
  # `treehouse get --lease` creates a real linked worktree of the project the
  # spawn runs it from and prints only its path; `return --force` removes it.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_T3_FAKE_LOG:?}"
{
  printf 'treehouse'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-}" in
  get)
    POOL="${FM_FAKE_TREEHOUSE_POOL:?}"
    mkdir -p "$POOL"
    n=$(( $(ls "$POOL" | wc -l | tr -d ' ') + 1 ))
    wt="$POOL/slot-$n"
    git worktree add --quiet --detach "$wt" >/dev/null 2>&1 || exit 1
    printf '%s\n' "$wt"
    exit 0
    ;;
  return)
    shift
    [ "${1:-}" != --force ] || shift
    git worktree remove --force "${1:?}" >/dev/null 2>&1 || rm -rf "${1:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/t3" "$fb/treehouse"
  fm_test_fake_no_mistakes "$fb"
  fm_fake_exit0 "$fb" tmux
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

# t3_case <name>: a home, a fakebin, and a T3 log for one case.
t3_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$CASE_DIR/user-home"
  touch "$HOME_DIR/state/.last-watcher-beat"
  T3LOG="$CASE_DIR/t3.log"
  : > "$T3LOG"
  FB=$(make_t3_fakebin "$CASE_DIR")
  : > "$FAKE/dispatch.log"
  rm -f "$FAKE/fail-thread-create" "$FAKE/fail-session-stop" "$FAKE/fail-archive" \
    "$FAKE/on-turn-status" "$FAKE/on-interrupt-status"
}

# t3_env <cmd...>: the environment every adapter and script call shares.
# FM_T3_ORIGIN_OVERRIDE and T3CODE_HOME_OVERRIDE let one case point the adapter
# at a dead port or an empty T3 home without losing the rest of the wiring.
t3_env() {
  env FM_T3_ORIGIN="${FM_T3_ORIGIN_OVERRIDE:-$ORIGIN}" T3CODE_HOME="${T3CODE_HOME_OVERRIDE:-$T3HOME}" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    PATH="$FB:$PATH" FM_T3_FAKE_LOG="$T3LOG" FM_T3_FAKE_TOKENS="$FAKE/tokens" \
    FM_FAKE_TREEHOUSE_POOL="$CASE_DIR/pool" "$@"
}

# t3_call <fn> [args...]: run one adapter function through the dispatcher.
t3_call() {
  # shellcheck disable=SC2016  # $0 and $@ are the child shell's own positionals.
  t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3 || exit 97; "$@"' "$ROOT" "$@"
}

seed_project() {  # <id> <workspace-root> [title]
  jq --arg id "$1" --arg root "$2" --arg t "${3:-proj}" \
    '.projects[$id] = {id:$id,title:$t,workspaceRoot:$root,defaultModelSelection:null}' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

seed_thread() {  # <id> <project-id> <session-status|none> [worktree]
  jq --arg id "$1" --arg pid "$2" --arg st "$3" --arg wt "${4:-}" '
    .threads[$id] = {
      id:$id, projectId:$pid, title:"fm-seeded", modelSelection:{instanceId:"claudeAgent",model:"m"},
      runtimeMode:"full-access", interactionMode:"default", branch:null,
      worktreePath:(if $wt == "" then null else $wt end),
      messages:[], activities:[], latestTurn:null, archivedAt:null, deletedAt:null,
      session:(if $st == "none" then null else {
        threadId:$id, status:$st, providerName:"claudeAgent", providerInstanceId:"claudeAgent",
        runtimeMode:"full-access",
        activeTurnId:(if $st == "running" or $st == "starting" then "turn-1" else null end),
        lastError:null} end)}' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

set_thread() {  # <id> <jq-filter-on-thread>
  jq --arg id "$1" ".threads[\$id] |= ($2)" "$FAKE/state.json" > "$FAKE/state.json.new" \
    && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

thread_field() {  # <id> <jq-expr>
  jq -r --arg id "$1" ".threads[\$id] | $2" "$FAKE/state.json"
}

dispatch_types() {
  jq -r '.type' "$FAKE/dispatch.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

dispatch_last() {  # <type> <jq-expr>
  jq -r --arg t "$1" "select(.type == \$t) | $2" "$FAKE/dispatch.log" | tail -n 1
}

assert_no_token_leak() {  # <label> <file-or-text>...
  local label=$1 tok what
  shift
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    for what in "$@"; do
      if [ -f "$what" ]; then
        ! grep -qF -- "$tok" "$what" || fail "$label: bearer token leaked into $what"
      else
        case "$what" in *"$tok"*) fail "$label: bearer token leaked into captured output" ;; esac
      fi
    done
  done < "$FAKE/tokens"
}

# --- origin and session ---------------------------------------------------------

test_origin_requires_running_server() {
  local out status
  t3_case origin
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  out=$(env FM_T3_ORIGIN= T3CODE_HOME="$CASE_DIR/no-t3-home" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3; fm_backend_t3_origin' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "origin resolution should fail without server-runtime.json"
  assert_contains "$out" "t3 serve" "the origin refusal should tell the operator how to start the server"
  mkdir -p "$CASE_DIR/t3-home-2/userdata"
  printf '{"version":1,"pid":1,"port":3773,"origin":"%s","serviceManaged":true}\n' "$ORIGIN" \
    > "$CASE_DIR/t3-home-2/userdata/server-runtime.json"
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  out=$(env FM_T3_ORIGIN= T3CODE_HOME="$CASE_DIR/t3-home-2" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3; fm_backend_t3_origin' "$ROOT")
  [ "$out" = "$ORIGIN" ] || fail "origin should come from server-runtime.json, got '$out'"
  pass "fm_backend_t3_origin: reads the running server's origin and refuses loudly without one"
}

test_session_is_minted_once_cached_privately_and_refreshed_on_401() {
  local out hdr issues mode
  t3_case session
  seed_project "$(uuid)" "$CASE_DIR/somewhere"
  out=$(t3_call fm_backend_t3_shell) || fail "shell read should succeed with a freshly minted session"
  printf '%s' "$out" | jq -e '.projects | length >= 1' >/dev/null || fail "shell read returned no projects"
  hdr="$HOME_DIR/state/.t3-session.header"
  assert_present "$hdr" "the bearer header file should be cached under state/"
  assert_present "$HOME_DIR/state/.t3-session" "the session record should be cached under state/"
  mode=$(stat -c %a "$hdr" 2>/dev/null || stat -f %Lp "$hdr")
  [ "$mode" = 600 ] || fail "the header file must be mode 0600, got $mode"
  assert_contains "$(cat "$T3LOG")" $'t3\x1f''auth'$'\x1f''session'$'\x1f''issue'$'\x1f''--ttl'$'\x1f''1h'$'\x1f''--label'$'\x1f''firstmate:'"$HOME_DIR"$'\x1f''--json' \
    "the session should be minted with the default TTL, a home label, and --json"
  t3_call fm_backend_t3_shell >/dev/null || fail "second shell read failed"
  issues=$(grep -c $'auth\x1fsession\x1fissue' "$T3LOG")
  [ "$issues" -eq 1 ] || fail "a valid cached session should be reused, but $issues were minted"
  assert_no_token_leak "session cache" "$T3LOG" "$out" "$HOME_DIR/state/.t3-session"
  # An invalidated token (server-side revocation, restart) is re-minted once
  # and the stale session revoked.
  printf 'Authorization: Bearer stale-token\n' > "$hdr"
  t3_call fm_backend_t3_shell >/dev/null || fail "a 401 should re-mint the session and retry"
  issues=$(grep -c $'auth\x1fsession\x1fissue' "$T3LOG")
  [ "$issues" -eq 2 ] || fail "a 401 should mint exactly one replacement, got $issues mints"
  assert_contains "$(cat "$T3LOG")" $'t3\x1f''auth'$'\x1f''session'$'\x1f''revoke'$'\x1f''sess-1' \
    "the replaced session should be revoked"
  t3_call fm_backend_t3_session_release || fail "release should succeed"
  assert_absent "$hdr" "release should remove the header file"
  assert_contains "$(cat "$T3LOG")" $'revoke\x1f''sess-2' "release should revoke the live session"
  pass "fm_backend_t3 session: minted once, cached 0600 and never logged, re-minted on 401, revoked on release"
}

# --- projects, models, threads ------------------------------------------------------

test_project_ensure_matches_existing_root_or_creates() {
  local pid out root
  t3_case project
  root="$CASE_DIR/repo-a"
  mkdir -p "$root"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$root" && pwd -P)"
  out=$(t3_call fm_backend_t3_project_ensure "$root") || fail "project_ensure failed for a registered root"
  [ "$out" = "$pid" ] || fail "project_ensure should return the registered project id, got '$out'"
  [ -z "$(dispatch_types)" ] || fail "a registered root must not dispatch project.create"
  mkdir -p "$CASE_DIR/repo-b"
  out=$(t3_call fm_backend_t3_project_ensure "$CASE_DIR/repo-b") || fail "project_ensure failed for a new root"
  [ "$(dispatch_types)" = "project.create" ] || fail "an unregistered root should dispatch exactly project.create, got '$(dispatch_types)'"
  [ "$(dispatch_last project.create .projectId)" = "$out" ] || fail "project_ensure should return the id it created"
  [ "$(dispatch_last project.create .workspaceRoot)" = "$(cd "$CASE_DIR/repo-b" && pwd -P)" ] \
    || fail "project.create should carry the physical workspace root"
  [ "$(dispatch_last project.create .title)" = repo-b ] || fail "project.create should title the project by its basename"
  pass "fm_backend_t3_project_ensure: reuses the project owning the root and registers one only when none exists"
}

test_model_selection_precedence_and_harness_gate() {
  local pid out status
  t3_case model
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  out=$(t3_call fm_backend_t3_model_selection claude claude-x high "$pid") || fail "explicit model failed"
  [ "$(printf '%s' "$out" | jq -c .)" = '{"instanceId":"claudeAgent","model":"claude-x","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "explicit model and effort should shape the selection, got '$out'"
  out=$(t3_call fm_backend_t3_model_selection claude "" "" "$pid") || fail "manifest default failed"
  [ "$(printf '%s' "$out" | jq -r .model)" = claude-manifest-default ] || fail "no model and no project default should fall back to the manifest default, got '$out'"
  jq --arg id "$pid" '.projects[$id].defaultModelSelection = {instanceId:"claudeAgent",model:"claude-project-default"}' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
  out=$(t3_call fm_backend_t3_model_selection claude "" "" "$pid") || fail "project default failed"
  [ "$(printf '%s' "$out" | jq -r .model)" = claude-project-default ] || fail "the project default should beat the manifest default, got '$out'"
  out=$(t3_call fm_backend_t3_model_selection codex "" "" "$pid" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-claude harness must be refused"
  assert_contains "$out" "claude harness family only" "the harness refusal should name the supported family"
  out=$(T3CODE_HOME_OVERRIDE="$CASE_DIR/empty-t3-home" t3_call fm_backend_t3_model_selection claude "" "" "" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "no model from any source must be refused"
  assert_contains "$out" "--model" "the no-model refusal should name the flag that supplies one"
  pass "fm_backend_t3_model_selection: explicit, then project default, then manifest default; claude only"
}

test_thread_create_binds_worktree_and_reads_back() {
  local pid tid wt out status
  t3_case thread-create
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  wt="$CASE_DIR/wt"
  mkdir -p "$wt"
  tid=$(t3_call fm_backend_t3_thread_create "$pid" fm-task1 "$wt" "" '{"instanceId":"claudeAgent","model":"m"}' full-access) \
    || fail "thread_create failed"
  [ "$(dispatch_types)" = "thread.create" ] || fail "thread_create should dispatch exactly thread.create, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.create .threadId)" = "$tid" ] || fail "thread_create should return the id it minted"
  [ "$(dispatch_last thread.create .worktreePath)" = "$wt" ] || fail "thread.create should bind worktreePath"
  [ "$(dispatch_last thread.create .branch)" = null ] || fail "an empty branch should be sent as null"
  [ "$(dispatch_last thread.create .title)" = fm-task1 ] || fail "thread.create should carry the task label as title"
  [ "$(dispatch_last thread.create .runtimeMode)" = full-access ] || fail "thread.create should carry the runtime mode"
  [ "$(thread_field "$tid" .worktreePath)" = "$wt" ] || fail "the server should hold the worktree binding"
  [ "$(t3_call fm_backend_t3_current_path "$tid")" = "$wt" ] || fail "current_path should read worktreePath back"
  : > "$FAKE/fail-thread-create"
  out=$(t3_call fm_backend_t3_thread_create "$pid" fm-task2 "$wt" main '{"instanceId":"claudeAgent","model":"m"}' auto 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-create"
  [ "$status" -ne 0 ] || fail "a refused thread.create must fail the create"
  assert_contains "$out" "thread.create failed" "the create failure should name the dispatch"
  pass "fm_backend_t3_thread_create: mints the id, binds the worktree, proves it by re-read, fails closed on a refused dispatch"
}

test_runtime_mode_maps_permission_flag() {
  t3_case runtime-mode
  [ "$(t3_call fm_backend_t3_runtime_mode '--permission-mode auto')" = auto ] || fail "auto should map to T3 runtimeMode auto"
  [ "$(t3_call fm_backend_t3_runtime_mode '--dangerously-skip-permissions')" = full-access ] || fail "bypass should map to full-access"
  pass "fm_backend_t3_runtime_mode: config/claude-permission-mode maps onto T3's runtime modes"
}

# --- state reads ----------------------------------------------------------------------

test_state_reads_map_session_status() {
  local pid tid st expect_busy expect_agent expect_composer out
  t3_case state-reads
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  while IFS=' ' read -r st expect_busy expect_agent expect_composer; do
    tid=$(uuid)
    seed_thread "$tid" "$pid" "$st"
    out=$(t3_call fm_backend_t3_session_status "$tid")
    [ "$out" = "$st" ] || fail "session_status for $st read '$out'"
    out=$(t3_call fm_backend_t3_busy_state "$tid")
    [ "$out" = "$expect_busy" ] || fail "busy_state for session $st should be $expect_busy, got '$out'"
    out=$(t3_call fm_backend_t3_agent_state "$tid")
    [ "$out" = "$expect_agent" ] || fail "agent_state for session $st should be $expect_agent, got '$out'"
    out=$(t3_call fm_backend_t3_composer_state "$tid")
    [ "$out" = "$expect_composer" ] || fail "composer_state for session $st should be $expect_composer, got '$out'"
    t3_call fm_backend_t3_target_exists "$tid" || fail "a readable thread ($st) must exist"
  done <<'EOF'
starting busy alive unknown
running busy alive unknown
ready idle alive empty
stopped idle alive empty
none idle alive empty
error unknown dead unknown
EOF
  # A gone endpoint: the server answers 404 for archived and deleted threads alike.
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  [ "$(t3_call fm_backend_t3_session_status "$tid")" = missing ] || fail "an archived thread should read missing"
  [ "$(t3_call fm_backend_t3_agent_state "$tid")" = missing ] || fail "an archived thread's agent state should be missing"
  [ "$(t3_call fm_backend_t3_busy_state "$tid")" = unknown ] || fail "an archived thread's busy state should be unknown"
  [ "$(t3_call fm_backend_t3_endpoint_absence "$tid")" = gone ] || fail "an archived thread's absence should be proven gone"
  t3_call fm_backend_t3_target_exists "$tid" && fail "an archived thread must not exist"
  [ "$(t3_call fm_backend_t3_agent_state "$(uuid)")" = missing ] || fail "an unknown thread id should read missing"
  # An unreachable server is unreadable, never death.
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_agent_state "$tid")
  [ "$out" = unreadable ] || fail "an unreachable server should read unreadable, got '$out'"
  [ "$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_endpoint_absence "$tid")" = unproven ] \
    || fail "an unreachable server cannot prove absence"
  pass "fm_backend_t3 state reads: session status maps onto busy, agent, composer, and absence verdicts; 404 is gone, an unreachable server is unreadable"
}

test_capture_renders_transcript_tail_with_state_footer() {
  local pid tid out
  t3_case capture
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  set_thread "$tid" '.messages = [
      {id:"m1",role:"user",text:"first ask",createdAt:"2026-01-01T00:00:01.000Z"},
      {id:"m2",role:"assistant",text:"done",createdAt:"2026-01-01T00:00:03.000Z"}]
    | .activities = [{id:"a1",tone:"tool",kind:"tool.started",summary:"Command run started",createdAt:"2026-01-01T00:00:02.000Z"},
                     {id:"a2",tone:"info",kind:"checkpoint.captured",summary:"Checkpoint captured",createdAt:"2026-01-01T00:00:04.000Z"}]
    | .latestTurn = {turnId:"t1",state:"completed"}'
  out=$(t3_call fm_backend_t3_capture "$tid" 40) || fail "capture failed"
  [ "$out" = $'user: first ask\n[tool] Command run started\nassistant: done\n'"[t3 thread=$tid session=ready turn=completed]" ] \
    || fail "capture should render messages and tool activity in time order with a state footer, got:"$'\n'"$out"
  out=$(t3_call fm_backend_t3_capture "$tid" 2) || fail "bounded capture failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] || fail "capture should honor the line bound, got:"$'\n'"$out"
  assert_contains "$out" "[t3 thread=" "the footer should survive a bounded tail"
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  t3_call fm_backend_t3_capture "$tid" 5 >/dev/null 2>&1 && fail "capture of a gone thread must fail"
  pass "fm_backend_t3_capture: renders the transcript tail in time order with a live-state footer and fails on a gone thread"
}

# --- sends ------------------------------------------------------------------------------

test_send_text_submit_is_a_turn_start() {
  local pid tid out
  t3_case send
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "hello worker" 3 0.01 0.01)
  [ "$out" = empty ] || fail "an accepted turn.start should report empty (delivered), got '$out'"
  [ "$(dispatch_types)" = "thread.turn.start" ] || fail "send should dispatch exactly thread.turn.start, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.turn.start .message.text)" = "hello worker" ] || fail "the message text should be sent verbatim"
  [ "$(dispatch_last thread.turn.start .message.role)" = user ] || fail "the message should be a user message"
  # A busy thread still accepts a queued message (T3 delivers it mid-turn).
  set_thread "$tid" '.session.status = "running" | .session.activeTurnId = "turn-9"'
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "queued while busy" 3 0.01 0.01)
  [ "$out" = empty ] || fail "a busy thread should still accept a queued turn.start, got '$out'"
  # A gone thread is not retried.
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  : > "$FAKE/http.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "lost" 3 0.01 0.01)
  [ "$out" = send-failed ] || fail "a gone thread should report send-failed, got '$out'"
  [ "$(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log")" = 1 ] \
    || fail "a 404 must not be retried, saw $(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log") posts"
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_send_text_submit "$tid" "unreachable" 2 0.01 0.01)
  [ "$out" = send-failed ] || fail "an unreachable server should report send-failed, got '$out'"
  pass "fm_backend_t3_send_text_submit: a 2xx turn.start is delivery, a busy thread queues, a gone thread is not retried"
}

test_send_key_maps_interrupt_and_enter() {
  local pid tid out status
  t3_case keys
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" running
  t3_call fm_backend_t3_send_key "$tid" Escape || fail "Escape should dispatch an interrupt"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "Escape should dispatch thread.turn.interrupt, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the fake should model T3 stopping the session after an interrupt"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_send_key "$tid" C-c || fail "C-c should dispatch an interrupt"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "C-c should dispatch thread.turn.interrupt"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_send_key "$tid" Enter || fail "Enter should be an accepted no-op"
  [ -z "$(dispatch_types)" ] || fail "Enter must dispatch nothing"
  out=$(t3_call fm_backend_t3_send_key "$tid" C-u 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a composer clear must be refused on a thread"
  assert_contains "$out" "unsupported T3 key" "the key refusal should name the key"
  pass "fm_backend_t3_send_key: Escape and C-c interrupt the turn, Enter is a no-op, other keys refuse"
}

# --- lifecycle --------------------------------------------------------------------------

test_session_stop_and_kill_order_and_proof() {
  local pid tid out status
  t3_case lifecycle
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  t3_call fm_backend_t3_session_stop "$tid" 3 || fail "session_stop should succeed on a ready session"
  [ "$(dispatch_types)" = "thread.session.stop" ] || fail "session_stop should dispatch thread.session.stop"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the session should read stopped"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_session_stop "$tid" 3 || fail "session_stop on a stopped session should be idempotent"
  [ -z "$(dispatch_types)" ] || fail "an already-stopped session must not be stopped again"
  # A stop the server ignores is reported, never assumed.
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/fail-session-stop"
  out=$(t3_call fm_backend_t3_session_stop "$tid" 1 2>&1)
  status=$?
  rm -f "$FAKE/fail-session-stop"
  [ "$status" -ne 0 ] || fail "a session still live after the stop wait must fail"
  assert_contains "$out" "still reports a live session" "the stop failure should say the session stayed live"
  # kill: stop first, then archive, then prove the 404.
  set_thread "$tid" '.session.status = "running" | .session.activeTurnId = "turn-2"'
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_kill "$tid" || fail "kill should succeed on a live thread"
  [ "$(dispatch_types)" = "thread.session.stop thread.archive" ] || fail "kill must stop the session before archiving, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "kill should archive the thread"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_kill "$tid" || fail "kill of an already-gone thread should succeed silently"
  [ -z "$(dispatch_types)" ] || fail "an already-gone thread must dispatch nothing"
  # An archive the server accepted but did not apply is refused by the re-read.
  tid=$(uuid)
  seed_thread "$tid" "$pid" stopped
  : > "$FAKE/fail-archive"
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_kill "$tid" 2>&1)
  status=$?
  rm -f "$FAKE/fail-archive"
  [ "$status" -ne 0 ] || fail "a kill whose archive did not take must fail"
  assert_contains "$out" "still readable after thread.archive" "the refused close should name the re-read"
  [ "$(dispatch_types)" = "thread.archive" ] || fail "a stopped session needs no stop before archive, got '$(dispatch_types)'"
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_kill "$tid" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a kill against an unreachable server must not report success"
  pass "fm_backend_t3_kill: stop, then archive, then a 404 re-read; unproven closes refuse"
}

# --- dispatcher and spawn -----------------------------------------------------------

test_dispatcher_routes_t3_operations() {
  local pid tid out
  t3_case dispatcher
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" running
  # shellcheck disable=SC2016  # $0 and $1 are the child shell's own positionals.
  out=$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state t3 "$1"; printf " "; fm_backend_agent_state t3 "$1"; printf " "; fm_backend_composer_state t3 "$1"; printf " "; fm_backend_target_exists t3 "$1" && printf exists' "$ROOT" "$tid")
  [ "$out" = "busy alive unknown exists" ] || fail "dispatcher routing for a running T3 thread read '$out'"
  # shellcheck disable=SC2016  # $0 and $1 are the child shell's own positionals.
  out=$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit t3 "$1" "via dispatcher" 1 0.01 0.01' "$ROOT" "$tid")
  [ "$out" = empty ] || fail "fm_backend_send_text_submit should route to the T3 adapter, got '$out'"
  [ "$(dispatch_last thread.turn.start .message.text)" = "via dispatcher" ] || fail "the routed send should reach the server"
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  [ "$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_required_tools t3' "$ROOT")" = "t3 curl jq treehouse" ] \
    || fail "t3 should require t3, curl, jq, and treehouse"
  pass "fm-backend.sh: busy, agent, composer, existence, send, and tool requirements dispatch to the T3 adapter"
}

test_spawn_t3_end_to_end_then_control_peek_and_teardown() {
  local proj pid id=t3spawnz1 out status tid wt meta settings brief_text
  t3_case spawn
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise T3 dispatch end to end."
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=5 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --model claude-test-model --effort high \
    --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  expect_code 0 "$status" "fm-spawn.sh --backend t3 should succeed against the fake server"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.create thread.turn.start" ] \
    || fail "spawn should create the thread then start the brief turn, got '$(dispatch_types)'"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  [ -n "$tid" ] && [ -d "$wt" ] || fail "thread.create should carry a thread id and an existing worktree"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=$tid worktree=$wt" \
    "spawn output should name the thread as the window and the leased worktree"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "backend=t3" "$meta" "meta missing backend=t3"
  assert_grep "window=$tid" "$meta" "meta window should be the thread id"
  assert_grep "t3_thread_id=$tid" "$meta" "meta missing t3_thread_id"
  assert_grep "t3_project_id=$pid" "$meta" "meta missing t3_project_id"
  assert_grep "worktree=$wt" "$meta" "meta missing the leased worktree"
  assert_grep "model=claude-test-model" "$meta" "meta missing the model"
  # The thread is bound to the isolated worktree, never the project root.
  [ "$wt" != "$(cd "$proj" && pwd -P)" ] || fail "the thread was bound to the project root"
  [ "$(git -C "$wt" rev-parse --show-toplevel)" = "$(cd "$wt" && pwd -P)" ] || fail "the leased worktree is not a worktree root"
  [ "$(dispatch_last thread.create .title)" = "fm-$id" ] || fail "the thread should be titled fm-<id>"
  [ "$(dispatch_last thread.create '.modelSelection | tojson')" = '{"instanceId":"claudeAgent","model":"claude-test-model","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "thread.create should carry the spawn's model and effort"
  [ "$(dispatch_last thread.create .runtimeMode)" = full-access ] || fail "the default permission posture should map to full-access"
  [ "$(dispatch_last thread.create .branch)" = null ] || fail "a detached leased worktree should send branch null"
  # The launch brief is the first turn, encoded as a launch-brief operational input.
  brief_text=$(jq -r 'select(.type == "thread.turn.start") | .message.text' "$FAKE/dispatch.log")
  [ "$(printf '%s' "$brief_text" | "$ROOT/bin/fm-operational-input.sh" kind)" = launch-brief ] \
    || fail "the first turn should be an encoded launch-brief input"
  case "$brief_text" in
    *"Exercise T3 dispatch end to end."*) ;;
    *) fail "the first turn should carry the brief's captain intent" ;;
  esac
  case "$brief_text" in
    *"You are a crewmate"*) ;;
    *) fail "the first turn should carry the worker role contract" ;;
  esac
  # The worker settings file carries the hooks the shared claude arm writes plus
  # the environment and policies a terminal launch would have put on argv.
  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "the worker settings file should exist in the worktree"
  jq -e '.hooks.Stop[0].hooks[0].command | test("fm-busy-event.sh") and test("--source claude-hook")' "$settings" >/dev/null \
    || fail "the Stop hook should drive the busy-state writer"
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("user-prompt-submit")' "$settings" >/dev/null \
    || fail "the UserPromptSubmit hook should open the turn"
  [ "$(jq -r .env.FM_TASK_ID "$settings")" = "$id" ] || fail "settings env should mark the task"
  [ "$(jq -r .env.GOTMPDIR "$settings")" = "/tmp/fm-$id/gotmp" ] || fail "settings env should carry GOTMPDIR"
  [ "$(jq -r .env.COMPACT_ADVISER_DISABLE "$settings")" = 1 ] || fail "settings env should pin the compact-adviser switch"
  [ "$(jq -r .env.CLAUDE_CODE_SEND_FEEDBACK "$settings")" = 0 ] || fail "settings env should disable feedback drafts"
  [ "$(jq -r .feedbackDrafts "$settings")" = off ] || fail "settings should carry feedbackDrafts off"
  [ "$(jq -r .attribution.commit "$settings")" = "" ] && [ "$(jq -r .attribution.sessionUrl "$settings")" = false ] \
    || fail "settings should carry the attribution-off policy"
  grep -qxF '.claude/settings.local.json' "$(git -C "$wt" rev-parse --git-path info/exclude)" \
    || fail "the settings file should stay out of git's view"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''get'$'\x1f''--lease'$'\x1f''--lease-holder'$'\x1f'"fm-$id" \
    "the worktree should be leased non-interactively for the task"
  [ -z "$(compgen -G "/tmp/fm-$id+*" || true)" ] || fail "a T3 launch must stage no launch file"
  assert_present "$HOME_DIR/state/$id.busy-state" "the busy contract should be armed"
  assert_no_token_leak "spawn" "$out" "$meta" "$T3LOG" "$HOME_DIR/state/$id.status" "$FAKE/dispatch.log"
  pass "fm-spawn.sh --backend t3: leases the worktree, binds the thread to it, delivers the brief as the first turn, wires hooks and environment through settings"

  # fm-peek reads the rendered transcript through the dispatcher.
  out=$(t3_env "$ROOT/bin/fm-peek.sh" "$id" 400 2>&1) || fail "fm-peek should read a T3 task"$'\n'"$out"
  assert_contains "$out" "[t3 thread=$tid session=running" "fm-peek should end with the live-state footer"
  assert_contains "$out" "user: " "fm-peek should show the brief turn"
  pass "fm-peek.sh: reads a T3 task's transcript tail with its live state"

  # fm-control: interrupt is thread.turn.interrupt; exit is thread.session.stop.
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1)
  status=$?
  expect_code 0 "$status" "fm-control interrupt should succeed on T3"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "interrupt should dispatch thread.turn.interrupt, got '$(dispatch_types)'"
  assert_contains "$out" "cancel=unconfirmed" "claude has no cancel acknowledgement, so interrupt reports unconfirmed"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the fake should model T3 stopping the provider after an interrupt"
  # The fake never runs the worker's hooks, so the busy record still holds the
  # spawn's seed; exit interrupts a busy agent first, which on T3 already stops
  # the session (modelled by the fake), so a stop needs an idle record to be
  # observed as its own dispatch.
  set_thread "$tid" '.session.status = "ready"'
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$id" idle --current-gen --source fm-recovery --event test-idle >/dev/null \
    || fail "could not mark the busy record idle"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 0 "$status" "fm-control exit should succeed on a ready T3 session"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.session.stop" ] || fail "exit should dispatch thread.session.stop, got '$(dispatch_types)'"
  assert_contains "$out" "stopped" "exit should report the stop"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "exit should leave the session stopped"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=3 "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 0 "$status" "a second exit should be idempotent"$'\n'"$out"
  assert_contains "$out" "already-stopped" "a stopped session should report already-stopped"
  [ -z "$(dispatch_types)" ] || fail "an already-stopped exit must dispatch nothing"
  pass "fm-control.sh: interrupt and exit drive T3's interrupt and session stop with proven postconditions"

  # Teardown stops, archives, proves the 404, returns the lease, and revokes the session.
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/dispatch.log"
  out=$(t3_env env -u TMUX -u TMUX_PANE "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "fm-teardown should complete for a T3 task"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.session.stop thread.archive" ] || fail "teardown should stop then archive, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "teardown should archive the thread"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force'$'\x1f'"$wt" "teardown should return the leased worktree"
  assert_absent "$meta" "teardown should remove the task record"
  assert_absent "$HOME_DIR/state/.t3-session.header" "teardown of the last T3 task should release the bearer session"
  assert_contains "$(cat "$T3LOG")" $'auth\x1f''session'$'\x1f''revoke' "teardown of the last T3 task should revoke the bearer session"
  [ ! -d "$wt" ] || fail "the leased worktree should be returned"
  rm -rf "/tmp/fm-$id"
  pass "fm-teardown.sh: closes a T3 task by stop, archive, and re-read, returns the lease, and revokes the home's session"
}

test_spawn_t3_refuses_before_leasing_and_cleans_a_failed_start() {
  local proj pid id out status subhome
  t3_case spawn-refusals
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  id=t3codexz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a codex spawn on t3 must refuse"
  assert_contains "$out" "claude harness family only" "the refusal should name the supported family"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''get' "a refused harness must lease no worktree"
  [ -z "$(dispatch_types)" ] || fail "a refused harness must create no thread, got '$(dispatch_types)'"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  pass "fm-spawn.sh --backend t3: a non-claude harness is refused before any lease or thread exists"

  # A Claude account pin cannot reach a T3-launched provider, so it refuses
  # rather than record account= for a pin that did not apply. The fake claude
  # reports the ordinary login signed in, so only the T3 conflict can refuse.
  id=t3pinz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  fm_fake_exit0 "$FB" claude
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$HOME_DIR/config/claude-account" "$FB/claude"
  [ "$status" -ne 0 ] || fail "a pinned Claude spawn on t3 must refuse"$'\n'"$out"
  assert_contains "$out" "T3 Code launches the provider with its server's own login" "the refusal should name the pin conflict"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''get' "a refused pin must lease no worktree"
  [ -z "$(dispatch_types)" ] || fail "a refused pin must dispatch nothing, got '$(dispatch_types)'"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused pin must publish no record"
  pass "fm-spawn.sh --backend t3: a declared Claude account pin is refused before any lease or thread exists"

  id=t3smz1
  subhome="$CASE_DIR/subhome"
  mkdir -p "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend t3 --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn on t3 must refuse"
  assert_contains "$out" "backend=t3 does not support --secondmate" "the secondmate refusal should name the backend"
  [ -z "$(dispatch_types)" ] || fail "a refused secondmate must dispatch nothing"
  pass "fm-spawn.sh --backend t3 --secondmate: refused before any mutation"

  # A thread that never starts its session is closed and its lease returned.
  id=t3nostartz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'stopped\n' > "$FAKE/on-turn-status"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/on-turn-status"
  [ "$status" -ne 0 ] || fail "a launch whose session never starts must fail"$'\n'"$out"
  assert_contains "$out" "reported no starting or running session" "the start failure should say what was not observed"
  [ "$(dispatch_types)" = "thread.create thread.turn.start thread.archive" ] \
    || fail "a failed start should archive the thread it created, got '$(dispatch_types)'"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force' "a failed fresh start should return the leased worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a failed start should leave no task record"
  assert_grep "failed" "$HOME_DIR/state/$id.status" "a failed start should append a failed status line"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3: a thread that never starts is archived, its lease returned, and no record left"
}

test_origin_requires_running_server
test_session_is_minted_once_cached_privately_and_refreshed_on_401
test_project_ensure_matches_existing_root_or_creates
test_model_selection_precedence_and_harness_gate
test_thread_create_binds_worktree_and_reads_back
test_runtime_mode_maps_permission_flag
test_state_reads_map_session_status
test_capture_renders_transcript_tail_with_state_footer
test_send_text_submit_is_a_turn_start
test_send_key_maps_interrupt_and_enter
test_session_stop_and_kill_order_and_proof
test_dispatcher_routes_t3_operations
test_spawn_t3_end_to_end_then_control_peek_and_teardown
test_spawn_t3_refuses_before_leasing_and_cleans_a_failed_start
