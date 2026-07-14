#!/bin/bash
# fix.sh build|conformance — Claude 코드 적응 루프.
# 원칙: Claude 는 a2ui-dali 클론의 src/ 만 수정(파일 도구만, Bash/git 금지).
#       빌드/테스트/되돌리기는 전부 오케스트레이터(이 스크립트)가 실행.
# 예산: build+conformance 합산 MAX_FIX_ATTEMPTS 회 ($RUNDIR/.fix_attempts 로 공유).
# 안티게이밍: 시도마다 diff 검사 — src/ 밖 수정(test/·CMakeLists·packaging/ 등)은 거부+되돌림.
#
# fix.sh --lib : 함수 정의만 (selftest 용)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/claude.sh"

FIX_ALLOWED_RE='^src/'

# 허용 범위 밖에서 변경/추가된 파일 목록을 stdout 으로 (없으면 빈 출력)
fix_scope_violations() { # $1=repo dir
  git -C "$1" status --porcelain | awk '{print $NF}' | grep -vE "$FIX_ALLOWED_RE" || true
}

# 범위 밖 변경 되돌리기 (tracked → checkout, untracked → 삭제)
fix_scope_revert() { # $1=repo dir, 이후 파일들
  local repo=$1 f
  shift
  for f in "$@"; do
    git -C "$repo" checkout -- "$f" 2>/dev/null || rm -f "$repo/$f"
  done
}

if [ "${1:-}" = "--lib" ]; then
  return 0 2>/dev/null || exit 0
fi

MODE="${1:?build|conformance}"
REPO="$SRC/a2ui-dali"
ATT_FILE="${RUNDIR:-$WORKSPACE}/.fix_attempts"
attempts=$(cat "$ATT_FILE" 2>/dev/null || echo 0)

case "$MODE" in
build)
  LOG="${RUNDIR:-$WORKSPACE}/a2ui_build.log"
  TASK="컴파일이 되도록 dali-ui API 변화를 적응"
  ;;
conformance)
  LOG="${RUNDIR:-$WORKSPACE}/conformance.log"
  TASK="conformance 테스트가 전 항목 통과하도록 렌더러 동작을 복원"
  ;;
*)
  ui_err "unknown mode: $MODE"
  exit 2
  ;;
esac

# 수정 후 재검증 — conformance 도 반드시 '재빌드 후' 테스트 (수정 미반영 방지)
retry_check() {
  case "$MODE" in
  build) bash "$ROOT/automation/build_a2ui.sh" build ;;
  conformance)
    bash "$ROOT/automation/build_a2ui.sh" build \
      && bash "$ROOT/automation/conformance.sh"
    ;;
  esac
}

while [ "$attempts" -lt "$MAX_FIX_ATTEMPTS" ]; do
  attempts=$((attempts + 1))
  echo "$attempts" >"$ATT_FILE"
  ui_step "[fix] Claude 코드 적응 시도 $attempts/$MAX_FIX_ATTEMPTS ($MODE)"

  ERRTAIL=$(tail -n 150 "$LOG" 2>/dev/null || echo "(로그 없음)")
  PROMPT="a2ui-dali 렌더러가 새 dali-ui (${DALI_UI_TAG:-unknown}, core/adaptor ${CORE_ADAPTOR_TAG:-unknown}) 에 대해 실패했습니다.
임무: src/ 아래 렌더러 소스만 수정해 $TASK 하세요.

규칙 (위반 시 수정이 자동 폐기됩니다):
- src/ 밖은 절대 수정 금지 — test/, examples/, CMakeLists.txt, packaging/, README, tools 등.
- 렌더링 동작·공개 API 의미를 바꾸지 말 것. 테스트/기대값을 고치는 게 아니라 코드를 표준 방식으로 적응.
- 존재가 불확실한 dali-ui 심볼을 지어내지 말 것. 설치된 실제 헤더를 Read 로 확인 가능: $PREFIX/include/dali-ui-foundation/, $PREFIX/include/dali-ui-components/
- 참고(과거 2.5.28 재편 패턴): 빌더 헤더 devel-api/builder → integration-api/builder (타입 Dali::Ui::TreeNode → Dali::Ui::Integration::TreeNode), 뷰/텍스트 헤더가 public-api/{views,types,configuration}/ 카테고리 디렉토리로 이동, fluent 체이닝 setter 가 void 반환으로 변경, Label::SetUnderline → SetTextUnderline.

실패 로그 (마지막 150줄):
$ERRTAIL"

  claude_call "$REPO" "Read Edit Grep Glob" "$PROMPT" >/dev/null \
    || ui_warn "claude 호출 실패 — 이번 시도는 수정 없이 재검증"

  bad=$(fix_scope_violations "$REPO")
  if [ -n "$bad" ]; then
    ui_warn "범위 밖 수정 거부·되돌림: $(tr '\n' ' ' <<<"$bad")"
    # shellcheck disable=SC2086
    fix_scope_revert "$REPO" $bad
  fi

  if retry_check; then
    ui_ok "$MODE 수정 성공 (시도 $attempts, 변경 파일: $(git -C "$REPO" status --porcelain | wc -l)개)"
    exit 0
  fi
done

ui_err "fix 예산 소진 ($attempts/$MAX_FIX_ATTEMPTS) — $MODE 미해결"
exit 1
