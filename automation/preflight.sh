#!/bin/bash
# preflight.sh — 실행 전에 '이 머신에 무엇이 있고, 없으면 무엇이 안 되는지' 를 명시적으로 점검.
#
# 왜 (2026-07-21, 서버 이전 대비): 이 에이전트는 DALi 스택과 a2ui 소스를 스스로 클론하지만,
# 클론으로 따라오지 않는 것들이 있다 — .env(자격증명/리모트 override), 렌더 도구, Claude 인증.
# 없으면 지금까지는 한참 빌드한 뒤 렌더/판정 단계에서 깨졌다. 시작 전에 한 번에 알려준다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

MISSING=0
req() { if [ "$2" = "0" ]; then ui_ok "  [필수] $1"; else ui_err "  [필수] $1 — 없음: $3"; MISSING=1; fi; }
opt() { if [ "$2" = "0" ]; then ui_ok "  [권장] $1"; else ui_warn "  [권장] $1 — 없음: $3"; fi; }
have() { command -v "$1" >/dev/null 2>&1 && echo 0 || echo 1; }

ui_step "[preflight] 실행 환경 점검"
req "git" "$(have git)" "dali-core/adaptor/ui·a2ui 소스를 가져올 수 없다"
req "네트워크(dali-ui 레포 도달)" \
    "$(timeout 20 git ls-remote "$DALI_UI_REPO" HEAD >/dev/null 2>&1 && echo 0 || echo 1)" \
    "새 dali-ui 태그 감지 및 스택 소스 취득 불가"
# core/adaptor 는 dali-ui 와 다른 호스트/프로토콜(gerrit git://)이라 따로 확인한다 — 한쪽만
# 되는 망이 실재한다(사내: github 대형 클론 불가 / 일부 망: git:// 차단). 폴백이 있으면
# 한쪽만 살아도 진행되므로, 둘 다 죽었을 때만 필수 실패로 본다.
req "네트워크(dali-core 소스 도달: 1순위 또는 폴백)" \
    "$( { timeout 20 git ls-remote "$DALI_CORE_REPO" HEAD >/dev/null 2>&1 \
         || { [ -n "${DALI_CORE_REPO_FALLBACK:-}" ] \
              && timeout 20 git ls-remote "$DALI_CORE_REPO_FALLBACK" HEAD >/dev/null 2>&1; }; } \
       && echo 0 || echo 1)" \
    "격리 DALi 스택 소스를 가져올 수 없어 빌드가 시작조차 못 한다"
req "빌드 도구(cmake/g++/make)" \
    "$([ "$(have cmake)" = 0 ] && [ "$(have g++)" = 0 ] && [ "$(have make)" = 0 ] && echo 0 || echo 1)" \
    "격리 DALi 스택과 a2ui 렌더러를 빌드할 수 없다"
req "렌더 도구(xvfb-run/ffmpeg/xwd)" \
    "$([ "$(have xvfb-run)" = 0 ] && [ "$(have ffmpeg)" = 0 ] && [ "$(have xwd)" = 0 ] && echo 0 || echo 1)" \
    "코퍼스를 렌더할 수 없어 시각 게이트 자체가 성립하지 않는다 (apt: xvfb ffmpeg x11-apps)"
req "python3 + Pillow(픽셀 비교)" \
    "$(python3 -c 'import PIL' 2>/dev/null && echo 0 || echo 1)" \
    "baseline 대비 픽셀 비교 불가 → 게이트 없음"
req "claude CLI" "$(have claude)" \
    "시각 판정이 fail-closed 로 DAMAGED 처리되어 릴리스가 항상 차단된다(코드 적응도 불가)"
# NOTE: 파이프 금지 — `fc-list | grep -q .` 는 grep 이 첫 줄에서 즉시 끝내며 fc-list 가
# SIGPIPE(141) 로 죽고, 이 스크립트의 `set -o pipefail` 이 그 141 을 파이프라인 상태로
# 올려 "폰트 없음" 오보가 된다(폰트가 많을수록 100% 재현). 출력을 그냥 담아서 판정한다.
opt "설치된 폰트" "$([ -n "$(fc-list 2>/dev/null)" ] && echo 0 || echo 1)" \
    "텍스트가 비어 렌더될 수 있다 (apt: fonts-dejavu)"
opt "릴리스 리모트 접근($A2UI_GIT_REMOTE)" \
    "$(timeout 20 git ls-remote "$A2UI_GIT_REMOTE" HEAD >/dev/null 2>&1 && echo 0 || echo 1)" \
    "게이트를 통과해도 릴리스 push 에서 실패한다(읽기 전용/자격증명 없음)"

# 코퍼스가 결정적으로 렌더 가능한가 — 로컬화되지 않은 원격 이미지 URL 이 남아 있으면 그 샘플만
# 회색 플레이스홀더로 렌더돼 게이트가 비결정적이 된다(필수는 아니고 경고: vendored 이미지가
# 있으면 render.sh 가 채운다). 무엇이 원격인지 알려준다.
if [ -f "$ROOT/tools/check_corpus_assets.py" ]; then
  if python3 "$ROOT/tools/check_corpus_assets.py" "$ROOT/corpus/jsonl" >/dev/null 2>&1; then
    ui_ok "  [권장] 코퍼스 이미지 전부 로컬(결정적 렌더)"
  else
    ui_warn "  [권장] 코퍼스에 원격 이미지 URL 잔존 — 게이트가 비결정적일 수 있다:"
    python3 "$ROOT/tools/check_corpus_assets.py" "$ROOT/corpus/jsonl" 2>&1 | grep -E "jsonl:" | while read -r _l; do ui_warn "    $_l"; done
  fi
fi

if [ "$MISSING" != "0" ]; then
  ui_err "[preflight] 필수 항목 누락 — 실행을 시작하지 않는다."
  exit 1
fi
ui_ok "[preflight] 필수 항목 충족"
exit 0
