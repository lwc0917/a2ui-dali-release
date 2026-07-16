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

# ── preflight (P1-10): 렌더 파이프라인 필수 도구/폰트 확인 — 크립틱한 중도 실패 대신
#    즉시 명확히 실패/경고. (도구 부재는 하드 실패, 폰트 부재는 경고: 게이트가 빈화면을 잡음) ──
_missing=""
for _t in xvfb-run ffmpeg xwd; do command -v "$_t" >/dev/null 2>&1 || _missing+=" $_t"; done
[ -n "$_missing" ] && { ui_err "렌더 필수 도구 없음:$_missing (apt: xvfb ffmpeg x11-apps)"; exit 1; }
if command -v fc-list >/dev/null 2>&1 && ! fc-list 2>/dev/null | grep -q .; then
  ui_warn "설치된 폰트를 찾지 못함 — 텍스트가 비어 보일 수 있음 (fonts-dejavu 권장)"
fi

total=0 fail=0
for f in "$ROOT"/corpus/jsonl/*.jsonl; do
  total=$((total + 1))
  name=$(basename "$f" .jsonl)
  # 샘플 1건을 하드 타임아웃으로 감싼다 (P1-10): 멈춘 Xvfb/렌더러/xwd 가 실행 전체를 무한
  # 점유하지 못하게 — 만료(124)는 개별 렌더 실패로 처리되고 비교 단계에서 REVIEW 로 잡힌다.
  if ( . "$SETENV" && timeout -k 5 "$RENDER_SAMPLE_TIMEOUT" \
        bash "$ROOT/tools/capture.sh" "$f" "$OUTDIR/$name.png" \
        "$RENDER_W" "$RENDER_H" "$RENDER_WAIT" ) >>"$LOG" 2>&1; then
    :
  else
    rc=$?
    [ "$rc" = 124 ] && ui_warn "렌더 타임아웃(${RENDER_SAMPLE_TIMEOUT}s): $name" || ui_warn "렌더 실패: $name"
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
