#!/bin/bash
# conformance.sh — a2ui-conformance-test 실행, 전 항목 통과(N/N) 확인.
# 결과 문자열("68/68")을 $RUNDIR/conformance.txt 에 기록 (리포트/CHANGELOG 용).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

REPO="$SRC/a2ui-dali"
LOG="${RUNDIR:-$WORKSPACE}/conformance.log"

ui_step "[conformance] a2ui-conformance-test"
( . "$SETENV" && cd "$REPO" && xvfb-run -a ./bin/a2ui-conformance-test test/ ) >"$LOG" 2>&1
rc=$?

RES=$(grep -oE 'RESULTS: [0-9]+/[0-9]+ passed' "$LOG" | tail -1 || true)
PASSED=$(sed -E 's|RESULTS: ([0-9]+)/([0-9]+) passed|\1|' <<<"$RES")
TOTAL=$(sed -E 's|RESULTS: ([0-9]+)/([0-9]+) passed|\2|' <<<"$RES")

if [ $rc -eq 0 ] && [ -n "$PASSED" ] && [ "$PASSED" = "$TOTAL" ]; then
  echo "$PASSED/$TOTAL" >"${RUNDIR:-$WORKSPACE}/conformance.txt"
  ui_ok "conformance $PASSED/$TOTAL"
  exit 0
fi
ui_err "conformance 실패: rc=$rc ${RES:-결과줄 없음} (log: $LOG)"
exit 1
