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
# 에셋 부재는 하드 실패 — 에셋이 없어도 렌더는 "성공"으로 끝나고 이미지·아이콘·알파마스크만
# 조용히 회색 플레이스홀더가 된다. 게이트는 prev vs new 델타라 '양쪽 다 똑같이 빠진' 손상을
# 구조적으로 못 잡으므로(둘 다 플레이스홀더 → diff 0 → PASS), 렌더 전에 절대검증한다.
RENDER_RES_DIR="$(cd "$(dirname "$A2UI_RENDERER")/.." && pwd)/res"
[ -d "$RENDER_RES_DIR" ] || { ui_err "렌더 에셋 루트 없음: $RENDER_RES_DIR — 이미지가 전부 빈 채로 렌더된다"; exit 1; }
# 코퍼스가 참조하지만 렌더러 레포(매 실행 새로 clone)에는 없는 이미지를, 우리 레포에 vendored
# 해 둔 corpus/sample-images 에서 채운다. 렌더러 레포는 sample-images 를 15개만 추적하는데
# 코퍼스는 16개를 참조한다(30_live-invitation-builder 의 원래 unsplash 이미지를 로컬화한 것).
# 이게 없으면 그 샘플만 회색 플레이스홀더로 렌더되어 게이트가 비결정적이 된다(실측 2026-07-22).
if [ -d "$ROOT/corpus/sample-images" ]; then
  mkdir -p "$RENDER_RES_DIR/sample-images"
  for _img in "$ROOT/corpus/sample-images"/*; do
    [ -e "$_img" ] || continue
    _b="$(basename "$_img")"
    [ -f "$RENDER_RES_DIR/sample-images/$_b" ] || cp "$_img" "$RENDER_RES_DIR/sample-images/$_b"
  done
fi
_missing_assets=$(grep -ohE '[A-Za-z0-9_./-]*sample-images/[A-Za-z0-9_.-]+\.(jpg|jpeg|png|webp)' \
  "$ROOT"/corpus/jsonl/*.jsonl 2>/dev/null | sed 's#^.*sample-images/#sample-images/#' | sort -u |
  while read -r _rel; do [ -f "$RENDER_RES_DIR/$_rel" ] || echo "$_rel"; done)
if [ -n "$_missing_assets" ]; then
  ui_err "코퍼스가 참조하는 로컬 에셋 누락 (기준: $RENDER_RES_DIR):"
  echo "$_missing_assets" | while read -r _m; do ui_err "  - $_m"; done
  exit 1
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
