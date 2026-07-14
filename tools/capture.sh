#!/bin/bash
# capture.sh — A2UI JSONL 1건을 a2ui-dali 로 렌더해 PNG 저장.
# (a2ui-dali-publish/tools/capture.sh vendored — 게이트가 클론 내용에 의존하지 않도록 고정)
#
# Usage:
#   tools/capture.sh <input.jsonl> <output.png> [width] [height] [render_wait_sec]
#
# 파이프라인: Xvfb → $A2UI_RENDERER → xwd → ffmpeg(xwd→png). 데스크톱/WM 불필요.
# 요구: 격리 스택 setenv 소싱 (DESKTOP_PREFIX, LD_LIBRARY_PATH, dali2-*),
#       A2UI_RENDERER = a2ui-basic-renderer 경로 (필수 — 이 레포엔 렌더러가 없음).
set -u

RENDERER="${A2UI_RENDERER:?A2UI_RENDERER (a2ui-basic-renderer 경로) 필요}"

IN="${1:?input jsonl required}"
OUT="${2:?output png required}"
W="${3:-480}"
H="${4:-1280}"
WAIT="${5:-5}"

if [ ! -x "$RENDERER" ]; then echo "[capture] renderer not found/executable: $RENDERER" >&2; exit 2; fi
if [ ! -f "$IN" ]; then echo "[capture] input not found: $IN" >&2; exit 2; fi
mkdir -p "$(dirname "$OUT")"

XWD="$(mktemp "${TMPDIR:-/tmp}/a2ui_cap_XXXXXX.xwd")"

# env vars are inherited by the inner shell; DISPLAY is set by xvfb-run itself.
export RENDERER IN W H WAIT XWD
xvfb-run -a -s "-screen 0 ${W}x${H}x24" bash -c '
  export DALI_WINDOW_WIDTH="$W" DALI_WINDOW_HEIGHT="$H"
  "$RENDERER" "$IN" >"${TMPDIR:-/tmp}/a2ui_render.log" 2>&1 &
  app=$!
  sleep "$WAIT"
  xwd -root -display "$DISPLAY" -out "$XWD" 2>"${TMPDIR:-/tmp}/a2ui_xwd.err"
  kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
'

if [ ! -s "$XWD" ]; then echo "[capture] xwd produced no data" >&2; exit 3; fi
ffmpeg -y -loglevel error -i "$XWD" "$OUT" || { echo "[capture] ffmpeg failed" >&2; exit 4; }
rm -f "$XWD"
[ -s "$OUT" ] && echo "[capture] OK → $OUT ($(stat -c%s "$OUT") bytes)" || { echo "[capture] PNG empty" >&2; exit 5; }
