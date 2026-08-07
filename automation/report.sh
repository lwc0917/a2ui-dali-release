#!/bin/bash
# report.sh <outcome> [detail] — 리포트 + artifacts 생성 (no-op 외 모든 경로가 경유).
# outcome: success|dry-run|skipped|bootstrap|no-op|gate-damage|build-break|conformance|render|infra|release-push|upstream-mismatch
# 실패 outcome 이면 Claude 진단(Read 전용, best-effort)을 리포트에 포함.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/claude.sh"

OUTCOME="${1:?outcome}"
DETAIL="${2:-}"
: "${RUNDIR:=$WORKSPACE}"

ui_step "[report] 리포트 생성 ($OUTCOME)"

# 렌더는 있는데 비교가 안 돈 실패(예: render 단계 중단)면 best-effort 비교를 돌려
# '어떤 샘플이 어떻게 깨졌는지' side-by-side 카드를 리포트에 확보한다.
if [ ! -f "$RUNDIR/compare/compare.json" ] \
  && ls "$RUNDIR"/new/*.png >/dev/null 2>&1 \
  && [ -d "$WORKSPACE/baseline" ]; then
  mkdir -p "$RUNDIR/compare"
  python3 "$ROOT/tools/compare.py" --baseline "$WORKSPACE/baseline" --new "$RUNDIR/new" \
    --out "$RUNDIR/compare" --threshold "$DIFF_THRESHOLD" >/dev/null 2>&1 \
    && ui_info "best-effort 비교로 부분 렌더 이미지 확보" || true
fi

# 실패 진단 (best-effort — 실패해도 리포트는 나감)
DIAG_FILE="$RUNDIR/diagnosis.txt"
case "$OUTCOME" in
success | dry-run | skipped | bootstrap | no-op) : >"$DIAG_FILE" ;;
# 원인이 이미 확정된 실패는 LLM 진단을 부르지 않는다 — 물어볼 것이 없고, 로그에 없는 추측을
# 덧붙이면 오히려 사람이 엉뚱한 곳을 본다.
gh-release-missing)
  cat >"$DIAG_FILE" <<'DIAG'
커밋과 태그는 원격(github.com/dalihub/a2ui-dali)에 반영됐지만 GitHub 릴리스 객체 생성이
실패했습니다. 태그만 있는 버전은 Releases 탭에 나타나지 않아 사용자에게는 미릴리스로 보입니다.
조치: 이 실행의 후속 작업 버튼(GitHub 릴리스 복구)을 누르면 같은 태그에 릴리스를 만듭니다.
반복 실패하면 gh CLI 인증(github.com)과 사내 프록시의 API 차단 여부를 확인하세요.
DIAG
  ;;
*)
  PROMPT="a2ui-dali 자동 릴리스 파이프라인이 '$OUTCOME' 단계에서 실패했습니다 (detail: $DETAIL).
이 디렉토리의 로그 파일들(*.log, compare/compare.json 등)을 Read/Glob 으로 확인하고,
근본 원인과 사람이 취할 다음 조치를 한국어 2~4문장으로 요약하세요. 요약문만 출력하세요."
  claude_call "$RUNDIR" "Read Glob" "$PROMPT" >"$DIAG_FILE" 2>/dev/null \
    || echo "(자동 진단 실패 — $RUNDIR 로그를 직접 확인하세요)" >"$DIAG_FILE"
  ;;
esac

# artifacts 대상: hub 실행이면 run 디렉토리, 로컬이면 $RUNDIR/artifacts
if [ -n "${AGENTHUB_RUN_DIR:-}" ]; then
  ART="$AGENTHUB_RUN_DIR/artifacts"
else
  ART="$RUNDIR/artifacts"
fi

python3 "$ROOT/tools/build_report.py" \
  --outcome "$OUTCOME" --detail "$DETAIL" \
  --rundir "$RUNDIR" --artifacts "$ART" \
  --out "$WORKSPACE/last_report.md" --diagnosis "$DIAG_FILE" \
  || { ui_err "리포트 생성 실패"; exit 1; }

ui_ok "리포트: $WORKSPACE/last_report.md · artifacts: $ART"
