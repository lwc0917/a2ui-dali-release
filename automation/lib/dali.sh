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

# ── 비호환 조합 캐시 (state/incompatible.json — 레포에 영속) ───────────────────
# 업스트림 세 레포(core/adaptor/ui)의 태그가 항상 정합하지는 않는다. 실측 2026-07-28,
# dali-ui v2.5.31.10949 는 '어떤 단일 태그로도' 빌드되지 않는다:
#   · core   는 dali_2.5.32 이상이어야 한다 — DevelActor::SetResizePolicy 가 2.5.32 에서 추가
#   · adaptor 는 dali_2.5.31 이하여야 한다 — VideoPlayerPlugin::VideoControlPolicy 가 2.5.32 에서 삭제
# 이 에이전트는 core/adaptor 에 같은 태그를 쓰므로 둘을 동시에 만족시킬 수 없다.
# ledger 는 '릴리스 성공'만 기록하므로 이런 타깃은 매 주기 수십 분짜리 스택 빌드를 무한 재시도한다.
# 그래서 실패를 '태그'가 아니라 '(dali-ui, core/adaptor) 조합' 단위로 기록한다 — 새 core 태그가
# 나오면 조합이 달라져 자동으로 다시 시도되므로, 업스트림이 정합해지면 스스로 풀린다.
incompatible_key() { echo "$1+$2"; } # $1=ui_tag $2=core_adaptor_tag

# 캐시 파일 경로. 예전엔 $WORKSPACE/incompatible.json 이었는데 workspace/ 는 gitignored 라
# 이 머신에만 존재했다 — 워크스페이스를 지우거나 다른 곳에 재설치하면 '이 조합은 빌드가 안
# 된다'는 학습이 통째로 사라지고, 수십 분짜리 스택 빌드를 다시 태워 같은 결론에 도달한다.
# 판단이 필요 없는 순수 사실이므로 레포에 두고 실행이 스스로 커밋·push 한다(run.sh).
: "${INCOMPAT_FILE:=$ROOT/state/incompatible.json}"

# 옛 워크스페이스 캐시가 있으면 한 번만 레포 파일로 옮겨 학습을 잃지 않는다(멱등).
incompatible_migrate() {
  [ -f "$INCOMPAT_FILE" ] && return 0
  [ -f "${WORKSPACE:-}/incompatible.json" ] || return 0
  mkdir -p "$(dirname "$INCOMPAT_FILE")" || return 0
  cp "$WORKSPACE/incompatible.json" "$INCOMPAT_FILE" 2>/dev/null \
    && echo "[incompat] 워크스페이스 캐시를 레포로 이전: $INCOMPAT_FILE" >&2
}

incompatible_has() { # $1=ui_tag $2=core_adaptor_tag → 0 if cached
  incompatible_migrate
  python3 - "$INCOMPAT_FILE" "$(incompatible_key "$1" "$2")" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
sys.exit(0 if key in set(data.get("pairs", [])) else 1)
PY
}

incompatible_add() { # $1=ui_tag $2=core_adaptor_tag $3=reason
  incompatible_migrate
  mkdir -p "$(dirname "$INCOMPAT_FILE")"
  python3 - "$INCOMPAT_FILE" "$(incompatible_key "$1" "$2")" "${3:-}" <<'PY'
import json, sys
path, key, reason = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
pairs = data.setdefault("pairs", [])
if key not in pairs:
    pairs.append(key)
data.setdefault("reasons", {})[key] = reason
with open(path, "w") as f:
    json.dump(data, f, indent=1, ensure_ascii=False)
PY
}

# 자동 경로용 타깃 선정: 최신순으로 훑으며
#  - ledger 에 있는 태그를 만나면 중단(그보다 오래된 건 이미 지난 상태) → 후보 없음
#  - 정확한 페어(dali_A.B.(C+1))가 core/adaptor 양쪽에 있으면 그 태그가 타깃
#  - 페어가 아직 없으면(예: dali-ui 2.5.30 인데 core 2.5.31 미태그) 스킵하고 다음 태그
#  - 그 조합이 이미 '비호환'으로 기록돼 있으면 더 옛 태그로 내려가지 않고 대기(no-op).
#    옛 태그는 어차피 릴리스 가치가 없고, 내려갈수록 실패할 스택 빌드만 더 태운다.
#    업스트림에 새 core/adaptor 태그가 나오면 조합이 바뀌어 자동으로 다시 시도된다.
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
      if incompatible_has "$tag" "$want"; then
        echo "select: $tag + $want 은 빌드 비호환으로 기록됨 — 새 core/adaptor 태그까지 대기" >&2
        return 1
      fi
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
