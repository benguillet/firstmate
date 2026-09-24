# T3 Code backend: live lab evidence (branch fm/t3-worker-backend @ 3f730b9)

Lab: a throwaway `t3 v0.0.42 serve --base-dir /tmp/fm-t3-lab-1s10/t3home --port 3791` (never the operator's
server on :3773), a scratch FM_HOME, a scratch HOME (so Treehouse pools stay in the lab), scratch git origins,
Claude Code 2.1.281 as T3's claudeAgent provider on claude-haiku-4-5, Treehouse v2.3.0.
The fleet scripts ran with FM_GATE_REFUSE_BYPASS=1 (the repo's own sandbox-fleet escape hatch, tests/lib.sh)
because the gate environment sets NO_MISTAKES_GATE. The lab was deleted afterwards.

| File | Scenario |
| --- | --- |
| s1-spawn.txt, s1-thread-binding.txt | spawn registers the repo's T3 project and a fm-<id> thread bound to the leased worktree; provider cwd = worktree |
| s2-status-peek-state.txt | hooks/env in settings.local.json, busy-state via claude hooks, fm-peek transcript |
| s3-steer.txt | fm-send steer -> inbox record -> doorbell turn -> worker acts, moves record to handled/ |
| s4-interrupt.txt | fm-control interrupt during a foreground `sleep 45` turn; the sleep never finished |
| s5-relaunch-exit.txt | fm-control relaunch (same thread, new spawn_gen), exit, exit again |
| s6-teardown.txt | teardown: thread already 404 when `treehouse return` ran; record gone; slot available; session revoked |
| s7-project-reuse-spawn.txt | captain registered the repo from another clone; the thread lands in that project; worker commits in its worktree |
| s8-teardown-server-down.txt | teardown --force with the T3 server stopped refuses: no return, record and lease kept; after restart it completes |
| s9-spawn-preflight-refusals.txt | codex harness, account pin, unreachable server, --secondmate: refused before any lease/thread/record |
| s10-send-accepted-pending.txt | accepted turn whose landing read fails: exit 3 "delivered, unconfirmed" (pre-fix: exit 1) |
| s11-prefix-teardown-comparison.txt | comparison only: pre-fix teardown (1d372d9) returned the slot while the thread stayed open and bound to it |
| s12-spawn-brief-refused.txt | brief turn refused: thread archived (404), then lease returned, no record |
| s13-spawn-unproven-close.txt | thread unreadable after create: lease and this task's claim kept, warning names both |
| lab-fault-proxy.py, lab-treehouse-logging-wrapper.sh | the lab's fault-injection proxy and treehouse call logger |
