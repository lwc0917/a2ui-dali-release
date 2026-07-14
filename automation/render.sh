#!/bin/bash
# render.sh <outdir> — vendored 코퍼스 전체를 격리 스택으로 렌더 (Xvfb, 결정론).
# 개별 실패는 경고(비교 단계에서 REVIEW 로 잡힘), 전부 실패면 비-0.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

OUTDIR="${1:?output dir}"
mkdir -p "$OUTDIR"
LOG="${RUNDIR:-$WORKSPACE}/render.log"
export A2UI_RENDERER="$SRC/a2ui-dali/bin/a2ui-basic-renderer"

ui_step "[render] 코퍼스 ${RENDER_W}x${RENDER_H} 렌더 → $OUTDIR (log: $LOG)"
[ -x "$A2UI_RENDERER" ] || { ui_err "렌더러 없음: $A2UI_RENDERER"; exit 1; }

total=0 fail=0
for f in "$ROOT"/corpus/jsonl/*.jsonl; do
  total=$((total + 1))
  name=$(basename "$f" .jsonl)
  if ( . "$SETENV" && bash "$ROOT/tools/capture.sh" "$f" "$OUTDIR/$name.png" \
        "$RENDER_W" "$RENDER_H" "$RENDER_WAIT" ) >>"$LOG" 2>&1; then
    :
  else
    ui_warn "렌더 실패: $name"
    fail=$((fail + 1))
  fi
done

ui_info "렌더 $((total - fail))/$total 성공"
if [ "$fail" -eq "$total" ]; then
  ui_err "모든 샘플 렌더 실패"
  exit 1
fi
[ "$fail" -eq 0 ] && ui_ok "전 샘플 렌더 완료"
exit 0
