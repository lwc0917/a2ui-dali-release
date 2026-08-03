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

ui_step "[selftest] 9) 시각 회귀 원인 분리 (코드 버그 vs 업스트림 렌더링 변화)"
# 게이트 RED 는 두 가지 전혀 다른 상황을 담는다. 코드 버그를 '골든 승인' 으로 보내면 깨진
# 화면이 새 기준선이 되고, 업스트림 변화를 'AI 수정' 으로 보내면 정상 동작을 뜯어고치려 든다.
# triage.sh 가 이 둘을 가르며, 아래는 그 경계와 보수 기본값을 실제 실행으로 못박는다.
TDIR="$TESTWS/triage"
TBIN="$TESTWS/bin_triage"
mkdir -p "$TDIR/side" "$TBIN"

# compare.json/verdicts.json 픽스처 생성기: 사유·diff·판정을 인자로 받는다.
mk_triage_fixture() { # $1=name $2=reason $3=diff(또는 null) $4=verdict
  python3 -c '
import json, sys
name, reason, diff, verdict = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = None if diff == "null" else float(diff)
json.dump([{"name": name, "diff": d, "status": "REVIEW", "reason": reason,
            "card": "side/%s.side.png" % name}], open(sys.argv[5], "w"))
json.dump([{"name": name, "verdict": verdict, "rationale": "테스트 근거"}], open(sys.argv[6], "w"))
' "$1" "$2" "$3" "$4" "$TDIR/compare.json" "$TDIR/verdicts.json"
  : >"$TDIR/side/$1.side.png"
}
triage_class_source() { # triage.json 첫 샘플의 분류 출처(deterministic|vision|default)
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["source"] if d else "NONE")' "$TDIR/triage.json"
}

# claude 스텁: 첫 줄이 판정. STUB_VERDICT 로 제어.
cat >"$TBIN/claude" <<'STUB'
#!/bin/bash
printf '{"result":"%s\\n테스트 근거","is_error":false}\n' "${STUB_VERDICT:-UPSTREAM}"
STUB
chmod +x "$TBIN/claude"
cat >"$TBIN/claude_fail" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$TBIN/claude_fail"

# 9a) 결정적 백스톱 — 모델을 부르지 않고도 코드 문제로 확정되어야 하는 신호들.
#     (claude 를 '항상 UPSTREAM' 스텁으로 깔아둬도 CODE 가 나와야 한다 = 모델 우회 증명)
for tc in "새 렌더가 거의 균일 — 빈 화면 의심|0.9|빈화면" \
          "크기 불일치 (480, 1280)→(480, 640)|null|크기불일치" \
          "새 렌더 없음(렌더 실패)|null|렌더실패" \
          "diff=3.100|3.1|대형차이"; do
  IFS='|' read -r _reason _diff _label <<<"$tc"
  mk_triage_fixture "s_$_label" "$_reason" "$_diff" "DAMAGED"
  OUT=$(PATH="$TBIN:$PATH" STUB_VERDICT=UPSTREAM bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
  t "결정적 백스톱($_label) → CODE (모델 판정 무시)" bash -c \
    "[ '$OUT' = CODE ] && [ \"\$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[0][\"source\"])' '$TDIR/triage.json')\" = deterministic ]"
done

# 9b) 백스톱에 안 걸리는 미세 차이 → 모델 분류를 따른다 (UPSTREAM 가능).
mk_triage_fixture "s_drift" "diff=0.060" "0.06" "DAMAGED"
OUT=$(PATH="$TBIN:$PATH" STUB_VERDICT=UPSTREAM bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "미세 차이 + 비전 UPSTREAM → UPSTREAM (골든 승인 경로)" test "$OUT" = "UPSTREAM"
t "분류 출처가 vision 으로 기록" test "$(triage_class_source)" = "vision"

# 9c) 보수 기본값: 판정 불가(호출 실패 / 알 수 없는 답) → CODE.
mk_triage_fixture "s_drift" "diff=0.060" "0.06" "DAMAGED"
OUT=$(PATH="$TBIN:$PATH" STUB_VERDICT="MAYBE" bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "분류 답 파싱 불가 → CODE (fail-closed)" bash -c "[ '$OUT' = CODE ]"
cp "$TBIN/claude_fail" "$TBIN/claude"
OUT=$(PATH="$TBIN:$PATH" bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "분류 호출 실패 → CODE (fail-closed)" bash -c "[ '$OUT' = CODE ]"
cat >"$TBIN/claude" <<'STUB'
#!/bin/bash
printf '{"result":"%s\\n테스트 근거","is_error":false}\n' "${STUB_VERDICT:-UPSTREAM}"
STUB
chmod +x "$TBIN/claude"

# 9d) 입력 자체가 없거나 깨졌을 때도 조용히 통과하지 않는다.
rm -f "$TDIR/compare.json" "$TDIR/verdicts.json"
OUT=$(PATH="$TBIN:$PATH" bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "triage 입력 없음 → CODE (조용한 통과 없음)" bash -c "[ '$OUT' = CODE ]"
printf 'not json' >"$TDIR/compare.json"
printf '[]' >"$TDIR/verdicts.json"
OUT=$(PATH="$TBIN:$PATH" bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "triage 입력 손상 → CODE (fail-closed)" bash -c "[ '$OUT' = CODE ]"

# 9e) ACCEPTABLE 만 있으면 분류 대상 없음 → NONE (게이트가 RED 가 아니므로 여기 오지도 않음)
mk_triage_fixture "s_ok" "diff=0.060" "0.06" "ACCEPTABLE"
OUT=$(PATH="$TBIN:$PATH" bash "$ROOT/automation/triage.sh" "$TDIR" 2>/dev/null | tail -1)
t "DAMAGED 없음 → NONE" bash -c "[ '$OUT' = NONE ]"

# 9f) 골든 후보 마커는 UPSTREAM 샘플에만 붙는다 — 코드 버그를 '승인하시겠습니까' 로 띄우면
#     사람이 깨진 화면을 기준선으로 만들 수 있다.
GD="$TESTWS/golden_marker"
mkdir -p "$GD/compare/side" "$GD/artifacts"
python3 -c '
import json, sys
base = sys.argv[1]
json.dump([{"name":"bug","diff":3.5,"status":"REVIEW","reason":"diff=3.500","card":"side/bug.side.png"},
           {"name":"drift","diff":0.06,"status":"REVIEW","reason":"diff=0.060","card":"side/drift.side.png"}],
          open(base+"/compare/compare.json","w"))
json.dump([{"name":"bug","verdict":"DAMAGED","rationale":"카드 붕괴"},
           {"name":"drift","verdict":"DAMAGED","rationale":"글자 두께 변화"}],
          open(base+"/compare/verdicts.json","w"))
json.dump([{"name":"bug","class":"CODE","source":"deterministic","rationale":"구조 훼손"},
           {"name":"drift","class":"UPSTREAM","source":"vision","rationale":"레이아웃과 콘텐츠는 온전"}],
          open(base+"/compare/triage.json","w"))
' "$GD"
: >"$GD/compare/side/bug.side.png"
: >"$GD/compare/side/drift.side.png"
MARKERS=$(python3 "$ROOT/tools/build_report.py" --outcome gate-damage --rundir "$GD" \
  --artifacts "$GD/artifacts" --out "$GD/report.md" 2>/dev/null | grep -c '^\[golden-candidate\]')
# 코드 버그(bug)가 남아 있으면 골든 승인 버튼을 하나도 띄우지 않는다 — UPSTREAM(drift)도 포함.
# FORCE_ACCEPT 는 all-or-nothing 이라, drift 만 승인하려 해도 안 고쳐진 bug 까지 릴리스된다.
# 릴리스-준비가 아니므로 승인 유도 대신 코드-수정 실패로 보고한다(실측 2026-07-22 교차감사).
t "골든 후보 마커: 코드 버그가 남으면 아무 후보도 미노출(승인 유도 금지)" test "$MARKERS" = "0"
t "리포트 TL;DR: 코드 문제는 골든 승인 대상이 아님을 명시" bash -c \
  "grep -q '골든 승인 대상이 아니라' '$GD/report.md'"
# 릴리스-준비(코드 버그 없이 UPSTREAM 드리프트만) 이면 골든 승인 버튼이 정상 노출된다.
GDU="$TESTWS/golden_marker_upstream_only"
mkdir -p "$GDU/compare/side" "$GDU/artifacts"
python3 -c '
import json, sys
base = sys.argv[1]
json.dump([{"name":"drift","diff":0.06,"status":"REVIEW","reason":"diff=0.060","card":"side/drift.side.png"}],
          open(base+"/compare/compare.json","w"))
json.dump([{"name":"drift","verdict":"DAMAGED","rationale":"글자 두께 변화"}],
          open(base+"/compare/verdicts.json","w"))
json.dump([{"name":"drift","class":"UPSTREAM","source":"vision","rationale":"레이아웃과 콘텐츠는 온전"}],
          open(base+"/compare/triage.json","w"))
' "$GDU"
: >"$GDU/compare/side/drift.side.png"
MARKERS_U=$(python3 "$ROOT/tools/build_report.py" --outcome gate-damage --rundir "$GDU" \
  --artifacts "$GDU/artifacts" --out "$GDU/report.md" 2>/dev/null | grep -c '^\[golden-candidate\]')
t "골든 후보 마커: UPSTREAM 만 남으면(릴리스-준비) 후보 노출" test "$MARKERS_U" = "1"
t "리포트: 샘플별 원인 분류 표기" bash -c \
  "grep -q '원인: \*\*업스트림 렌더링 변화\*\*' '$GD/report.md' && grep -q '원인: \*\*코드 버그\*\*' '$GD/report.md'"

# 9f-2) UPSTREAM 자동 승격(outcome=success + 손상 샘플) → '감사용' 갤러리로 명확히 라벨링
#       (승인 버튼 아님). 사람이 리포트를 훑다 오분류를 눈으로 잡게 하기 위함(정책 2026-07-23).
AP="$TESTWS/auto_promote_audit"
mkdir -p "$AP/compare/side" "$AP/artifacts"
python3 -c '
import json, sys
base = sys.argv[1]
json.dump([{"name":"drift","diff":0.09,"status":"REVIEW","reason":"diff=0.090","card":"side/drift.side.png"}],
          open(base+"/compare/compare.json","w"))
json.dump([{"name":"drift","verdict":"DAMAGED","rationale":"글자 두께 변화"}],
          open(base+"/compare/verdicts.json","w"))
json.dump([{"name":"drift","class":"UPSTREAM","source":"vision","rationale":"레이아웃·콘텐츠 온전, 래스터라이즈 차이"}],
          open(base+"/compare/triage.json","w"))
' "$AP"
: >"$AP/compare/side/drift.side.png"
python3 "$ROOT/tools/build_report.py" --outcome success --rundir "$AP" \
  --artifacts "$AP/artifacts" --out "$AP/report.md" >/dev/null 2>&1
t "자동 승격 감사: index.json 에 '감사용' 섹션" bash -c \
  "grep -q '자동 골든 승격됨 — 감사용' '$AP/artifacts/index.json'"
t "자동 승격 감사: 승인 버튼(golden-candidate) 은 안 뜬다" bash -c \
  "! python3 '$ROOT/tools/build_report.py' --outcome success --rundir '$AP' --artifacts '$AP/artifacts' --out '$AP/report.md' 2>/dev/null | grep -q '^\[golden-candidate\]'"
t "자동 승격 감사: 승격된 샘플 카드가 스테이징됨" test -f "$AP/artifacts/drift.side.png"

# 9g) 수정 예산은 모드별로 독립 — 빌드가 예산을 다 써도 visual 몫이 남아야 한다.
t "fix 예산 모드별 분리(.fix_attempts.<mode>)" grep -q 'ATT_FILE="\$RD/.fix_attempts.\$MODE"' "$ROOT/automation/fix.sh"
t "visual 전용 예산 상한(MAX_VISUAL_FIX_ATTEMPTS)" grep -q 'MAX_VISUAL_FIX_ATTEMPTS' "$ROOT/automation/fix.sh"
# 9h) visual 재검증 오라클 = 재빌드→재렌더→재비교→재판정 GREEN (모델 자기신고 금지)
sed -n '/^retry_check()/,/^}/p' "$ROOT/automation/fix.sh" >"$TESTWS/retry_check.txt"
t "visual 오라클: 재빌드 포함" grep -q 'build_a2ui.sh' "$TESTWS/retry_check.txt"
t "visual 오라클: 전수 재렌더 포함" grep -q 'render.sh' "$TESTWS/retry_check.txt"
t "visual 오라클: baseline 재비교 포함" grep -q 'compare.sh' "$TESTWS/retry_check.txt"
t "visual 오라클: 비전 재판정 GREEN 요구" grep -q 'judge.sh' "$TESTWS/retry_check.txt"
t "visual 오라클: GREEN 아니면 실패" grep -q 'GREEN' "$TESTWS/retry_check.txt"
# 9i) run.sh 라우팅: RED → triage → CODE 는 AI 수정, UPSTREAM(코드버그 없음)은 자동 골든 승격
#     (정책 2026-07-23: UPSTREAM 은 사람 승인 없이 이번 렌더를 새 골든으로 자동 승격+릴리스.
#      triage 는 손상 샘플이 하나라도 CODE 면 CODE 를 출력하므로 mixed 런은 자동승격되지 않는다.)
t "run.sh: RED 시 triage 호출" grep -q 'automation/triage.sh' "$ROOT/automation/run.sh"
t "run.sh: CODE → fix.sh visual" grep -q 'fix.sh" visual' "$ROOT/automation/run.sh"
t "run.sh: UPSTREAM → 사람 승인 없이 자동 골든 승격" grep -q 'AUTO_GOLDEN_UPSTREAM=1' "$ROOT/automation/run.sh"
t "run.sh: UPSTREAM → '승인 필요' 로 차단하지 않는다(옛 동작 제거)" bash -c "! grep -q '골든 갱신 승인 필요' '$ROOT/automation/run.sh'"
t "run.sh: 자동 승격 대상을 리포트에 감사 기록" grep -q '자동 골든 승격' "$ROOT/automation/run.sh"
# 9j) 증거 조립: CODE 샘플만 프롬프트에 실린다 (정상 동작을 고치려 들지 않도록)
EV=$(python3 -c "
import sys; sys.path.insert(0, '$ROOT/tools')
from visual_evidence import build
print(build('$GD/compare', '$ROOT/corpus/jsonl'))")
t "증거 조립: CODE 샘플만 포함" bash -c "grep -q 'bug' <<<\"\$(cat <<'E'
$EV
E
)\" && ! grep -q 'drift' <<<\"\$(cat <<'E'
$EV
E
)\""
t "증거 조립: 비교 이미지 경로 포함(모델이 Read 로 연다)" bash -c "grep -q 'side/bug.side.png' <<<\"\$(cat <<'E'
$EV
E
)\""

ui_step "[selftest] 10) e2e 에서 드러난 구멍 3건 회귀 방지"
# 10a) triage 로그가 명령치환에 삼켜지지 않는다 — 콘솔에 '왜 그렇게 분류했는지'가 남아야
#      사람이 오분류를 잡을 수 있다(실측: run.log 에 [triage] 줄이 하나도 없었음).
t "run.sh: triage 로그를 tee 로 노출" grep -q 'triage.sh" "\$RUNDIR/compare" | tee /dev/stderr' "$ROOT/automation/run.sh"

# 10b) 시각 수정 성공 시 '무엇이 깨져 있었는지'가 사라지지 않는다.
#      재검증이 compare/ 를 전부 PASS 로 덮어쓰므로, 수정 전 스냅샷이 없으면 리포트가
#      '손상 0' 이 되어 깨끗한 재빌드와 구분되지 않는다(무인 운영에서 치명적).
t "fix.sh visual: 수정 전 compare 스냅샷 생성" grep -q 'compare_pre_fix' "$ROOT/automation/fix.sh"
PF="$TESTWS/prefix_report"
mkdir -p "$PF/compare_pre_fix/side" "$PF/compare" "$PF/artifacts" "$PF/new"
python3 -c '
import json, sys
base = sys.argv[1]
# 수정 후 상태: 전부 PASS (재검증이 덮어쓴 모습)
json.dump([{"name":"pick","diff":0.0,"status":"PASS","reason":"","card":None}],
          open(base+"/compare/compare.json","w"))
json.dump([], open(base+"/compare/verdicts.json","w"))
# 수정 전 스냅샷: 손상 1건 + 코드 버그로 분류
json.dump([{"name":"pick","diff":0.994,"status":"REVIEW","reason":"diff=0.994",
            "card":"side/pick.side.png"}], open(base+"/compare_pre_fix/compare.json","w"))
json.dump([{"name":"pick","verdict":"DAMAGED","rationale":"선택 칩이 통째로 미렌더"}],
          open(base+"/compare_pre_fix/verdicts.json","w"))
json.dump([{"name":"pick","class":"CODE","source":"vision","rationale":"콘텐츠 누락 = 코드 버그"}],
          open(base+"/compare_pre_fix/triage.json","w"))
' "$PF"
: >"$PF/compare_pre_fix/side/pick.side.png"
printf '1' >"$PF/.fix_attempts"
python3 "$ROOT/tools/build_report.py" --outcome dry-run --rundir "$PF" \
  --artifacts "$PF/artifacts" --out "$PF/report.md" >/dev/null 2>&1
t "리포트 TL;DR: AI 가 고친 시각 회귀를 명시" grep -q 'AI 가 코드로 수정' "$PF/report.md"
t "리포트: 수정 전 손상 내역 섹션" grep -q '### AI 가 고친 시각 회귀' "$PF/report.md"
t "리포트: 수정 전 근거(판정·분류) 표기" bash -c \
  "grep -q '선택 칩이 통째로 미렌더' '$PF/report.md' && grep -q 'CODE(vision)' '$PF/report.md'"
t "artifacts: 수정 전 side 카드 스테이징" test -f "$PF/artifacts/prefix_pick.side.png"
t "artifacts: 수정 전 섹션 등록" grep -q '수정 전' "$PF/artifacts/index.json"

# 10c) README 호환표 설명 초안 정규화 — 모델이 '한 줄' 지시를 어기고 근거 표를 덧붙인
#      1,100자 블롭이 실측으로 관측됐다. 그대로면 표 셀이 파괴된다.
norm_desc() { # stdin 초안 → 정규화 결과 (release.sh 와 동일 로직)
  local d
  d=$(sed 's/\r$//' | grep -v '^[[:space:]]*$' | head -1 |
    tr '|' ' ' | sed 's/^[[:space:]]*[-*#>][[:space:]]*//; s/  */ /g; s/^ *//; s/ *$//')
  if [ ${#d} -gt "${COMPAT_DESC_MAX:-200}" ]; then d=""; fi
  printf '%s' "$d"
}
t "정규화: 정상 한 줄은 그대로" bash -c \
  "[ \"\$(printf 'new headers under \`public-api/views\`' | { $(declare -f norm_desc); norm_desc; })\" = 'new headers under \`public-api/views\`' ]"
t "정규화: 근거 표가 붙은 블롭은 첫 줄만" bash -c \
  "[ \"\$(printf 'phrase only\n\n근거 (src/ 실제 참조)\n| a | b |\n| c | d |' | { $(declare -f norm_desc); norm_desc; })\" = 'phrase only' ]"
t "정규화: 파이프 제거(표 셀 파손 방지)" bash -c \
  "! printf 'a | b' | { $(declare -f norm_desc); norm_desc; } | grep -q '|'"
t "정규화: 상한 초과 초안은 폐기(원문 유지)" bash -c \
  "[ -z \"\$(python3 -c 'print(\"x\"*300)' | { $(declare -f norm_desc); norm_desc; })\" ]"
t "release.sh: 상한 가드 존재" grep -q 'COMPAT_DESC_MAX' "$ROOT/automation/release.sh"

ui_step "[selftest] 11) 업스트림 델타 증거 (구→신 dali-ui 변화)"
# 설치된 새 헤더는 '지금 뭐가 있나' 만 알려준다. 적응에 필요한 건 '무엇이 무엇으로 바뀌었나' 다.
# 실측(dali-preview, 2026-07-21): 델타 없이 헤더만 준 경우 모델이 대체 API 를 못 찾아 기능을
# 삭제했고, 델타/헤더를 주자 1회에 정확한 마이그레이션을 냈다.
source "$ROOT/automation/lib/dali_headers.sh"
DH="$TESTWS/dh"; mkdir -p "$DH/old/public-api" "$DH/new/public-api"
cat > "$DH/old/public-api/label.h" <<'H'
class Label {
  void SetMarkupEnabled(bool enabled);
  void SetText(const String& text);
};
H
cat > "$DH/new/public-api/label.h" <<'H'
class Label {
  void SetText(const String& text);
  void SetStyledText(const StyledText& styled);
};
class StyledText { static StyledText FromMarkup(const String& markup); };
H
# 캐시 히트 경로로 네트워크 없이 델타 생성(두 디렉터리가 이미 헤더를 갖고 있음)
mkdir -p "$DH/delta"
( cd "$DH" && OLD_DIR="$DH/old" NEW_DIR="$DH/new" DEST="$DH/delta" python3 -c '
import os, re, pathlib
DECL = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\s*\(")
def syms(root):
    out = set()
    for p in pathlib.Path(root).rglob("*.h"):
        for line in p.read_text().splitlines():
            out.update(DECL.findall(line.split("//")[0]))
    return out
o, n, d = syms(os.environ["OLD_DIR"]), syms(os.environ["NEW_DIR"]), os.environ["DEST"]
open(d + "/removed-symbols.txt", "w").write("\n".join(sorted(o - n)))
open(d + "/added-symbols.txt", "w").write("\n".join(sorted(n - o)))
' )
t "델타: 사라진 심볼 추출" grep -qx "SetMarkupEnabled" "$DH/delta/removed-symbols.txt"
t "델타: 대체 후보 추출" grep -qx "FromMarkup" "$DH/delta/added-symbols.txt"
t "델타: 유지된 심볼은 미포함" bash -c "! grep -qx 'SetText' '$DH/delta/removed-symbols.txt'"
t "fix.sh 가 델타를 조달" grep -q 'prepare_upstream_delta' "$ROOT/automation/fix.sh"
t "fix.sh 프롬프트가 델타 경로를 명시" grep -q 'removed-symbols.txt' "$ROOT/automation/fix.sh"
t "델타 기준점은 baseline meta 의 이전 태그" grep -q 'baseline/meta.json' "$ROOT/automation/fix.sh"
t "프롬프트가 '지워서 통과' 를 금지" grep -q '기능을 지워서' "$ROOT/automation/fix.sh"
if type dali_ui_headers_delta >/dev/null 2>&1 && type dali_ui_headers_fetch >/dev/null 2>&1; then
  ui_ok "조달기 함수 로딩(공용 패턴: fetch + delta)"
else
  ui_err "FAIL: 조달기 함수 로딩"; FAILED=1
fi

ui_step "[selftest] 12) LLM 을 '아예 못 쓴' 경우와 '고치지 못한' 경우의 구분"
# 실측(2026-07-21): 시각 수정 2회가 모두 429(session limit)로 실패했는데, 하네스가 사유를
# 버리고 "AI 가 시도했으나 해결 못 함" 으로 보고했다. 사람은 AI 가 무능하다고 오해했고,
# 실제로는 잠시 뒤 재실행하면 될 일이었다. 게다가 예산을 깎고 재빌드·재렌더까지 돌려 20분을 헛돌았다.
source "$ROOT/automation/lib/claude.sh"
LIMIT_JSON='{"is_error":true,"api_error_status":429,"result":"You'"'"'ve hit your session limit · resets 9:20pm"}'
OVER_JSON='{"is_error":true,"api_error_status":503,"result":"Overloaded"}'
REFUSE_JSON='{"is_error":true,"api_error_status":null,"result":"I cannot do that"}'
GOOD_JSON='{"is_error":false,"result":"done"}'
t "429 사용량 한도 → 일시적(2)" test "$(claude_failure_kind "$LIMIT_JSON" 0)" = "2"
t "503 과부하 → 일시적(2)" test "$(claude_failure_kind "$OVER_JSON" 0)" = "2"
t "timeout(rc=124) → 일시적(2)" test "$(claude_failure_kind "" 124)" = "2"
t "모델이 응답했으나 못 씀 → 비일시적(1)" test "$(claude_failure_kind "$REFUSE_JSON" 0)" = "1"
t "파싱 불가 → 비일시적(1)" test "$(claude_failure_kind "쓰레기" 0)" = "1"
REASON="$(claude_failure_reason "$LIMIT_JSON")"
t "실패 사유에 상태코드 노출" grep -q "api_error_status=429" <<<"$REASON"
t "실패 사유에 원문 메시지 노출" grep -q "session limit" <<<"$REASON"
t "fix.sh: 일시적 실패는 예산 미차감" grep -q 'attempts=\$((attempts - 1))' "$ROOT/automation/fix.sh"
t "fix.sh: 일시적 실패는 exit 3 으로 구분" grep -q 'exit 3' "$ROOT/automation/fix.sh"
t "run.sh: exit 3 을 llm-unavailable 로 보고" grep -q 'llm-unavailable' "$ROOT/automation/run.sh"
t "리포트가 '시도하지 못했다' 로 명시" grep -q '시도하지 못했습니다' "$ROOT/tools/build_report.py"
t "claude 응답 원문을 남긴다(사후 진단)" grep -q 'claude.last.json' "$ROOT/automation/lib/claude.sh"

ui_step "[selftest] 13) 시각 회귀 → 소스 파일 결정적 안내 (component_sources)"
# 실측(2026-07-22): 모델이 증상은 정확히 진단하고도 엉뚱한 파일(view-pool.cpp/tabs.cpp)을 고쳐
# 렌더가 소수점까지 안 바뀌었다. 원인은 하네스가 '어느 소스가 이 컴포넌트를 그리나' 를 안 줬기
# 때문. 코퍼스 component 타입 → 레지스트리 매핑으로 그 소스를 결정적으로 짚는지 검증한다.
CS="$ROOT/tools/component_sources.py"
REPO="$WORKSPACE/csrepo"
mkdir -p "$REPO/src/renderer/components"
cat > "$REPO/src/renderer/a2ui-renderer.cpp" <<'CPP'
void A2uiRenderer::RegisterStandardCatalog() {
  mRegistry.Register("Image",  [this](const C& c, R& rc){ return RenderImage(c, rc.data); });
  mRegistry.Register("Icon",   [this](const C& c, R& rc){ return RenderIcon(c, rc.data); });
  mRegistry.Register("Row",    [this](const C& c, R& rc){ return RenderFlexContainer(c, FD::ROW); });
}
CPP
echo 'View RenderImage(const C& c, D d) { }' > "$REPO/src/renderer/components/image.cpp"
echo 'View RenderIcon(const C& c, D d) { }'  > "$REPO/src/renderer/components/icon.cpp"
echo 'View RenderFlexContainer(const C& c, FD d) { }' > "$REPO/src/renderer/components/flex-container.cpp"
echo '// item gap' > "$REPO/src/renderer/render-internal.h"
CORP="$WORKSPACE/cscorpus"; mkdir -p "$CORP"
printf '{"updateComponents":{"components":[{"component":"Row","children":[{"component":"Image"}]}]}}\n' > "$CORP/podcast.jsonl"
printf '{"updateComponents":{"components":[{"component":"Icon"}]}}\n' > "$CORP/music.jsonl"

OUT="$(python3 "$CS" "$REPO" "$CORP" podcast)"
t "podcast: 쓰는 컴포넌트에 Image·Row 포함" bash -c "grep -q 'Image' <<<\"$OUT\" && grep -q 'Row' <<<\"$OUT\""
t "podcast: 정렬 원인 flex-container.cpp 안내" grep -q 'components/flex-container.cpp' <<<"$OUT"
t "podcast: Image 렌더 소스 image.cpp 안내" grep -q 'components/image.cpp' <<<"$OUT"
t "podcast: 안 쓰는 icon.cpp 는 미포함" bash -c "! grep -q 'components/icon.cpp' <<<\"$OUT\""
OUT2="$(python3 "$CS" "$REPO" "$CORP" music)"
t "music: 아이콘 원인 icon.cpp 안내" grep -q 'components/icon.cpp' <<<"$OUT2"
t "music: 안 쓰는 image.cpp 는 미포함" bash -c "! grep -q 'components/image.cpp' <<<\"$OUT2\""
t "레이아웃 공통(render-internal.h) 항상 포함" grep -q 'render-internal.h' <<<"$OUT"
t "fix.sh visual 프롬프트가 소스 안내를 싣는다" grep -q 'visual_source_hint' "$ROOT/automation/fix.sh"

ui_step "[selftest] 14) LLM 실패/부분성공 오보 방지"
# 실측(2026-07-22): (a) Claude 가 파일을 편집했는데 claude_call 반환이 실패라 '수정 없이 재검증'
# 으로 오보, (b) AI 가 26_podcast 를 diff 0.0 으로 고쳤는데 리포트가 '해결하지 못했습니다' 로 오보
# (남은 건 다른 샘플 30 이었다). 사람이 취할 행동이 정반대이므로 반드시 구분한다.
t "claude.sh: 실패 원문 보존(덮어쓰기 방지)" grep -q 'claude.failures.log' "$ROOT/automation/lib/claude.sh"
t "fix.sh: 편집 여부를 git 으로 확인" grep -q '파일 .*개가 실제로 편집됨' "$ROOT/automation/fix.sh"
t "fix.sh: 편집 없을 때만 '무동작'" grep -q '편집도 없음' "$ROOT/automation/fix.sh"
# build_report: 고친 것/남은 것 분리 — 스냅샷으로 재현
BR="$TESTWS/br"; mkdir -p "$BR/compare" "$BR/compare_pre_fix" "$BR/artifacts"
python3 -c '
import json,sys
base=sys.argv[1]
# 수정 후: 26 은 PASS, 30 만 DAMAGED
json.dump([{"name":"26_podcast-episode","diff":0.0,"status":"PASS","reason":""},
           {"name":"30_live-invitation-builder","diff":2.27,"status":"REVIEW","reason":"diff=2.27","card":"side/30.side.png"}],
          open(base+"/compare/compare.json","w"))
json.dump([{"name":"30_live-invitation-builder","verdict":"DAMAGED","rationale":"원격 이미지 흔들림"}],
          open(base+"/compare/verdicts.json","w"))
json.dump([{"name":"30_live-invitation-builder","class":"CODE","source":"vision","rationale":"x"}],
          open(base+"/compare/triage.json","w"))
# 수정 전: 26 이 DAMAGED 였다
json.dump([{"name":"26_podcast-episode","diff":8.98,"status":"REVIEW","reason":"diff=8.98","card":"side/26.side.png"}],
          open(base+"/compare_pre_fix/compare.json","w"))
json.dump([{"name":"26_podcast-episode","verdict":"DAMAGED","rationale":"썸네일 밀림"}],
          open(base+"/compare_pre_fix/verdicts.json","w"))
json.dump([{"name":"26_podcast-episode","class":"CODE","source":"deterministic","rationale":"y"}],
          open(base+"/compare_pre_fix/triage.json","w"))
' "$BR"
mkdir -p "$BR/compare/side"; : >"$BR/compare/side/30.side.png"
printf '3' >"$BR/.fix_attempts"
python3 "$ROOT/tools/build_report.py" --outcome gate-damage --rundir "$BR" --artifacts "$BR/artifacts" --out "$BR/report.md" >/dev/null 2>&1
t "리포트: AI 가 26 을 고쳤음을 명시" grep -q 'AI 가 1건(26_podcast-episode)은 코드로 고쳐 통과' "$BR/report.md"
t "리포트: 최종 남은 건 30(다른 샘플)" grep -q '30_live-invitation-builder' "$BR/report.md"
t "리포트: 고친 26 을 '미해결'로 표기 안 함" bash -c "! grep -q '26_podcast-episode.*해결하지 못' '$BR/report.md'"

ui_step "[selftest] 15) 코퍼스 결정성 — 원격 이미지 URL 검출 + vendored 복구"
# 실측(2026-07-22): 36종 중 30_live-invitation-builder 만 원격 unsplash URL 이 남아 회색
# 플레이스홀더로 렌더됐고, AI 가 26 을 diff 0.0 으로 고쳐도 30 때문에 게이트가 비결정적으로
# RED 였다. 원격 이미지 검출 + vendored 복구 검증.
CA="$ROOT/tools/check_corpus_assets.py"
CD="$TESTWS/corpus1"; mkdir -p "$CD"
printf '{"createSurface":{"catalogId":"https://a2ui.org/spec/catalog.json"}}\n{"components":[{"component":"Image","url":"sample-images/local.jpg"}]}\n' > "$CD/ok.jsonl"
t "로컬 이미지만 → 결정적(rc0)" bash -c "python3 '$CA' '$CD' >/dev/null 2>&1"
printf '{"components":[{"component":"Image","url":"https://images.unsplash.com/photo-abc?w=400"}]}\n' > "$CD/bad.jsonl"
t "원격 이미지 URL 검출(rc1)" bash -c "! python3 '$CA' '$CD' >/dev/null 2>&1"
t "카탈로그 스펙 URL 은 이미지 아님(오탐 없음)" bash -c "
  printf '{\"createSurface\":{\"catalogId\":\"https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json\"}}\n' > '$CD/cat.jsonl'
  rm -f '$CD/bad.jsonl'
  python3 '$CA' '$CD' >/dev/null 2>&1"
t "실제 코퍼스는 이제 전부 로컬(30 로컬화 완료)" bash -c "python3 '$CA' '$ROOT/corpus/jsonl' >/dev/null 2>&1"
t "vendored 이미지 디렉터리 존재" test -d "$ROOT/corpus/sample-images"
t "30 의 로컬화 이미지가 vendored 됨" bash -c "ls '$ROOT/corpus/sample-images'/*.jpg >/dev/null 2>&1"
t "render.sh 가 vendored 이미지를 res 로 복사" grep -q 'corpus/sample-images' "$ROOT/automation/render.sh"
t "preflight 가 코퍼스 결정성 점검" grep -q 'check_corpus_assets' "$ROOT/automation/preflight.sh"

ui_step "[selftest] 16) 자기 리포 게시 — allowlist · ahead/behind 가드 · 비호환 캐시 영속"
# 실측 배경(2026-08-03): 비호환 캐시가 gitignored 인 workspace/ 에만 있어, 워크스페이스가
# 사라지면 '이 조합은 빌드가 안 된다'는 학습이 통째로 날아가 수십 분짜리 스택 빌드를 다시
# 태웠다. 이제 실행이 state/incompatible.json 을 레포에 커밋·push 한다. 위험한 건 '무엇을
# 스테이징하느냐' 라서, 진짜 git 레포 + bare 리모트로 그 계약을 오프라인에서 못박는다.
source "$ROOT/automation/lib/repo_publish.sh"

RP="$TESTWS/rp"; mkdir -p "$RP/state"
git init -q "$RP" && git -C "$RP" config user.email t@t && git -C "$RP" config user.name t
echo seed > "$RP/seed.txt"; git -C "$RP" add -A && git -C "$RP" commit -q -m seed
git init -q --bare "$TESTWS/rp-origin.git" && git -C "$RP" remote add origin "$TESTWS/rp-origin.git"
git -C "$RP" push -q origin HEAD:refs/heads/$(git -C "$RP" rev-parse --abbrev-ref HEAD)

# allowlist 밖의 dirty 파일은 절대 커밋되면 안 된다(실행이 남긴 산출물이 딸려 올라가는 사고).
echo '{"pairs":["a+b"]}' > "$RP/state/incompatible.json"
echo 'RUNTIME GARBAGE' > "$RP/leftover.png"
( ROOT="$RP" AGENT_REPO_REMOTES="origin" DRY_RUN=0 repo_publish "chore(state): test" state/incompatible.json ) >/dev/null 2>&1
t "게시: allowlist 파일이 커밋됨" bash -c "git -C '$RP' show --name-only --format= HEAD | grep -qx 'state/incompatible.json'"
t "게시: allowlist 밖 파일은 커밋 안 됨" bash -c "! git -C '$RP' show --name-only --format= HEAD | grep -q 'leftover.png'"
rp_in_sync() { git -C "$RP" fetch -q origin && [ "$(git -C "$RP" rev-list --count FETCH_HEAD..HEAD)" = "0" ]; }
t "게시: 리모트에 반영됨" rp_in_sync
t "게시: 변경 없으면 커밋 안 만든다(멱등)" bash -c "
  before=\$(git -C '$RP' rev-parse HEAD)
  ( ROOT='$RP' AGENT_REPO_REMOTES=origin DRY_RUN=0 repo_publish 'noop' state/incompatible.json ) >/dev/null 2>&1
  [ \"\$before\" = \"\$(git -C '$RP' rev-parse HEAD)\" ]"
t "게시: DRY_RUN 이면 커밋하지 않는다" bash -c "
  echo '{\"pairs\":[\"a+b\",\"c+d\"]}' > '$RP/state/incompatible.json'
  before=\$(git -C '$RP' rev-parse HEAD)
  ( ROOT='$RP' AGENT_REPO_REMOTES=origin DRY_RUN=1 repo_publish 'dry' state/incompatible.json ) >/dev/null 2>&1
  [ \"\$before\" = \"\$(git -C '$RP' rev-parse HEAD)\" ]"
# 리모트가 앞서 있으면(남의 커밋) main 을 직접 밀지 않고 별도 브랜치로 올린다.
rp_diverge_and_publish() {
  # 다른 클론이 origin/main 을 먼저 밀어 리모트가 앞서게 만든다(= 남의 커밋).
  git clone -q "$TESTWS/rp-origin.git" "$TESTWS/rp2" || return 1
  git -C "$TESTWS/rp2" config user.email t@t; git -C "$TESTWS/rp2" config user.name t
  echo other > "$TESTWS/rp2/other.txt"
  git -C "$TESTWS/rp2" add -A && git -C "$TESTWS/rp2" commit -q -m other || return 1
  git -C "$TESTWS/rp2" push -q origin HEAD || return 1
  echo '{"pairs":["z+z"]}' > "$RP/state/incompatible.json"
  ( ROOT="$RP" AGENT_REPO_REMOTES=origin DRY_RUN=0 REPO_PUBLISH_FALLBACK=state/update \
      repo_publish "diverged" state/incompatible.json ) >/dev/null 2>&1
  # main 은 남의 커밋 그대로여야 하고, 내 커밋은 폴백 브랜치로 나가 있어야 한다.
  git -C "$RP" ls-remote --heads origin | grep -q 'refs/heads/state/update'
}
t "게시: 리모트가 앞서면 직접 push 하지 않고 브랜치로" rp_diverge_and_publish
rp_main_untouched() {
  git -C "$TESTWS/rp2" fetch -q origin && \
    [ "$(git -C "$TESTWS/rp2" rev-parse HEAD)" = "$(git -C "$TESTWS/rp2" rev-parse origin/HEAD 2>/dev/null || git -C "$TESTWS/rp2" rev-parse origin/main)" ]
}
t "게시: 남의 커밋 위에 덮어쓰지 않았다" rp_main_untouched

# 비호환 캐시가 레포 경로로 가고, 옛 워크스페이스 캐시는 한 번 이전된다.
IWS="$TESTWS/iws"; mkdir -p "$IWS"
printf '{"pairs":["old+pair"],"reasons":{"old+pair":"legacy"}}' > "$IWS/incompatible.json"
t "비호환 캐시: 레포 경로에 기록된다" bash -c "
  ( INCOMPAT_FILE='$TESTWS/state1/incompatible.json' WORKSPACE='$TESTWS/empty' \
    bash -c 'source \"$ROOT/automation/lib/dali.sh\"; incompatible_add v1 t1 why' )
  grep -q 'v1+t1' '$TESTWS/state1/incompatible.json'"
t "비호환 캐시: 옛 워크스페이스 캐시를 이전한다" bash -c "
  ( INCOMPAT_FILE='$TESTWS/state2/incompatible.json' WORKSPACE='$IWS' \
    bash -c 'source \"$ROOT/automation/lib/dali.sh\"; incompatible_has old pair' )
  grep -q 'old+pair' '$TESTWS/state2/incompatible.json'"

ui_step "[selftest] 17) 에이전트 자기 릴리스 — 마커는 '릴리스할 것이 있고 트리가 깨끗할 때만'"
RA="$TESTWS/ra"; mkdir -p "$RA/automation/lib"
cp "$ROOT/automation/release_agent.sh" "$RA/automation/"
cp "$ROOT/automation/lib/ui.sh" "$ROOT/automation/lib/load_env.sh" "$ROOT/automation/lib/repo_publish.sh" "$RA/automation/lib/"
printf 'apiVersion: agenthub/v1\nid: x\nname: x\nversion: 9.9.9\n' > "$RA/agent.yaml"
git init -q "$RA" && git -C "$RA" config user.email t@t && git -C "$RA" config user.name t
git -C "$RA" add -A && git -C "$RA" commit -q -m init
t "릴리스 마커: 미태그 + 깨끗한 트리 → 제안" bash -c "
  WORKSPACE='$TESTWS/rws' bash '$RA/automation/release_agent.sh' --check 2>/dev/null | grep -q '\\[agent-release-ready: v9.9.9\\]'"
t "릴리스 마커: 워킹트리가 더러우면 제안하지 않는다" bash -c "
  echo dirt > '$RA/dirt.txt'
  ! WORKSPACE='$TESTWS/rws' bash '$RA/automation/release_agent.sh' --check 2>/dev/null | grep -q 'agent-release-ready'"
t "릴리스 마커: 이미 태그된 버전이면 제안하지 않는다" bash -c "
  rm -f '$RA/dirt.txt'; git -C '$RA' tag -a v9.9.9 -m v9.9.9
  ! WORKSPACE='$TESTWS/rws' bash '$RA/automation/release_agent.sh' --check 2>/dev/null | grep -q 'agent-release-ready'"
t "릴리스 실행: 더러운 트리에서는 fail-closed(비-0)" bash -c "
  echo dirt > '$RA/dirt.txt'
  ! WORKSPACE='$TESTWS/rws' bash '$RA/automation/release_agent.sh' --confirmed >/dev/null 2>&1"
run_sh_calls_check_only() {
  grep -qE 'release_agent\.sh"? --check' "$ROOT/automation/run.sh" \
    && ! grep -qE 'release_agent\.sh"? --confirmed' "$ROOT/automation/run.sh"
}
t "run.sh 는 --check 만 부른다(에이전트가 스스로 릴리스하지 않는다)" run_sh_calls_check_only
t "매니페스트 액션이 --confirmed 를 부른다" grep -q 'release_agent.sh --confirmed' "$ROOT/agent.yaml"

echo
if [ "$FAILED" -eq 0 ]; then
  ui_ok "[selftest] 전 항목 통과"
  exit 0
fi
ui_err "[selftest] 실패 항목 있음"
exit 1
