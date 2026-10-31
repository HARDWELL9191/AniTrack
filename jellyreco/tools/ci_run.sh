#!/usr/bin/env bash
# CI helper: runs a command, and if it fails, puts its last lines in an error annotation on the run
# (so the cause shows on the run's summary page, not only in the full log).
# Usage: tools/ci_run.sh "<title>" <command> [args...]
title="$1"; shift
log="$(mktemp)"
set -o pipefail
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  tail -n 60 "$log" | python3 -c "import sys; t=sys.stdin.read().replace('%','%25').replace('\r','').replace('\n','%0A'); print('::error title=' + sys.argv[1] + ' (exit ' + sys.argv[2] + ')::' + t)" "$title" "$rc"
fi
rm -f "$log"
exit "$rc"
