#!/bin/bash
# selftest.sh — 오프라인 가드레일 검증 (네트워크/빌드/Claude 불필요).
#  1) dali-ui ↔ core/adaptor 페어링 규칙(+폴백)
#  2) ledger 멱등
#  3) fix 범위 가드 (src/ 밖 수정 감지·되돌림)
#  4) judge 보수 기본값 (claude 스텁이 쓰레기 응답 → DAMAGED → RED)
#  5) compare.py 스모크 (PASS/REVIEW/side 카드/시트)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/dali.sh"
source "$ROOT/automation/lib/claude.sh"

# 격리 워크스페이스는 반드시 load_env(.env 로드) '이후'에 지정한다.
# ※ 실측 사고: .env 에 WORKSPACE 가 있으면 load_env 가 사전 export 를 덮어써서
#   종료 trap 이 '운영 워크스페이스'를 rm -rf 해버렸음. 전용 변수 + /tmp 가드로 방지.
TESTWS="$(mktemp -d /tmp/a2ui-release-selftest.XXXXXX)"
export WORKSPACE="$TESTWS"
cleanup_testws() {
  case "$TESTWS" in
  /tmp/a2ui-release-selftest.*) rm -rf "$TESTWS" ;;
  *) ui_err "selftest cleanup 가드: 예상 밖 경로 삭제 거부 ($TESTWS)" ;;
  esac
}
trap cleanup_testws EXIT

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

ui_step "[selftest] 1b) 자동 타깃 선정 (exact-pair only, 실측 2.5.30 사례)"
dali_ui_tags_desc() { printf 'v2.5.30.10887\nv2.5.29.10863\nv2.5.29.10862\nv2.5.28.10837\n'; }
_core_adaptor_common_tags() { printf 'dali_2.5.29\ndali_2.5.30\n'; }
ledger_add v2.5.28.10837
t "페어 없는 2.5.30 은 대기, 2.5.29.10863+dali_2.5.30 선정" \
  test "$(select_processable_target 2>/dev/null)" = "v2.5.29.10863 dali_2.5.30"
ledger_add v2.5.29.10863
select_none() { ! select_processable_target >/dev/null 2>&1; }
t "처리 가능분이 모두 ledger 에 있으면 후보 없음" select_none

ui_step "[selftest] 1c) 게이트 강도 입력 매핑 (hub run 인자)"
gate_map() { # $1=GATE_LEVEL [$2=DIFF_THRESHOLD_INPUT] → 유효 threshold 출력
  bash -c "
    export GATE_LEVEL='$1' DIFF_THRESHOLD_INPUT='${2:-}' DIFF_THRESHOLD=
    source '$ROOT/automation/lib/load_env.sh'
    echo \"\$GATE_LEVEL \$DIFF_THRESHOLD\""
}
t "strict → 0.02" test "$(gate_map strict)" = "strict 0.02"
t "normal → 0.05" test "$(gate_map normal)" = "normal 0.05"
t "lenient → 0.30" test "$(gate_map lenient)" = "lenient 0.30"
t "직접 지정이 레벨 기본값보다 우선" test "$(gate_map lenient 0.10)" = "lenient 0.10"
t "미지정/이상값 → normal 폴백" test "$(gate_map weird)" = "normal 0.05"
t "force_accept 포괄값(true)은 무력화 (sticky 우회 차단)" bash -c "
  export FORCE_ACCEPT_INPUT=true
  source '$ROOT/automation/lib/load_env.sh'
  [ -z \"\$FORCE_ACCEPT\" ]"
t "force_accept 태그값은 통과 (target-bound)" bash -c "
  export FORCE_ACCEPT_INPUT=v2.5.29.10863
  source '$ROOT/automation/lib/load_env.sh'
  [ \"\$FORCE_ACCEPT\" = v2.5.29.10863 ]"

ui_step "[selftest] 2) ledger"
t "ledger_add 후 ledger_has" bash -c "
  source '$ROOT/automation/lib/load_env.sh'
  export WORKSPACE='$TESTWS'   # .env 의 WORKSPACE 덮어쓰기 무력화 (실 ledger 보호)
  source '$ROOT/automation/lib/dali.sh'
  ledger_add vX.Y.Z && ledger_has vX.Y.Z && ! ledger_has vNOPE"

ui_step "[selftest] 3) fix 범위 가드"
source "$ROOT/automation/fix.sh" --lib
export WORKSPACE="$TESTWS" # fix.sh 가 load_env 를 재소싱하며 .env 가 다시 덮어씀 — 재고정
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
# P0-2: 손상/절단/빈 compare.json 은 판정 불가 → 보수적으로 RED (fail-closed)
judge_gate() { PATH="$STUB:$PATH" bash "$ROOT/automation/judge.sh" "$1" 2>/dev/null | tail -1; }
CDIR_BAD="$WORKSPACE/cmp_corrupt"; mkdir -p "$CDIR_BAD"
printf '[{"name":"x","status":"REVIEW' >"$CDIR_BAD/compare.json"   # 절단된 JSON
t "손상된 compare.json → RED (fail-closed)" test "$(judge_gate "$CDIR_BAD")" = "RED"
CDIR_EMPTY="$WORKSPACE/cmp_empty"; mkdir -p "$CDIR_EMPTY"
printf '[]' >"$CDIR_EMPTY/compare.json"                            # 빈 목록(비정상 비교)
t "빈 목록 compare.json → RED (fail-closed)" test "$(judge_gate "$CDIR_EMPTY")" = "RED"
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

ui_step "[selftest] 5b) P1-7 국소훼손/빈화면 백스톱 & 오탐 가드"
# 전역 mean-abs-diff 가 국소 손상을 희석하는 취약점(P1-7) 회귀 방지.
# 세 케이스 모두 결정적(난수 없음) — 임계 여유를 넉넉히 두어 부동소수 흔들림에도 안전.
PA="$WORKSPACE/pa" PB="$WORKSPACE/pb" PO="$WORKSPACE/po"
mkdir -p "$PA" "$PB"
python3 - "$PA" "$PB" <<'PY'
import sys
import numpy as np
from PIL import Image
A, B = sys.argv[1], sys.argv[2]
# 공통 베이스: 세로 그라디언트(비균일 std≈74) — is_near_uniform 오작동 방지용.
base = np.tile((np.arange(1024) % 256).astype(np.uint8)[:, None, None], (1, 1024, 3))

# (1) 국소 훼손: 32x32 타일 하나만 +40 → 전역 0.038(≤0.05)인데 국소 patch≈39(>8).
loc = base.copy()
loc[448:480, 448:480] = np.clip(loc[448:480, 448:480].astype(int) + 40, 0, 255)
Image.fromarray(base).save(A + "/loc.png")
Image.fromarray(loc).save(B + "/loc.png")

# (2) 빈 화면(전면 미렌더): 새 렌더가 균일 백색 → 전역 diff 큼 → REVIEW.
Image.fromarray(base).save(A + "/blank.png")
Image.fromarray(np.full((1024, 1024, 3), 255, np.uint8)).save(B + "/blank.png")

# (3) 오탐 가드: 서브임계 희소 노이즈(+2, 73px 간격) → 전역·patch 모두 임계 이하 → PASS.
noise = base.copy()
noise[::73, ::73] = np.clip(noise[::73, ::73].astype(int) + 2, 0, 255)
Image.fromarray(base).save(A + "/noise.png")
Image.fromarray(noise).save(B + "/noise.png")
PY
python3 "$ROOT/tools/compare.py" --baseline "$PA" --new "$PB" --out "$PO" >/dev/null
t "국소 훼손(전역<임계, patch>임계) → REVIEW(국소)" bash -c "python3 -c \"
import json
es = {e['name']: e for e in json.load(open('$PO/compare.json'))}
assert es['loc']['status'] == 'REVIEW', es['loc']
assert '국소' in es['loc']['reason'], es['loc']\""
t "빈 화면(전면 미렌더) → REVIEW" bash -c "python3 -c \"
import json
es = {e['name']: e for e in json.load(open('$PO/compare.json'))}
assert es['blank']['status'] == 'REVIEW', es['blank']\""
t "서브임계 희소 노이즈 → PASS (백스톱 오탐 없음)" bash -c "python3 -c \"
import json
es = {e['name']: e for e in json.load(open('$PO/compare.json'))}
assert es['noise']['status'] == 'PASS', es['noise']\""

ui_step "[selftest] 6) 무인 운영 하드닝 (P1-9 로테이션 / P1-10 타임아웃·preflight / 다중 판정)"
# 6a) P1-9: prune_old_runs 를 run.sh 에서 추출해 실제로 검증 (최신 KEEP_RUNS 개만 남기고
#     runs/ 밖은 절대 안 건드림; KEEP_RUNS<1 은 현재 실행 보호 위해 스킵).
eval "$(sed -n '/^prune_old_runs()/,/^}/p' "$ROOT/automation/run.sh")"
PW="$TESTWS/prunetest"
mkdir -p "$PW/runs" "$PW/keepme"
for i in 1 2 3 4 5; do
  mkdir -p "$PW/runs/r$i"
  touch -d "2026-01-0$i 00:00" "$PW/runs/r$i" 2>/dev/null || true
done
( WORKSPACE="$PW" KEEP_RUNS=2; prune_old_runs )
t "P1-9: 최신 2개만 보존" bash -c "[ \$(ls -1d '$PW/runs/'*/ 2>/dev/null | wc -l) -eq 2 ]"
t "P1-9: 가장 오래된 r1 삭제됨" bash -c "! test -d '$PW/runs/r1'"
t "P1-9: 가장 최신 r5 보존" test -d "$PW/runs/r5"
t "P1-9: runs/ 밖(keepme) 절대 미삭제" test -d "$PW/keepme"
mkdir -p "$PW/runs/rz"
( WORKSPACE="$PW" KEEP_RUNS=0; prune_old_runs )
t "P1-9: KEEP_RUNS<1 은 정리 스킵(현재 실행 보호)" test -d "$PW/runs/rz"

# 6b) P1-10: render/conformance 가 하드 타임아웃으로 감싸졌는가 + preflight 도구 확인
t "P1-10: render 샘플 타임아웃 래핑" grep -q 'timeout -k .* "\$RENDER_SAMPLE_TIMEOUT"' "$ROOT/automation/render.sh"
t "P1-10: conformance 타임아웃 래핑" grep -q 'timeout -k .* "\$CONFORMANCE_TIMEOUT"' "$ROOT/automation/conformance.sh"
t "P1-10: render preflight 필수 도구 점검" grep -q 'command -v "\$_t"' "$ROOT/automation/render.sh"

# 6c) 다중 판정(JUDGE_VOTES): ACCEPTABLE 스텁 + 2표 → 만장일치 GREEN. (garbage→RED 는 §4 커버)
STUB2="$TESTWS/bin_vote"
mkdir -p "$STUB2"
# claude_call 은 --output-format json 결과에서 result 를 뽑는다 → 스텁도 JSON 을 낸다.
cat >"$STUB2/claude" <<'STUB'
#!/bin/bash
echo '{"result":"ACCEPTABLE\n미세 드리프트","is_error":false}'
STUB
chmod +x "$STUB2/claude"
CDIR2="$TESTWS/cmp_vote"
mkdir -p "$CDIR2/side"
python3 -c '
import json, sys
json.dump([{"name": "01_x", "diff": 0.06, "status": "REVIEW", "reason": "diff=0.06",
            "card": "side/01_x.side.png"}], open(sys.argv[1], "w"))
' "$CDIR2/compare.json"
: >"$CDIR2/side/01_x.side.png"
GATE2=$(PATH="$STUB2:$PATH" JUDGE_VOTES=2 bash "$ROOT/automation/judge.sh" "$CDIR2" 2>/dev/null | tail -1)
t "다중 판정: ACCEPTABLE 2표 만장일치 → GREEN" test "$GATE2" = "GREEN"

ui_step "[selftest] 7) README 호환표 갱신 (tools/readme_bump — 버전 범프 + 설명 셀 재작성)"
# release.sh 가 릴리스 때 편집하는 README 호환 블록 로직을 결정적으로 회귀 검증(Claude 불필요).
RB_OUT=$(python3 - "$ROOT/tools" "$TESTWS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import readme_bump as rb

SRC = (
    "# demo\n\n"
    "> ## ⚠️ DALi compatibility\n>\n"
    "> | Module | Version |\n"
    "> |--------|---------|\n"
    "> | `dali2-core`, `dali2-adaptor` | **`dali_2.5.29`** |\n"
    "> | `dali2-ui-foundation`, `dali2-ui-components` | "
    "**`dali-ui` `v2.5.28.10837`** — old headers under `public-api/foo` |\n"
    ">\n"
    "> `dali-ui` trails core by one minor, so pair `dali-ui` 2.5.28 "
    "with core/adaptor 2.5.29.\n\n"
    "## Highlights\n\n- keep `v2.5.28.10837` here untouched\n"
)
ui, core = "v2.5.29.10863", "dali_2.5.30"
HL = "## Highlights"

b = rb.bump_versions(SRC, ui, core)
head_b, tail_b = b[: b.find(HL)], b[b.find(HL):]
tail_s = SRC[SRC.find(HL):]

c = []
c.append(("desc-current", rb.get_compat_desc(SRC) == "old headers under `public-api/foo`"))
c.append(("bump-ui", "v2.5.29.10863" in head_b and "v2.5.28.10837" not in head_b))
c.append(("bump-core", "dali_2.5.30" in head_b and "dali_2.5.29" not in head_b))
c.append(("bump-pair", "pair `dali-ui` 2.5.29 with core/adaptor 2.5.30" in head_b))
c.append(("bump-keeps-desc", "old headers under `public-api/foo`" in head_b))
c.append(("bump-tail-untouched", tail_b == tail_s))  # Highlights 이후 옛 태그 언급 불변

nd = "new headers under `public-api/widgets` + builder in `devel-api/builder`"
d = rb.replace_compat_desc(b, ui, nd)
head_d = d[: d.find(HL)]
c.append(("desc-replaced", nd in head_d and "public-api/foo" not in head_d))
c.append(("desc-keeps-tag", "v2.5.29.10863" in head_d))       # 태그 보존
c.append(("desc-empty-noop", rb.replace_compat_desc(b, ui, "") == b))
c.append(("desc-blank-noop", rb.replace_compat_desc(b, ui, "  \n ") == b))
c.append(("desc-tail-untouched", d[d.find(HL):] == tail_s))

# get-desc CLI 픽스처(다음 t 케이스에서 사용)
open(sys.argv[2] + "/rm_cli.md", "w").write(
    "> | x | **`dali-ui` `v9.9.9.9`** — hello world |\n")

bad = [n for n, ok in c if not ok]
print("FAIL:" + ",".join(bad) if bad else "OK")
PY
)
t "readme_bump 회귀 (버전 범프+설명 셀+폴백)" test "$RB_OUT" = "OK"
[ "$RB_OUT" = OK ] || ui_err "  readme_bump 실패 항목: $RB_OUT"
t "get-desc CLI 동작" bash -c \
  "[ \"\$(python3 '$ROOT/tools/readme_bump.py' get-desc '$TESTWS/rm_cli.md')\" = 'hello world' ]"

ui_step "[selftest] 8) 렌더 에셋 해석 (capture.sh 가 렌더러 레포 루트에서 실행되는가)"
# 렌더러는 이미지/아이콘/알파마스크를 상대경로 res/ 로 연다 → 실행 CWD 가 렌더러 레포 루트가
# 아니면 에셋이 전부 조용히 유실되고(회색 플레이스홀더) 렌더는 "성공"으로 끝난다. 게이트는
# prev vs new 델타라 양쪽이 똑같이 깨지면 diff=0(PASS) — 그래서 여기서 직접 못박는다.
# 실제 실행 검증: xvfb-run/xwd/ffmpeg 를 스텁하고 가짜 렌더러가 자기 CWD 와 에셋 열림 여부를 기록.
RSTUB="$TESTWS/bin_render"
FAKE="$TESTWS/fakestack"
mkdir -p "$RSTUB" "$FAKE/bin" "$FAKE/res/sample-images"
echo "jpegbytes" >"$FAKE/res/sample-images/x.jpg"
cat >"$FAKE/bin/a2ui-basic-renderer" <<'STUB'
#!/bin/bash
# 렌더러 대역: 실행 시점의 CWD 와, 상대경로 에셋이 열리는지를 기록한다.
{ echo "PWD=$PWD"; if [ -f "res/sample-images/x.jpg" ]; then echo "ASSET=ok"; else echo "ASSET=missing"; fi; } \
  >"$RENDER_PROBE"
sleep 30 &   # capture.sh 가 kill 할 백그라운드 앱 흉내
wait
STUB
chmod +x "$FAKE/bin/a2ui-basic-renderer"
cat >"$RSTUB/xvfb-run" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -a) shift;; -s) shift 2;; *) break;; esac; done
export DISPLAY=":0"
exec "$@"
STUB
cat >"$RSTUB/xwd" <<'STUB'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-out" ] && { out="$2"; shift 2; continue; }; shift; done
[ -n "$out" ] && printf 'xwddata' >"$out"
STUB
cat >"$RSTUB/ffmpeg" <<'STUB'
#!/bin/bash
for a in "$@"; do last="$a"; done
printf 'pngdata' >"$last"
STUB
chmod +x "$RSTUB/xvfb-run" "$RSTUB/xwd" "$RSTUB/ffmpeg"
RPROBE="$TESTWS/render_probe.txt"
: >"$RPROBE"
CAP_IN="$TESTWS/cap_in.jsonl"
echo '{"x":1}' >"$CAP_IN"
# 호출자 CWD 는 res/ 가 없는 곳(=허브가 넘기는 에이전트 루트와 같은 상황).
( cd "$TESTWS" && PATH="$RSTUB:$PATH" A2UI_RENDERER="$FAKE/bin/a2ui-basic-renderer" \
    RENDER_PROBE="$RPROBE" bash "$ROOT/tools/capture.sh" "$CAP_IN" "$TESTWS/cap_out.png" 64 64 0 \
) >/dev/null 2>&1
t "렌더러가 에셋 루트(렌더러 레포)에서 실행됨" bash -c "grep -qx 'PWD=$FAKE' '$RPROBE'"
t "상대경로 res/ 에셋이 실제로 열림" bash -c "grep -qx 'ASSET=ok' '$RPROBE'"
t "렌더러 stderr 로그가 샘플별로 분리됨" grep -q 'RENDER_LOG=' "$ROOT/tools/capture.sh"
# preflight: 코퍼스가 참조하는 로컬 에셋이 없으면 렌더는 시작조차 하면 안 된다.
t "render preflight: 에셋 루트 부재 → 하드 실패" bash -c \
  "grep -q '렌더 에셋 루트 없음' '$ROOT/automation/render.sh'"
t "render preflight: 코퍼스 참조 에셋 존재 검증" bash -c \
  "grep -q 'sample-images/' '$ROOT/automation/render.sh'"

echo
if [ "$FAILED" -eq 0 ]; then
  ui_ok "[selftest] 전 항목 통과"
  exit 0
fi
ui_err "[selftest] 실패 항목 있음"
exit 1
