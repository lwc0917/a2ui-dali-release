#!/bin/bash
# gh_release_sync.sh — 원격에 있는 a2ui-dali 태그에 GitHub '릴리스'가 있도록 맞춘다(멱등).
#
# 왜 있나: 태그 push 와 릴리스 생성은 별개의 일이고, 릴리스 쪽만 실패할 수 있다. 그 상태를
# 고칠 자동 경로가 없으면 사람이 손으로 gh 를 두드려야 하고, 대개는 아무도 모른 채 남는다
# (실측 2026-08-07: v0.13.0~v0.18.0 이 태그만 있는 채 6주). 그래서 복구를 스크립트로 고정하고
# 허브 후속 작업 버튼(`gh-release-sync` 액션)이 이걸 부른다.
#
#   (인자 없음)          : origin/main 의 현재 버전 하나만 — 방금 실패한 릴리스 복구용(버튼).
#   --tag vX.Y.Z         : 그 태그만 (반복 지정 가능)
#   --missing [N]        : 릴리스가 없는 원격 태그 전부(최신 N개로 제한, 기본 전부) — 소급 보정
#   --list               : 무엇이 없는지 보기만 한다(생성 안 함)
#
# 노트는 CHANGELOG.md 의 해당 절에서 뽑는다. 이미 릴리스가 있으면 절대 덮어쓰지 않는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/gh_release.sh"

REPO="$SRC/a2ui-dali"
[ -d "$REPO/.git" ] || {
  ui_err "[gh-release] a2ui-dali 클론이 없다: $REPO (먼저 실행이 한 번 돌아야 한다)"
  exit 1
}

MODE=current
LIMIT=0
TAGS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --tag)
    MODE=explicit
    TAGS+=("$2")
    shift 2
    ;;
  --missing)
    MODE=missing
    if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
      LIMIT="$2"
      shift
    fi
    shift
    ;;
  --list)
    MODE=list
    shift
    ;;
  *)
    ui_err "[gh-release] 알 수 없는 인자: $1"
    exit 2
    ;;
  esac
done

ui_step "[gh-release] GitHub 릴리스 동기화 (mode=$MODE)"
git -C "$REPO" fetch --tags --force origin >/dev/null 2>&1 \
  || ui_warn "[gh-release] fetch 실패 — 로컬에 있는 태그 정보로 진행"

remote_url="$(gh_remote_url "$REPO" origin)"
hs="$(gh_url_host_slug "$remote_url")" || {
  ui_err "[gh-release] 리모트 URL 해석 실패: $remote_url"
  exit 1
}
HOST="${hs%% *}"
SLUG="${hs##* }"

# 원격 태그 목록 (vX.Y.Z 만, 오름차순)
remote_tags() {
  git -C "$REPO" ls-remote --tags origin 2>/dev/null \
    | sed -n 's#.*refs/tags/\(v[0-9][0-9.]*\)$#\1#p' | sort -V -u
}

case "$MODE" in
current)
  VER="$(git -C "$REPO" show origin/main:CMakeLists.txt 2>/dev/null | python3 -c '
import re, sys
m = re.search(r"PROJECT\s*\([^)]*?VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)", sys.stdin.read(), re.S | re.I)
print(m.group(1) if m else "")
')"
  [ -n "$VER" ] || { ui_err "[gh-release] origin/main 에서 버전 파싱 실패"; exit 1; }
  TAGS=("v$VER")
  ;;
missing | list)
  mapfile -t ALL < <(remote_tags)
  [ "${#ALL[@]}" -gt 0 ] || { ui_err "[gh-release] 원격 태그를 못 읽었다"; exit 1; }
  MISSING=()
  for t in "${ALL[@]}"; do
    if GH_HOST="$HOST" gh release view "$t" --repo "$HOST/$SLUG" >/dev/null 2>&1; then
      continue
    fi
    MISSING+=("$t")
  done
  if [ "${#MISSING[@]}" -eq 0 ]; then
    ui_ok "[gh-release] 릴리스 누락 없음 — 원격 태그 ${#ALL[@]}개 전부 릴리스 있음"
    exit 0
  fi
  ui_info "[gh-release] 릴리스 없는 태그 ${#MISSING[@]}개: ${MISSING[*]}"
  [ "$MODE" = "list" ] && exit 0
  if [ "$LIMIT" -gt 0 ] && [ "${#MISSING[@]}" -gt "$LIMIT" ]; then
    MISSING=("${MISSING[@]: -$LIMIT}")
    ui_info "[gh-release] --missing $LIMIT → 최신 ${#MISSING[@]}개만 처리"
  fi
  TAGS=("${MISSING[@]}")
  ;;
esac

FAILED=0
DONE=0
for tag in "${TAGS[@]}"; do
  ver="${tag#v}"
  notes="$(mktemp)"
  # 절을 못 찾으면(오래된 태그 등) 태그 메시지로 폴백 — 노트 없는 릴리스보다는 낫다.
  gh_changelog_section "$REPO" "$tag" "$ver" >"$notes" 2>/dev/null \
    || git -C "$REPO" tag -l --format='%(contents)' "$tag" >"$notes" 2>/dev/null
  title="$(gh_release_title "$REPO" "$tag" "a2ui-dali")"
  if gh_ensure_release "$REPO" origin "$tag" "$title" "$notes"; then
    case "$GH_RELEASE_STATE" in
    created) ui_ok "[gh-release] 생성: ${GH_RELEASE_URL:-$tag}"; DONE=$((DONE + 1)) ;;
    *) ui_info "[gh-release] $tag 이미 존재 — 유지(멱등)" ;;
    esac
  else
    ui_err "[gh-release] $tag 실패($GH_RELEASE_STATE): ${GH_RELEASE_ERR##*$'\n'}"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$notes"
done

if [ "$FAILED" -gt 0 ]; then
  # 부분 성공도 실패로 보고한다 — 허브가 초록으로 칠하면 아무도 안 본다(release_agent.sh 와 동일 원칙).
  ui_err "[gh-release] $FAILED 건 실패 · $DONE 건 생성"
  exit 1
fi
ui_ok "[gh-release] 완료 — $DONE 건 생성, 나머지는 이미 존재"
exit 0
