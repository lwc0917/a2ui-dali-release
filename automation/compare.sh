#!/bin/bash
# compare.sh <baseline_dir> <new_dir> <out_dir> — tools/compare.py 래퍼.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

BASE="${1:?baseline dir}"
NEW="${2:?new dir}"
OUT="${3:?out dir}"

ui_step "[compare] baseline 대비 픽셀 회귀 비교 (임계 $DIFF_THRESHOLD)"
mkdir -p "$OUT"
python3 "$ROOT/tools/compare.py" --baseline "$BASE" --new "$NEW" --out "$OUT" \
  --threshold "$DIFF_THRESHOLD" || { ui_err "compare.py 실패"; exit 1; }

n_review=$(python3 -c '
import json, sys
es = json.load(open(sys.argv[1]))
print(sum(1 for e in es if e["status"] != "PASS"))
' "$OUT/compare.json")
if [ "$n_review" -eq 0 ]; then
  ui_ok "전 샘플 PASS (변경 없음)"
else
  ui_warn "REVIEW $n_review 건 — 시각 판정 필요"
fi
exit 0
