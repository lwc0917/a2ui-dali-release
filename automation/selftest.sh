#!/bin/bash
# selftest.sh — 오프라인 가드레일 검증 (네트워크/빌드/Claude 불필요).
#  1) dali-ui ↔ core/adaptor 페어링 규칙(+폴백)
#  2) ledger 멱등
#  3) fix 범위 가드 (src/ 밖 수정 감지·되돌림)
#  4) judge 보수 기본값 (claude 스텁이 쓰레기 응답 → DAMAGED → RED)
#  5) compare.py 스모크 (PASS/REVIEW/side 카드/시트)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WORKSPACE="$(mktemp -d /tmp/a2ui-release-selftest.XXXXXX)"
trap 'rm -rf "$WORKSPACE"' EXIT
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/dali.sh"
source "$ROOT/automation/lib/claude.sh"

FAILED=0
t() { # $1=desc, 이후=명령 — 성공해야 통과
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    ui_ok "$desc"
  else
    ui_err "FAIL: $desc"
    FAILED=1
  fi
}

ui_step "[selftest] 1) 페어링 규칙"
_core_adaptor_common_tags() { printf 'dali_2.5.27\ndali_2.5.29\n'; }
t "v2.5.28.10837 → dali_2.5.29 (정확 매치)" \
  test "$(pair_core_adaptor_tag v2.5.28.10837 2>/dev/null)" = "dali_2.5.29"
t "v2.5.30.11000 → dali_2.5.29 (이하 최신 폴백)" \
  test "$(pair_core_adaptor_tag v2.5.30.11000 2>/dev/null)" = "dali_2.5.29"
pair_must_fail() { ! pair_core_adaptor_tag v0.0.1 2>/dev/null; }
t "v0.0.1 → 폴백 불가 시 실패 리턴" pair_must_fail

ui_step "[selftest] 2) ledger"
t "ledger_add 후 ledger_has" bash -c "
  source '$ROOT/automation/lib/load_env.sh'; source '$ROOT/automation/lib/dali.sh'
  ledger_add vX.Y.Z && ledger_has vX.Y.Z && ! ledger_has vNOPE"

ui_step "[selftest] 3) fix 범위 가드"
source "$ROOT/automation/fix.sh" --lib
TREPO="$WORKSPACE/trepo"
mkdir -p "$TREPO/src" "$TREPO/test"
git -C "$TREPO" init -q
echo a >"$TREPO/src/a.cpp"
echo t >"$TREPO/test/t.txt"
git -C "$TREPO" add -A
git -C "$TREPO" -c user.name=t -c user.email=t@t commit -qm init
echo mod >>"$TREPO/src/a.cpp"   # 허용 범위
echo mod >>"$TREPO/test/t.txt"  # 범위 밖
echo new >"$TREPO/CMakeLists.txt" # 범위 밖 (untracked)
viol=$(fix_scope_violations "$TREPO")
t "위반 감지: test/t.txt" grep -q "test/t.txt" <<<"$viol"
t "위반 감지: CMakeLists.txt" grep -q "CMakeLists.txt" <<<"$viol"
t "허용 범위 src/ 는 미포함" bash -c "! grep -q 'src/a.cpp' <<<'$viol'"
# shellcheck disable=SC2086
fix_scope_revert "$TREPO" $viol
t "되돌림 후 위반 없음" test -z "$(fix_scope_violations "$TREPO")"
t "src/ 수정은 보존" grep -q mod "$TREPO/src/a.cpp"
t "test/ 는 원복" bash -c "! grep -q mod '$TREPO/test/t.txt'"

ui_step "[selftest] 4) judge 보수 기본값 (claude 스텁)"
STUB="$WORKSPACE/bin"
mkdir -p "$STUB"
printf '#!/bin/bash\necho "not json garbage"\n' >"$STUB/claude"
chmod +x "$STUB/claude"
CDIR="$WORKSPACE/cmp"
mkdir -p "$CDIR/side"
python3 -c '
import json, sys
json.dump([{"name": "01_x", "diff": 0.5, "status": "REVIEW", "reason": "diff=0.500",
            "card": "side/01_x.side.png"}], open(sys.argv[1], "w"))
' "$CDIR/compare.json"
GATE=$(PATH="$STUB:$PATH" bash "$ROOT/automation/judge.sh" "$CDIR" 2>/dev/null | tail -1)
t "쓰레기 응답 → RED (DAMAGED 기본값)" test "$GATE" = "RED"
t "verdicts.json 에 DAMAGED 기록" grep -q DAMAGED "$CDIR/verdicts.json"
t "claude_judgement 기본값 유지" bash -c "
  export PATH='$STUB:\$PATH' WORKSPACE='$WORKSPACE' CLAUDE_MODEL=opus CLAUDE_TIMEOUT=10
  source '$ROOT/automation/lib/ui.sh'; source '$ROOT/automation/lib/claude.sh'
  [ \"\$(claude_judgement '$WORKSPACE' 'x' DAMAGED DAMAGED ACCEPTABLE)\" = DAMAGED ]"

ui_step "[selftest] 5) compare.py 스모크"
A="$WORKSPACE/a" B="$WORKSPACE/b" O="$WORKSPACE/o"
mkdir -p "$A" "$B"
python3 -c '
import sys
from PIL import Image, ImageDraw
img = Image.new("RGB", (120, 200), (250, 250, 250))
img.save(sys.argv[1] + "/s1.png"); img.save(sys.argv[2] + "/s1.png")
img.save(sys.argv[1] + "/s2.png")
d = ImageDraw.Draw(img); d.rectangle([10, 10, 110, 100], fill=(200, 30, 30))
img.save(sys.argv[2] + "/s2.png")
' "$A" "$B"
python3 "$ROOT/tools/compare.py" --baseline "$A" --new "$B" --out "$O" >/dev/null
t "동일 이미지 → PASS" bash -c "python3 -c \"
import json; es={e['name']:e for e in json.load(open('$O/compare.json'))}
assert es['s1']['status']=='PASS' and es['s2']['status']=='REVIEW'\""
t "REVIEW side 카드 생성" test -s "$O/side/s2.side.png"
t "PASS 는 side 카드 없음" bash -c "! test -e '$O/side/s1.side.png'"
t "갤러리 시트 생성" test -s "$O/gallery_sheet.png"

echo
if [ "$FAILED" -eq 0 ]; then
  ui_ok "[selftest] 전 항목 통과"
  exit 0
fi
ui_err "[selftest] 실패 항목 있음"
exit 1
