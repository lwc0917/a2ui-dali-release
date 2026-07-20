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

# 렌더러는 이미지/아이콘/마스크를 **상대경로 `res/`** 로 연다
# (basic-renderer main.cpp: SetImageDir("res/")). 즉 에셋 해석 기준이 프로세스 CWD 다.
# 호출자의 CWD 에서 그냥 실행하면 res/ 를 못 찾아도 렌더는 "성공"하고 이미지 자리만
# 회색 플레이스홀더로 남는다 — 로그도 게이트도 못 잡는 조용한 손상(실측: 로컬 에셋을
# 쓰는 12/36 샘플의 사진·아이콘·알파마스크가 전부 유실). 그래서 렌더러 레포 루트
# (= bin/ 의 부모)로 옮겨서 실행한다. conformance.sh 가 이미 같은 이유로 cd 한다.
RENDER_CWD="$(cd "$(dirname "$RENDERER")/.." && pwd)"
[ -d "$RENDER_CWD/res" ] || echo "[capture] WARN: $RENDER_CWD/res 없음 — 이미지가 빈 채로 렌더될 수 있음" >&2
# cd 이후에도 유효하도록 입출력을 먼저 절대경로로 고정.
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

XWD="$(mktemp "${TMPDIR:-/tmp}/a2ui_cap_XXXXXX.xwd")"
# 렌더러 stderr 은 샘플별로 남긴다 (예전엔 한 파일을 매 샘플이 덮어써서, 마지막 샘플
# 것만 남고 "이미지 로드 실패" 같은 증거가 통째로 사라졌다).
RENDER_LOG="${TMPDIR:-/tmp}/a2ui_render_$(basename "${OUT%.png}").log"

# env vars are inherited by the inner shell; DISPLAY is set by xvfb-run itself.
export RENDERER IN W H WAIT XWD RENDER_CWD RENDER_LOG
xvfb-run -a -s "-screen 0 ${W}x${H}x24" bash -c '
  export DALI_WINDOW_WIDTH="$W" DALI_WINDOW_HEIGHT="$H"
  cd "$RENDER_CWD" || exit 6
  "$RENDERER" "$IN" >"$RENDER_LOG" 2>&1 &
  app=$!
  sleep "$WAIT"
  xwd -root -display "$DISPLAY" -out "$XWD" 2>"${TMPDIR:-/tmp}/a2ui_xwd.err"
  kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
'

if [ ! -s "$XWD" ]; then echo "[capture] xwd produced no data" >&2; exit 3; fi
ffmpeg -y -loglevel error -i "$XWD" "$OUT" || { echo "[capture] ffmpeg failed" >&2; exit 4; }
rm -f "$XWD"
[ -s "$OUT" ] && echo "[capture] OK → $OUT ($(stat -c%s "$OUT") bytes)" || { echo "[capture] PNG empty" >&2; exit 5; }
