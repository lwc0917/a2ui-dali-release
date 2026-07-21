#!/bin/bash
# fix.sh build|conformance|visual — Claude 코드 적응 루프.
# 원칙: Claude 는 a2ui-dali 클론의 src/ 만 수정(파일 도구만, Bash/git 금지).
#       빌드/테스트/되돌리기는 전부 오케스트레이터(이 스크립트)가 실행.
# 예산: 모드별로 독립 ($RUNDIR/.fix_attempts.<mode>). 예전엔 하나를 공유해서 빌드가 3회를
#       다 쓰면 conformance/visual 몫이 0 이 되어, 빌드는 고쳐놓고 다음 관문에서 즉시 막혔다.
#       리포트용 누적 합계는 $RUNDIR/.fix_attempts 에 계속 기록한다.
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

MODE="${1:?build|conformance|visual}"
REPO="$SRC/a2ui-dali"
RD="${RUNDIR:-$WORKSPACE}"
ATT_FILE="$RD/.fix_attempts.$MODE"     # 모드별 예산
TOTAL_FILE="$RD/.fix_attempts"         # 리포트용 누적 합계
attempts=$(cat "$ATT_FILE" 2>/dev/null || echo 0)
BUDGET="$MAX_FIX_ATTEMPTS"

case "$MODE" in
build)
  LOG="$RD/a2ui_build.log"
  TASK="컴파일이 되도록 dali-ui API 변화를 적응"
  ;;
conformance)
  LOG="$RD/conformance.log"
  TASK="conformance 테스트가 전 항목 통과하도록 렌더러 동작을 복원"
  ;;
visual)
  # 시각 회귀: 빌드도 conformance 도 통과했는데 '그림'이 달라진 경우. triage.sh 가
  # CODE(= 우리 렌더러가 새 dali-ui 에서 잘못 그림)로 분류한 샘플만 여기로 온다.
  # 1회 시도가 빌드+렌더36+비교+비전판정이라 비싸므로 기본 예산은 더 짧다.
  LOG="$RD/compare/triage.json"
  TASK="시각 회귀를 제거 — 이전 릴리스와 같은 화면이 나오도록 렌더러 코드를 새 dali-ui 에 맞게 적응"
  BUDGET="${MAX_VISUAL_FIX_ATTEMPTS:-2}"
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
  visual)
    # 오라클은 '게이트가 실제로 GREEN 이 되는가' 하나뿐이다: 재빌드 → 전수 재렌더 →
    # baseline 대비 재비교 → 비전 재판정. 모델의 "고쳤습니다" 는 아무 효력이 없고,
    # 여기서 GREEN 이 나와야만 수정이 인정된다(그리고 그 렌더가 그대로 릴리스에 실린다).
    bash "$ROOT/automation/build_a2ui.sh" build \
      && bash "$ROOT/automation/render.sh" "$RD/new" \
      && bash "$ROOT/automation/compare.sh" "$WORKSPACE/baseline" "$RD/new" "$RD/compare" \
      && [ "$(bash "$ROOT/automation/judge.sh" "$RD/compare" | tail -1)" = "GREEN" ]
    ;;
  esac
}

# visual 모드 프롬프트에 실을 증거: 어떤 샘플이 어떻게 깨졌는지 + 사람이 보는 것과 같은
# side-by-side 카드의 절대경로(Claude 가 Read 로 이미지를 직접 본다) + 그 샘플의 코퍼스 입력.
visual_evidence() {
  python3 "$ROOT/tools/visual_evidence.py" "$RD/compare" "$ROOT/corpus/jsonl"
}

while [ "$attempts" -lt "$BUDGET" ]; do
  attempts=$((attempts + 1))
  echo "$attempts" >"$ATT_FILE"
  # 리포트용 누적(모드 합계)
  cat "$RD"/.fix_attempts.* 2>/dev/null | awk 'BEGIN{s=0} {s+=$1} END{print s+0}' >"$TOTAL_FILE" || true
  ui_step "[fix] Claude 코드 적응 시도 $attempts/$BUDGET ($MODE)"

  if [ "$MODE" = "visual" ]; then
    ERRTAIL="빌드와 conformance 는 통과했지만, 이전 릴리스 대비 '화면'이 달라졌습니다.
아래 샘플들은 '업스트림 렌더링 변화'가 아니라 '우리 렌더러 코드의 버그'로 분류되었습니다.

$(visual_evidence)

각 샘플의 비교 이미지를 Read 로 직접 열어 무엇이 깨졌는지 확인한 뒤 원인을 고치세요."
  else
    ERRTAIL=$(tail -n 150 "$LOG" 2>/dev/null || echo "(로그 없음)")
  fi
  PROMPT="a2ui-dali 렌더러가 새 dali-ui (${DALI_UI_TAG:-unknown}, core/adaptor ${CORE_ADAPTOR_TAG:-unknown}) 에 대해 실패했습니다.
임무: src/ 아래 렌더러 소스만 수정해 $TASK 하세요.

규칙 (위반 시 수정이 자동 폐기됩니다):
- src/ 밖은 절대 수정 금지 — test/, examples/, CMakeLists.txt, packaging/, README, tools 등.
- 렌더링 동작·공개 API 의미를 바꾸지 말 것. 테스트/기대값을 고치는 게 아니라 코드를 표준 방식으로 적응.
- 존재가 불확실한 dali-ui 심볼을 지어내지 말 것. 설치된 실제 헤더를 Read 로 확인 가능: $PREFIX/include/dali-ui-foundation/, $PREFIX/include/dali-ui-components/
- 참고(과거 2.5.28 재편 패턴): 빌더 헤더 devel-api/builder → integration-api/builder (타입 Dali::Ui::TreeNode → Dali::Ui::Integration::TreeNode), 뷰/텍스트 헤더가 public-api/{views,types,configuration}/ 카테고리 디렉토리로 이동, fluent 체이닝 setter 가 void 반환으로 변경, Label::SetUnderline → SetTextUnderline.

- 게이트를 우회하는 어떤 시도도 금지 — 코퍼스/기준선/비교 임계값은 애초에 수정 범위 밖이고,
  화면을 비우거나 요소를 지워서 차이를 줄이는 '수정'은 빈 화면 백스톱에 걸려 거부된다.

실패 근거:
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

ui_err "fix 예산 소진 ($attempts/$BUDGET) — $MODE 미해결"
exit 1
