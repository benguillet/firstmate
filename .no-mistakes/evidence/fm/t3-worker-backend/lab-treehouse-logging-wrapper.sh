#!/usr/bin/env bash
# lab observer: log each treehouse call and, for return, the watched T3 thread's HTTP status at that instant
LOG=/tmp/fm-t3-lab-1s10/treehouse-calls.log
line="$(date +%T.%N | cut -c1-12) treehouse $*"
case " $* " in
  *" return "*) if [ -n "${LAB_WATCH_THREAD:-}" ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' -H @/tmp/fm-t3-lab-1s10/observer.header "http://127.0.0.1:3791/api/orchestration/threads/$LAB_WATCH_THREAD")
      line="$line   [T3 GET thread $LAB_WATCH_THREAD -> HTTP $code]"; fi ;;
esac
echo "$line" >> "$LOG"
exec /home/ubuntu/.local/bin/treehouse "$@"
