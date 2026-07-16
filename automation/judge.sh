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

# 게이트 강도별 판정 기준 (gate_level run 입력 → GATE_LEVEL)
case "$GATE_LEVEL" in
strict)
  CRITERIA="- DAMAGED = 사람 눈에 띄는 모든 변화: 레이아웃/크기/위치/정렬 변화, 요소 이동, 폰트 굵기 변화 등.
- ACCEPTABLE = 서브픽셀 안티앨리어싱 노이즈처럼 확대해야 보이는 차이만."
  ;;
lenient)
  CRITERIA="- DAMAGED = 치명 파손만: 빈 화면, 텍스트/이미지 전면 미렌더, 요소가 겹쳐 내용을 읽을 수 없는 수준, 카드 밖으로 내용 이탈.
- ACCEPTABLE = 그 외 전부 — 크기/위치/정렬 드리프트, 색·폰트 차이는 내용이 온전하면 허용."
  ;;
*)
  CRITERIA="- DAMAGED = 레이아웃 붕괴, 요소 겹침, 텍스트/이미지 미렌더, 내용 잘림, 빈 화면.
- ACCEPTABLE = 서브픽셀 안티앨리어싱, 미세한 폰트 렌더링 차이, 1~2px 위치 이동, 미세한 색 변화 등 사람 눈에 문제 없는 드리프트."
  ;;
esac

ui_step "[judge] REVIEW 샘플 시각 판정 (강도: $GATE_LEVEL)"
# compare.json 파싱을 프로세스치환 '밖'에서 수행해 python 의 비-0 exit 를 반드시 포착한다.
# (실측 fail-open 버그: mapfile < <(python) 은 프로세스치환의 실패 exit 를 못 봐서
#  손상/절단된 compare.json 을 'REVIEW 0건'→GREEN 으로 오인 → 판정 없이 릴리스.)
# 파싱 실패 / 빈 목록 / 형식 위반 → 보수적으로 RED (설계 원칙: 판정 불가 = 차단).
if ! REVIEW_TSV=$(python3 - "$COMPARE_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (json.JSONDecodeError, OSError):
    sys.exit(2)                       # 손상/절단/읽기불가
if not isinstance(data, list) or not data:
    sys.exit(3)                       # 빈 목록/비-list = 비정상 비교(정상 run 은 36건)
for e in data:
    if not isinstance(e, dict) or "status" not in e or "name" not in e:
        sys.exit(4)                   # 형식 위반
    if e["status"] != "PASS":
        print(e["name"] + "\t" + e.get("reason", ""))
PY
); then
  ui_err "compare.json 파싱/검증 실패 — 보수적으로 RED (판정 불가 = 차단)"
  echo RED
  exit 0
fi
REVIEWS=()
[ -n "$REVIEW_TSV" ] && mapfile -t REVIEWS <<<"$REVIEW_TSV"

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
아래 기준으로 새 빌드를 판정하세요 (게이트 강도: $GATE_LEVEL).
$CRITERIA
답변 형식: 첫 줄에 정확히 한 단어 DAMAGED 또는 ACCEPTABLE. 둘째 줄에 근거 한 문장(한국어)."
    # 보수적 다수결(fail-closed 강화): JUDGE_VOTES 번 판정해 '하나라도 DAMAGED(또는 판정
    # 불가)' 면 DAMAGED — 단일 오판(ACCEPTABLE 새는 것)을 줄인다. DAMAGED 가 나오면 즉시
    # 중단(비용 절약). JUDGE_VOTES=1(기본)은 기존 단일 판정과 동일 동작·비용.
    verdict="ACCEPTABLE"
    rationale="(근거 없음)"
    votes=0
    for ((vi = 1; vi <= ${JUDGE_VOTES:-1}; vi++)); do
      v="DAMAGED" # 보수 기본값(호출/파싱 실패 시)
      r="판정 실패(호출/파싱 불가) — 보수적으로 차단"
      if out=$(claude_call "$CDIR" "Read Glob" "$prompt"); then
        first=$(head -1 <<<"$out" | awk '{print $1}' | tr -cd 'A-Z')
        if [ "$first" = "DAMAGED" ] || [ "$first" = "ACCEPTABLE" ]; then
          v=$first
          r=$(sed -n '2p' <<<"$out")
          [ -n "$r" ] || r="(근거 없음)"
        fi
      fi
      votes=$((votes + 1))
      rationale="$r"
      if [ "$v" = "DAMAGED" ]; then
        verdict="DAMAGED"
        break # 하나라도 DAMAGED 면 확정 — 나머지 투표 불필요
      fi
    done
    if [ "$verdict" = "DAMAGED" ]; then
      red=1
      ui_warn "$name → DAMAGED (${votes}/${JUDGE_VOTES:-1}표): $rationale"
    else
      ui_ok "$name → ACCEPTABLE (${votes}표 만장일치): $rationale"
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
