# dali.sh — dali-ui 태그 감지 / core·adaptor 페어링 / ledger.
# lib/load_env.sh, lib/ui.sh 이후 source.

# 원격 태그 이름 목록 (peeled ^{} 제거, 정렬 전)
_remote_tags() { # $1=repo url, $2=refs glob
  git ls-remote --tags "$1" "$2" 2>/dev/null \
    | awk '{print $2}' | sed 's|^refs/tags/||; s|\^{}$||' | sort -u
}

# 최신 dali-ui 릴리스 태그(vA.B.C.BUILD) → stdout. 조회 실패/없음 → 비-0.
latest_dali_ui_tag() {
  local tags
  tags=$(_remote_tags "$DALI_UI_REPO" 'refs/tags/v*') || return 1
  tags=$(grep -E '^v[0-9]+(\.[0-9]+){2,3}$' <<<"$tags" | sort -V | tail -1)
  [ -n "$tags" ] || return 1
  echo "$tags"
}

# core/adaptor 양쪽에 공통 존재하는 dali_X.Y.Z 태그 목록
_core_adaptor_common_tags() {
  local core adaptor
  core=$(_remote_tags "$DALI_CORE_REPO" 'refs/tags/dali_*' | grep -E '^dali_[0-9]+\.[0-9]+\.[0-9]+$') || return 1
  adaptor=$(_remote_tags "$DALI_ADAPTOR_REPO" 'refs/tags/dali_*' | grep -E '^dali_[0-9]+\.[0-9]+\.[0-9]+$') || return 1
  comm -12 <(sort -u <<<"$core") <(sort -u <<<"$adaptor")
}

# dali-ui vA.B.C.* → core/adaptor 태그. 규칙: dali-ui 가 core 보다 minor 1 낮음
# → 원하는 태그 = dali_A.B.(C+1). 없으면 그 이하 최신 공통 태그로 폴백(+경고, stderr).
pair_core_adaptor_tag() {
  local ui_tag=$1 ver A B C want common best
  ver=${ui_tag#v}
  IFS=. read -r A B C _ <<<"$ver"
  [ -n "${C:-}" ] || { echo "pair: 태그 파싱 실패: $ui_tag" >&2; return 1; }
  want="dali_${A}.${B}.$((C + 1))"
  common=$(_core_adaptor_common_tags) || { echo "pair: core/adaptor 태그 조회 실패" >&2; return 1; }
  if grep -qx "$want" <<<"$common"; then
    echo "$want"
    return 0
  fi
  # 폴백: want 이하(version order)의 최신 공통 태그
  best=$(printf '%s\n' "$common" "$want" | sort -uV | awk -v w="$want" '$0==w{exit}{print}' | tail -1)
  if [ -n "$best" ]; then
    echo "pair: 정확한 $want 없음 → $best 로 폴백 (빌드 실패 시 triage 대상)" >&2
    echo "$best"
    return 0
  fi
  echo "pair: $ui_tag 에 쓸 core/adaptor 태그 없음 (want=$want)" >&2
  return 1
}

# ── ledger: $WORKSPACE/done.json = {"done": ["v2.5.28.10837", ...]} ──
ledger_has() { # $1=tag → 0 if present
  python3 - "$WORKSPACE/done.json" "$1" <<'PY'
import json, sys
path, tag = sys.argv[1], sys.argv[2]
try:
    done = json.load(open(path)).get("done", [])
except (FileNotFoundError, json.JSONDecodeError):
    done = []
sys.exit(0 if tag in done else 1)
PY
}

ledger_add() { # $1=tag (idempotent)
  python3 - "$WORKSPACE/done.json" "$1" <<'PY'
import json, sys
path, tag = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except (FileNotFoundError, json.JSONDecodeError):
    data = {"done": []}
if tag not in data["done"]:
    data["done"].append(tag)
json.dump(data, open(path, "w"), indent=1)
PY
}
