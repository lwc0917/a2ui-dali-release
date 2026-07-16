# dali.sh — dali-ui 태그 감지 / core·adaptor 페어링 / ledger.
# lib/load_env.sh, lib/ui.sh 이후 source.

# 원격 태그 이름 목록 (peeled ^{} 제거, 정렬 전)
# timeout 로 감싸 ls-remote 가 스톨해도 무한 대기하지 않음(무인 운영).
_remote_tags() { # $1=repo url, $2=refs glob
  timeout "${NET_TIMEOUT:-900}" git ls-remote --tags "$1" "$2" 2>/dev/null \
    | awk '{print $2}' | sed 's|^refs/tags/||; s|\^{}$||' | sort -u
}

# dali-ui 릴리스 태그(vA.B.C.BUILD) 목록, 최신순 → stdout. 조회 실패/없음 → 비-0.
dali_ui_tags_desc() {
  local tags
  tags=$(_remote_tags "$DALI_UI_REPO" 'refs/tags/v*') || return 1
  tags=$(grep -E '^v[0-9]+(\.[0-9]+){2,3}$' <<<"$tags" | sort -rV)
  [ -n "$tags" ] || return 1
  echo "$tags"
}

# 최신 dali-ui 릴리스 태그 → stdout (호환용)
latest_dali_ui_tag() { dali_ui_tags_desc | head -1; }

# dali-ui 태그의 '정확한' 페어(dali_A.B.(C+1)) 이름 계산 (존재 확인 안 함)
exact_pair_name() { # $1=vA.B.C.*
  local ver A B C
  ver=${1#v}
  IFS=. read -r A B C _ <<<"$ver"
  [ -n "${C:-}" ] || return 1
  echo "dali_${A}.${B}.$((C + 1))"
}

# core/adaptor 양쪽에 공통 존재하는 dali_X.Y.Z 태그 목록
_core_adaptor_common_tags() {
  local core adaptor
  core=$(_remote_tags "$DALI_CORE_REPO" 'refs/tags/dali_*' | grep -E '^dali_[0-9]+\.[0-9]+\.[0-9]+$') || return 1
  adaptor=$(_remote_tags "$DALI_ADAPTOR_REPO" 'refs/tags/dali_*' | grep -E '^dali_[0-9]+\.[0-9]+\.[0-9]+$') || return 1
  comm -12 <(sort -u <<<"$core") <(sort -u <<<"$adaptor")
}

# 자동 경로용 타깃 선정: 최신순으로 훑으며
#  - ledger 에 있는 태그를 만나면 중단(그보다 오래된 건 이미 지난 상태) → 후보 없음
#  - 정확한 페어(dali_A.B.(C+1))가 core/adaptor 양쪽에 있으면 그 태그가 타깃
#  - 페어가 아직 없으면(예: dali-ui 2.5.30 인데 core 2.5.31 미태그) 스킵하고 다음 태그
# 출력: "UI_TAG PAIR_TAG" / 후보 없음 → 비-0 (스킵 사유는 stderr)
select_processable_target() {
  local common tag want
  common=$(_core_adaptor_common_tags) || { echo "select: core/adaptor 태그 조회 실패" >&2; return 2; }
  while read -r tag; do
    [ -n "$tag" ] || continue
    if ledger_has "$tag"; then
      echo "select: $tag 은 이미 처리됨 — 그 이전 태그는 검토 안 함" >&2
      return 1
    fi
    want=$(exact_pair_name "$tag") || continue
    if grep -qx "$want" <<<"$common"; then
      echo "$tag $want"
      return 0
    fi
    echo "select: $tag 스킵 — 페어 $want 가 core/adaptor 에 아직 없음 (대기)" >&2
  done < <(dali_ui_tags_desc)
  return 1
}

# dali-ui vA.B.C.* → core/adaptor 태그. 규칙: dali-ui 가 core 보다 minor 1 낮음
# → 원하는 태그 = dali_A.B.(C+1). 없으면 그 이하 최신 공통 태그로 폴백(+경고, stderr).
# ※ 자동 경로는 select_processable_target(exact-only)을 쓰고, 이 폴백은
#   FORCE_TARGET(사람이 명시)에서만 사용 — 폴백 빌드는 실패할 수 있음(2.5.30 실측).
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
