#!/bin/bash
# judge.sh <compare_dir> — REVIEW 샘플을 Claude 비전으로 판정.
# '심각한 훼손'만 DAMAGED (레이아웃 붕괴/겹침/미렌더/잘림) — 미세 드리프트는 허용.
# 보수 기본값: 판정 불가(호출 실패/파싱 불가) → DAMAGED (릴리스 차단, 사람 확인).
# 산출: <compare_dir>/verdicts.json. 마지막 stdout 줄 = GREEN | RED.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/claude.sh"

CDIR="${1:?compare dir}"
COMPARE_JSON="$CDIR/compare.json"
[ -f "$COMPARE_JSON" ] || { ui_err "compare.json 없음: $CDIR"; echo RED; exit 0; }

ui_step "[judge] REVIEW 샘플 시각 판정"
mapfile -t REVIEWS < <(python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])):
    if e["status"] != "PASS":
        print(e["name"] + "\t" + e["reason"])
' "$COMPARE_JSON")

TSV="$CDIR/.verdicts.tsv"
: >"$TSV"
red=0

if [ ${#REVIEWS[@]} -eq 0 ]; then
  ui_ok "REVIEW 0건 — 판정 불필요"
else
  for row in "${REVIEWS[@]}"; do
    name=${row%%$'\t'*}
    reason=${row#*$'\t'}
    card="side/$name.side.png"
    prompt="당신은 UI 렌더링 회귀 판정자입니다. 파일 $card 를 Read 도구로 열어 보세요.
왼쪽 패널=이전 릴리스(baseline), 가운데=새 빌드(new), 오른쪽(있다면)=diff 히트맵(빨강=변경 영역).
비교 사유: $reason
새 빌드가 '심각한 훼손'인지 판정하세요.
- DAMAGED = 레이아웃 붕괴, 요소 겹침, 텍스트/이미지 미렌더, 내용 잘림, 빈 화면.
- ACCEPTABLE = 서브픽셀 안티앨리어싱, 미세한 폰트 렌더링 차이, 1~2px 위치 이동, 미세한 색 변화 등 사람 눈에 문제 없는 드리프트.
답변 형식: 첫 줄에 정확히 한 단어 DAMAGED 또는 ACCEPTABLE. 둘째 줄에 근거 한 문장(한국어)."
    verdict="DAMAGED" # 보수 기본값
    rationale="판정 실패(호출/파싱 불가) — 보수적으로 차단"
    if out=$(claude_call "$CDIR" "Read Glob" "$prompt"); then
      first=$(head -1 <<<"$out" | awk '{print $1}' | tr -cd 'A-Z')
      if [ "$first" = "DAMAGED" ] || [ "$first" = "ACCEPTABLE" ]; then
        verdict=$first
        rationale=$(sed -n '2p' <<<"$out")
        [ -n "$rationale" ] || rationale="(근거 없음)"
      fi
    fi
    if [ "$verdict" = "DAMAGED" ]; then
      red=1
      ui_warn "$name → DAMAGED: $rationale"
    else
      ui_ok "$name → ACCEPTABLE: $rationale"
    fi
    printf '%s\t%s\t%s\n' "$name" "$verdict" "$rationale" >>"$TSV"
  done
fi

python3 -c '
import json, sys
rows = []
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2:
        rows.append({"name": parts[0], "verdict": parts[1],
                     "rationale": parts[2] if len(parts) > 2 else ""})
json.dump(rows, open(sys.argv[2], "w"), indent=1, ensure_ascii=False)
' "$TSV" "$CDIR/verdicts.json"

if [ "$red" -eq 1 ]; then echo RED; else echo GREEN; fi
