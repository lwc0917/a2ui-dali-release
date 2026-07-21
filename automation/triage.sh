#!/bin/bash
# triage.sh <compare_dir> — 게이트 RED 의 '원인'을 분류한다.
#
#   CODE     = 새 빌드가 잘못 그렸다 (요소 누락·겹침·잘림·빈 화면 …). 새 dali-ui 에 렌더러
#              코드가 맞지 않아 생긴 버그 → AI 가 src/ 를 고쳐야 할 문제.
#   UPSTREAM = 새 빌드도 정상적으로 그렸는데 플랫폼 렌더링 자체가 바뀌었다 (글자 래스터라이즈,
#              자간, 안티앨리어싱 …) → 코드 문제가 아니라 '골든(기준선)을 갱신할까' 하는
#              사람의 결정.
#
# 이 둘을 섞으면 두 가지 사고가 난다: 코드 버그를 사람에게 "이걸 새 기준으로 승인할래?" 라고
# 물어 깨진 화면이 기준선이 되거나, 반대로 정당한 업스트림 변화에 AI 가 코드를 뜯어고치려
# 든다. 그래서 판정(DAMAGED 여부)과 원인 분류를 분리한다.
#
# 산출: <compare_dir>/triage.json  [{name, class, source, rationale}]
#       마지막 stdout 줄 = CODE | UPSTREAM | NONE
#
# 보수 기본값: 분류 불가(호출/파싱 실패, 알 수 없는 답) → CODE.
#   CODE 로 잘못 보내면 최악이 "AI 가 못 고쳐서 사람에게 넘어감"(릴리스는 여전히 차단)인 반면,
#   UPSTREAM 으로 잘못 보내면 사람에게 깨진 렌더를 골든으로 승인하라고 권하는 꼴이 된다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/claude.sh"

CDIR="${1:?compare dir}"
COMPARE_JSON="$CDIR/compare.json"
VERDICTS_JSON="$CDIR/verdicts.json"
OUT="$CDIR/triage.json"

# 모델을 부르기 전에 걸리는 결정적 백스톱 — 이 사유들은 '정상적으로 그린 결과'일 수가 없다.
# (렌더 산출물 자체가 없음 / 캔버스 크기가 바뀜 / 화면이 거의 균일 = 빈 화면 / 전역 차이가
#  구조 훼손 수준). 실측 기준: AA 노이즈의 patch-max ≤ 2.52, 카드 전체가 비면 전역 4.13.
: "${VISUAL_STRUCTURAL_DIFF:=2.0}"

if [ ! -f "$COMPARE_JSON" ] || [ ! -f "$VERDICTS_JSON" ]; then
  ui_err "triage 입력 없음 (compare.json/verdicts.json) — 보수적으로 CODE"
  printf '[]\n' >"$OUT"
  echo CODE
  exit 0
fi

# DAMAGED 샘플만: name<TAB>pixel_reason<TAB>vision_rationale<TAB>det_class
# det_class: CODE(결정적 백스톱에 걸림) 또는 빈 문자열(모델 분류 필요)
if ! ROWS=$(python3 - "$COMPARE_JSON" "$VERDICTS_JSON" "$VISUAL_STRUCTURAL_DIFF" <<'PY'
import json, sys
cmp_path, ver_path, struct_diff = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    entries = json.load(open(cmp_path))
    verdicts = json.load(open(ver_path))
except (json.JSONDecodeError, OSError):
    sys.exit(2)
if not isinstance(entries, list) or not isinstance(verdicts, list):
    sys.exit(3)
by_name = {e.get("name"): e for e in entries if isinstance(e, dict)}
for v in verdicts:
    if not isinstance(v, dict) or v.get("verdict") != "DAMAGED":
        continue
    name = v.get("name", "")
    e = by_name.get(name, {})
    reason = str(e.get("reason", ""))
    diff = e.get("diff")
    det = ""
    if reason.startswith("새 렌더 없음") or reason.startswith("크기 불일치") or "빈 화면" in reason:
        det = "CODE"
    elif isinstance(diff, (int, float)) and diff >= struct_diff:
        det = "CODE"
    print("\t".join([name, reason, str(v.get("rationale", "")), det]))
PY
); then
  ui_err "triage 입력 파싱 실패 — 보수적으로 CODE"
  printf '[]\n' >"$OUT"
  echo CODE
  exit 0
fi

if [ -z "$ROWS" ]; then
  ui_ok "DAMAGED 샘플 없음 — 분류 불필요"
  printf '[]\n' >"$OUT"
  echo NONE
  exit 0
fi

ui_step "[triage] 시각 회귀 원인 분류 (코드 버그 vs 업스트림 렌더링 변화)"
TSV="$CDIR/.triage.tsv"
: >"$TSV"
any_code=0

while IFS=$'\t' read -r name reason vrationale det; do
  [ -n "$name" ] || continue
  if [ "$det" = "CODE" ]; then
    any_code=1
    ui_warn "$name → CODE (결정적: $reason)"
    printf '%s\t%s\t%s\t%s\n' "$name" "CODE" "deterministic" "구조 훼손 신호($reason) — 모델 분류 없이 코드 문제로 확정" >>"$TSV"
    continue
  fi
  card="side/$name.side.png"
  prompt="당신은 UI 렌더링 회귀의 '원인'을 분류합니다. 훼손 여부 판정이 아니라 원인 분류입니다.
파일 $card 를 Read 도구로 열어 보세요. 왼쪽=이전 릴리스(baseline), 가운데=새 빌드(new), 오른쪽(있다면)=diff 히트맵.
이 샘플은 이미 '훼손(DAMAGED)' 판정을 받았습니다.
- 판정 근거: $vrationale
- 픽셀 비교 사유: $reason
- 플랫폼 변화: dali-ui ${DALI_UI_TAG:-unknown} / core·adaptor ${CORE_ADAPTOR_TAG:-unknown} 로 올라감

다음 둘 중 하나로 분류하세요:
- CODE = 새 빌드가 '잘못' 그렸다. 요소 누락·겹침·잘림·위치 붕괴·빈 화면·이미지 미표시처럼
  콘텐츠나 레이아웃이 깨졌다. 렌더러 코드가 새 dali-ui 에 맞지 않아 생긴 버그.
- UPSTREAM = 새 빌드도 '정상적으로' 그렸다. 레이아웃과 콘텐츠는 온전하고, 차이는 플랫폼
  렌더링 자체의 변화(글자 래스터라이즈·자간·행간·안티앨리어싱·미세 색상)로 설명된다.

확신이 없으면 CODE 를 고르세요. UPSTREAM 은 '사람이 이 화면을 새 기준선으로 승인해도 좋다'는
뜻이므로, 깨진 화면을 UPSTREAM 으로 분류하면 손상이 그대로 기준이 됩니다.
UPSTREAM 을 고를 경우 근거 문장에 레이아웃과 콘텐츠가 온전하다는 확인을 반드시 포함하세요.
답변 형식: 첫 줄에 정확히 한 단어 CODE 또는 UPSTREAM. 둘째 줄에 근거 한 문장(한국어)."

  klass="CODE" # 보수 기본값
  rationale="분류 실패(호출/파싱 불가) — 보수적으로 코드 문제로 처리"
  source="default"
  if out=$(claude_call "$CDIR" "Read Glob" "$prompt"); then
    first=$(head -1 <<<"$out" | awk '{print $1}' | tr -cd 'A-Z')
    if [ "$first" = "CODE" ] || [ "$first" = "UPSTREAM" ]; then
      klass=$first
      source="vision"
      r=$(sed -n '2p' <<<"$out")
      rationale="${r:-(근거 없음)}"
    fi
  fi
  if [ "$klass" = "CODE" ]; then
    any_code=1
    ui_warn "$name → CODE ($source): $rationale"
  else
    ui_info "$name → UPSTREAM ($source): $rationale"
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$klass" "$source" "$rationale" >>"$TSV"
done <<<"$ROWS"

python3 -c '
import json, sys
rows = []
for line in open(sys.argv[1]):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 2:
        rows.append({"name": p[0], "class": p[1],
                     "source": p[2] if len(p) > 2 else "",
                     "rationale": p[3] if len(p) > 3 else ""})
json.dump(rows, open(sys.argv[2], "w"), indent=1, ensure_ascii=False)
' "$TSV" "$OUT"

if [ "$any_code" -eq 1 ]; then echo CODE; else echo UPSTREAM; fi
