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
# shellcheck disable=SC1091
source "$ROOT/automation/lib/dali_headers.sh"

# 허용: 렌더러 소스 + '게이트가 아닌' 테스트 소스(test/ 최상위 .cpp).
FIX_ALLOWED_RE='^(src/|test/[^/]*\.cpp$)'

# 거부(허용보다 우선). test/ 를 통째로 막았더니 업스트림 API 개편이 test/ 를 건드리는 순간
# 빌드가 '영구 미수정' 상태가 됐다 — 실측 2026-07-28: dali-ui 의 GetChildViewCount/GetChildViewAt
# → GetChildCount/GetChildAt 개편에서 Claude 가 src/ 는 다 적응시켜 98% 까지 갔는데
# test/streaming-render-test.cpp 를 못 고쳐 fix 예산(3회)을 모두 소진하고 실패했다.
# 반대로 test/ 를 전부 열면 Claude 가 '게이트를 고쳐' 통과할 수 있다. 그래서 게이트만 막는다:
#   · test/conformance-test.cpp = conformance 게이트 본체
#   · test/*.jsonl              = 게이트 기대값 데이터 (conformance.sh 가 test/ 를 읽는다)
#   · test/e2e/**               = e2e 픽스처
# a2ui-streaming-render-test 는 별도 실행파일이고 conformance.sh 가 쓰지 않으므로 게이트가 아니다.
FIX_DENIED_RE='^test/(conformance-test\.cpp$|e2e/|[^/]*\.jsonl$)'

# 허용 범위 밖 또는 명시적 거부 대상인 변경/추가 파일 목록을 stdout 으로 (없으면 빈 출력)
fix_scope_violations() { # $1=repo dir
  local files
  files=$(git -C "$1" status --porcelain | awk '{print $NF}')
  [ -n "$files" ] || return 0
  {
    grep -vE "$FIX_ALLOWED_RE" <<<"$files" || true
    grep -E "$FIX_DENIED_RE" <<<"$files" || true
  } | grep -v '^$' | sort -u
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
  # 재검증이 같은 compare/ 에 덮어쓰기 때문에, 수정이 성공하면 '무엇이 깨져 있었는지'가
  # 통째로 사라진다(실측: 리포트가 '손상 0'이 되어 깨끗한 재빌드와 구분 불가). 수정 전
  # 상태를 먼저 스냅샷해 두고, 리포트가 그걸로 '무엇을 AI 가 고쳤는지'를 보고한다.
  [ -d "$RD/compare_pre_fix" ] || cp -a "$RD/compare" "$RD/compare_pre_fix" 2>/dev/null || true
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

# ── 업스트림 델타 조달 (하네스가 증거를 만들어 준다) ──────────────────────────
# 설치된 새 헤더($PREFIX/include)는 "지금 뭐가 있나" 만 알려준다. 정작 필요한 건 "직전
# 릴리스에서 뭐가 어떻게 바뀌었나" 다 — 사라진 심볼과 그 자리를 대신하는 새 심볼.
# 기준점은 baseline/meta.json 의 dali_ui(= 지금 기준선을 만든 태그)로 공짜로 얻는다.
# 실측(dali-preview): 이 델타가 없으면 모델은 '사라졌다'까지만 알고 대체 API 를 못 찾아
# 기능을 삭제하는 쪽으로 간다.
DELTA_HINT=""
prepare_upstream_delta() {
  local prev new_tag dest
  new_tag="${DALI_UI_TAG:-}"
  [ -n "$new_tag" ] || return 1
  prev="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("dali_ui",""))
except Exception: print("")' "$WORKSPACE/baseline/meta.json" 2>/dev/null)"
  [ -n "$prev" ] && [ "$prev" != "$new_tag" ] || return 1
  dest="$WORKSPACE/.dali-headers/delta-${prev}..${new_tag}"
  dali_ui_headers_delta "$prev" "$new_tag" "$dest" >/dev/null 2>&1 || return 1
  DELTA_HINT="$dest"
  ui_info "[fix] 업스트림 델타 확보: $prev → $new_tag (사라진 심볼 $(grep -c . "$dest/removed-symbols.txt" 2>/dev/null || echo 0)개 / 새 심볼 $(grep -c . "$dest/added-symbols.txt" 2>/dev/null || echo 0)개)"
}
prepare_upstream_delta || ui_info "[fix] 업스트림 델타 없음(기준선 태그 미상/네트워크) — 설치 헤더만 제공"

# visual 모드 프롬프트에 실을 증거: 어떤 샘플이 어떻게 깨졌는지 + 사람이 보는 것과 같은
# side-by-side 카드의 절대경로(Claude 가 Read 로 이미지를 직접 본다) + 그 샘플의 코퍼스 입력.
visual_evidence() {
  python3 "$ROOT/tools/visual_evidence.py" "$RD/compare" "$ROOT/corpus/jsonl"
}

# CODE 로 분류된(=고칠) 샘플들이 어느 렌더러 소스로 그려지는지 결정적으로 안내한다.
# 시각 회귀는 컴파일 에러와 달리 '어디를 고쳐야 하는지' 단서가 없다 — 그래서 모델이 엉뚱한
# 파일을 건드려 렌더가 안 바뀌었다(실측 2026-07-22). 코퍼스의 component 타입 → 레지스트리의
# 타입→소스 매핑으로, 그 샘플을 그리는 파일을 짚어준다.
visual_source_hint() {
  local names
  names="$(python3 -c '
import json, sys
try:
    t = json.load(open(sys.argv[1] + "/triage.json"))
    print(" ".join(x["name"] for x in t if isinstance(x, dict) and x.get("class") == "CODE"))
except Exception:
    try:
        v = json.load(open(sys.argv[1] + "/verdicts.json"))
        print(" ".join(x["name"] for x in v if isinstance(x, dict) and x.get("verdict") == "DAMAGED"))
    except Exception:
        print("")' "$RD/compare")"
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086
  python3 "$ROOT/tools/component_sources.py" "$SRC/a2ui-dali" "$ROOT/corpus/jsonl" $names 2>/dev/null
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

이 샘플들이 '어느 렌더러 소스로 그려지는지' 는 결정적으로 파악돼 있습니다. 추측하지 말고
아래 파일부터 Read/Grep 으로 원인을 찾으세요(정렬·간격은 컨테이너인 flex-container.cpp 가,
아이콘/이미지는 각 컴포넌트 파일이 결정합니다):

$(visual_source_hint)

각 샘플의 비교 이미지를 Read 로 직접 열어 무엇이 깨졌는지 확인하고, 위 소스에서 원인을
고치세요. 수정 후 렌더가 실제로 바뀌는지가 유일한 성공 기준입니다 — 엉뚱한 파일을 고치면
diff 가 그대로라 재검증에서 반려됩니다."
  else
    ERRTAIL=$(tail -n 150 "$LOG" 2>/dev/null || echo "(로그 없음)")
  fi
  PROMPT="a2ui-dali 렌더러가 새 dali-ui (${DALI_UI_TAG:-unknown}, core/adaptor ${CORE_ADAPTOR_TAG:-unknown}) 에 대해 실패했습니다.
임무: src/ 아래 렌더러 소스를 수정해 $TASK 하세요.

규칙 (위반 시 수정이 자동 폐기됩니다):
- 수정 가능: src/ 아래 전체, 그리고 test/ 최상위의 .cpp 중 게이트가 아닌 것(예: test/streaming-render-test.cpp).
  같은 API 개편이 그 테스트 소스도 깨뜨리면 빌드가 통째로 안 되므로 거기까지는 적응해도 된다.
- 절대 수정 금지: test/conformance-test.cpp, test/ 의 .jsonl 기대값, test/e2e/, CMakeLists.txt, packaging/, README, tools, examples 등.
  게이트 자체나 기대값을 고쳐 통과시키는 것은 적응이 아니라 부정이며 자동 폐기된다.
- 렌더링 동작·공개 API 의미를 바꾸지 말 것. 테스트/기대값을 고치는 게 아니라 코드를 표준 방식으로 적응.
- 존재가 불확실한 dali-ui 심볼을 지어내지 말 것. 설치된 실제 헤더를 Read/Grep 으로 확인 가능: $PREFIX/include/dali-ui-foundation/, $PREFIX/include/dali-ui-components/
- 업스트림이 '무엇으로 바뀌었는지' 는 여기에 있다(없으면 '(없음)'): ${DELTA_HINT:-(없음)}
    removed-symbols.txt = 직전 릴리스에 있었는데 사라진 이름(= 적응 대상)
    added-symbols.txt   = 이번에 새로 생긴 이름(= 대체 후보가 거의 항상 여기 있다)
    headers.diff        = 공개 헤더 전체 diff (새 형태를 문맥과 함께 확인)
  API 가 '없어진' 것처럼 보이면 대개 '옮겨지거나 형태가 바뀐' 것이다. removed 에서 에러 심볼을
  찾고 added 에서 짝을 찾은 뒤 헤더에서 시그니처를 확인하고 나서 코드를 쓸 것. 기능을 지워서
  컴파일을 통과시키는 것은 적응이 아니며, 렌더가 달라지면 게이트에서 거부된다.
- 참고(과거 2.5.28 재편 패턴): 빌더 헤더 devel-api/builder → integration-api/builder (타입 Dali::Ui::TreeNode → Dali::Ui::Integration::TreeNode), 뷰/텍스트 헤더가 public-api/{views,types,configuration}/ 카테고리 디렉토리로 이동, fluent 체이닝 setter 가 void 반환으로 변경, Label::SetUnderline → SetTextUnderline.

- 게이트를 우회하는 어떤 시도도 금지 — 코퍼스/기준선/비교 임계값은 애초에 수정 범위 밖이고,
  화면을 비우거나 요소를 지워서 차이를 줄이는 '수정'은 빈 화면 백스톱에 걸려 거부된다.

실패 근거:
$ERRTAIL"

  if ! claude_call "$REPO" "Read Edit Grep Glob" "$PROMPT" >/dev/null; then
    ck=$?
    if [ "$ck" = "2" ]; then
      # 일시적 인프라 실패(사용량 한도·네트워크·타임아웃)는 '수정 시도' 가 아니다.
      # 예산을 깎고 재검증까지 돌리면 (a) 20분을 헛돌고 (b) 리포트가 "AI 가 시도했으나
      # 해결 못 함" 이라고 사실과 다르게 보고한다(실측 2026-07-21: 429 session limit).
      attempts=$((attempts - 1))
      echo "$attempts" >"$ATT_FILE"
      ui_err "[fix] LLM 호출 불가(일시적) — 예산 미차감, 이번 실행은 수정 없이 중단. 사유: $(claude_failure_reason "$(cat "$WORKSPACE/claude.last.json" 2>/dev/null)")"
      exit 3   # 3 = LLM 사용 불가(재시도하면 될 일) — 1(수정 실패) 과 구분
    fi
    # claude_call 이 실패를 반환해도 Claude 는 acceptEdits 로 파일을 실시간 편집했을 수 있다
    # (실측 2026-07-22: 반환은 실패인데 flex-container.cpp 등 6개가 수정되어 26_podcast 가
    # diff 0.0 이 됐다). '수정 없이 재검증' 이라 찍으면 실제 수정을 못 한 것처럼 오보된다.
    # 편집 여부를 git 으로 직접 확인해 정확히 로깅한다 — 오라클은 어차피 아래 retry_check.
    _edited=$(git -C "$REPO" status --porcelain 2>/dev/null | grep -c '^.M\|^M\|^??' || echo 0)
    if [ "$_edited" -gt 0 ]; then
      ui_warn "claude 반환은 실패지만 파일 ${_edited}개가 실제로 편집됨 — 그 편집으로 재검증(수정 없음 아님)"
    else
      ui_warn "claude 응답을 쓸 수 없음 + 편집도 없음 — 이번 시도는 사실상 무동작"
    fi
  fi

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
