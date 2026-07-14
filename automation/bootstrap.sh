#!/bin/bash
# bootstrap.sh — 최초 1회: 현행 릴리스 페어로 격리 스택+렌더러를 빌드해
# baseline 렌더(코퍼스 전수)와 ledger 를 시드. 릴리스는 하지 않는다.
# 멱등: 이미 baseline 이 있으면 즉시 종료.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/dali.sh"

# 현행 릴리스 좌표 (v0.11.0 기준; 필요 시 env 로 override)
: "${BOOT_DALI_UI_TAG:=v2.5.28.10837}"
: "${BOOT_CORE_ADAPTOR_TAG:=dali_2.5.29}"
: "${BOOT_A2UI_REF:=v0.11.0}"

export RUNDIR="${RUNDIR:-$WORKSPACE/runs/bootstrap-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RUNDIR"
printf 'DALI_UI_TAG=%s\nCORE_ADAPTOR_TAG=%s\n' \
  "$BOOT_DALI_UI_TAG" "$BOOT_CORE_ADAPTOR_TAG" >"$RUNDIR/.target"

fail() {
  ui_err "$1"
  bash "$ROOT/automation/report.sh" infra "bootstrap: $1" || true
  exit 1
}

if [ -f "$WORKSPACE/baseline/meta.json" ]; then
  ui_ok "baseline 이미 존재 — 부트스트랩 불필요"
  exit 0
fi

ui_step "[bootstrap] baseline 구축: a2ui-dali $BOOT_A2UI_REF @ dali-ui $BOOT_DALI_UI_TAG + $BOOT_CORE_ADAPTOR_TAG"

bash "$ROOT/automation/build_stack.sh" "$BOOT_CORE_ADAPTOR_TAG" "$BOOT_DALI_UI_TAG" \
  || fail "DALi 스택 빌드 실패"
bash "$ROOT/automation/build_a2ui.sh" checkout "$BOOT_A2UI_REF" || fail "a2ui-dali 체크아웃 실패"
bash "$ROOT/automation/build_a2ui.sh" build || fail "a2ui-dali 빌드 실패"
bash "$ROOT/automation/conformance.sh" || fail "conformance 실패 (현행 릴리스가 통과해야 baseline 신뢰 가능)"

BASE="$WORKSPACE/baseline"
rm -rf "$BASE"
mkdir -p "$BASE"
bash "$ROOT/automation/render.sh" "$BASE" || fail "baseline 렌더 실패"

N_CORPUS=$(ls "$ROOT"/corpus/jsonl/*.jsonl | wc -l)
N_PNG=$(ls "$BASE"/*.png 2>/dev/null | wc -l)
[ "$N_PNG" -eq "$N_CORPUS" ] || fail "baseline 불완전: 렌더 $N_PNG/$N_CORPUS — 전수 렌더가 되어야 기준선으로 사용 가능"

python3 -c '
import json, sys, datetime
json.dump({"dali_ui": sys.argv[2], "core_adaptor": sys.argv[3], "a2ui_version": sys.argv[4],
           "date": datetime.date.today().isoformat()},
          open(sys.argv[1], "w"), indent=1)
' "$BASE/meta.json" "$BOOT_DALI_UI_TAG" "$BOOT_CORE_ADAPTOR_TAG" "${BOOT_A2UI_REF#v}"

ledger_add "$BOOT_DALI_UI_TAG"
ui_ok "ledger 시드: $BOOT_DALI_UI_TAG"

# 리포트용: 요약 시트(자기 비교, diff 0) + 개별 렌더(new/ 로 복사해 리포트가 집게)
mkdir -p "$RUNDIR/compare" "$RUNDIR/new"
cp "$BASE"/*.png "$RUNDIR/new/"
python3 "$ROOT/tools/compare.py" --baseline "$BASE" --new "$BASE" --out "$RUNDIR/compare" \
  --threshold "$DIFF_THRESHOLD" >/dev/null || true

bash "$ROOT/automation/report.sh" bootstrap \
  "a2ui-dali $BOOT_A2UI_REF @ dali-ui $BOOT_DALI_UI_TAG · 코퍼스 $N_PNG종 렌더" || true
ui_ok "[bootstrap] 완료 — 다음 주기부터 새 dali-ui 태그를 자동 처리"
exit 0
