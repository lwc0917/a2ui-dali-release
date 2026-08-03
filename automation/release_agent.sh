#!/bin/bash
# release_agent.sh — 이 '에이전트 자신'의 코드를 태그하고 사내·사외에 릴리스한다.
#
# 대상은 마이그레이션 산출물(a2ui-dali)이 아니라 **에이전트 레포 자체**다. 지금까지 이 일은
# 전부 수동이었고, 그 결과 매니페스트 버전이 태그보다 앞서 나가 있었다(실측 2026-08-03:
# a2ui 는 커밋 2개와 v1.1.0 태그가 사외에 아예 없었고, 다른 두 에이전트도 태그가 매니페스트보다
# 2~3단계 뒤처져 있었다). 무엇이 배포됐는지 리포만 보고는 알 수 없는 상태였다.
#
#   --check     : agent.yaml 의 버전이 아직 태그되지 않았으면 마커를 stdout 에 찍는다.
#                 허브의 후속 작업 버튼이 이 마커(available_when)에 물려 있다. 부작용 없음.
#   --confirmed : 태그 생성 → 사내·사외 push → 양쪽 GitHub 릴리스. 허브 버튼 = 사람 승인이며,
#                 에이전트는 스스로 이 경로를 호출하지 않는다(run.sh 는 --check 만 부른다).
#
# 정직성(안티패턴 #4): 한 단계라도 실패하면 **비-0 으로 끝난다**. 태그는 올라갔는데 릴리스가
# 실패한 경우처럼 부분 성공도 실패로 보고한다 — 허브가 초록으로 칠하면 아무도 안 본다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/repo_publish.sh" # git_push_resilient (프록시 우회 폴백)

MODE="${1:---check}"

manifest_version() { sed -n 's/^version:[[:space:]]*//p' "$ROOT/agent.yaml" | head -1 | tr -d '"'; }
tag_exists() { git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; }
tree_dirty() { [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; }

VER="$(manifest_version)"
TAG="v$VER"

# ── --check: 마커만 (부작용 없음) ─────────────────────────────────────────────
if [ "$MODE" = "--check" ]; then
  [ -n "$VER" ] || exit 0
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
  tag_exists "$TAG" && exit 0                       # 이미 릴리스됨 — 조용히 끝낸다
  if tree_dirty; then
    # 커밋되지 않은 변경이 있는 채로 태그하면 '릴리스된 것'과 '디스크에 있는 것'이 갈린다.
    # 버튼을 띄우는 대신 이유를 보여준다(눌러도 안 되는 버튼보다 낫다).
    ui_warn "[release] $TAG 미태그 상태지만 워킹트리가 깨끗하지 않다 — 커밋 후 다시 제안된다"
    exit 0
  fi
  echo "[agent-release-ready: $TAG]"
  ui_info "[release] 에이전트 코드 $TAG 릴리스 대기 — 허브의 후속 작업 버튼으로 승인하세요"
  exit 0
fi

[ "$MODE" = "--confirmed" ] || { ui_err "[release] 사용법: release_agent.sh --check|--confirmed"; exit 2; }

# ── --confirmed: 실제 릴리스 ─────────────────────────────────────────────────
ui_step "[release] 에이전트 코드 릴리스 $TAG"
[ -n "$VER" ] || { ui_err "[release] agent.yaml 에서 버전을 못 읽었다"; exit 1; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { ui_err "[release] 에이전트 레포가 git 이 아니다"; exit 1; }
if tree_dirty; then
  ui_err "[release] 워킹트리가 깨끗하지 않다 — 무엇이 릴리스되는지 확정할 수 없다"
  git -C "$ROOT" status --short | head -10
  exit 1
fi
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { ui_err "[release] detached HEAD — 릴리스 중단"; exit 1; }

PREV="$(git -C "$ROOT" tag --list 'v*' | sort -V | tail -1)"
if tag_exists "$TAG"; then
  ui_info "[release] 태그 $TAG 는 이미 로컬에 있다 — push/릴리스만 진행(멱등)"
else
  git -C "$ROOT" tag -a "$TAG" -m "$TAG" || { ui_err "[release] 태그 생성 실패"; exit 1; }
  ui_ok "[release] 태그 생성: $TAG"
fi

# 릴리스 노트: 직전 태그 이후 커밋 목록(없으면 최근 10개).
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
{
  echo "## $TAG"
  echo
  if [ -n "$PREV" ] && [ "$PREV" != "$TAG" ]; then
    echo "$PREV 이후 변경:"
    git -C "$ROOT" log --format='- %s' "$PREV..$TAG"
  else
    git -C "$ROOT" log --format='- %s' -10 "$TAG"
  fi
} >"$NOTES_FILE"

# ── push: 브랜치 + 태그를 사내·사외 양쪽에 ──
# push 에 성공한 리모트만 릴리스 대상이 된다. 예전엔 무조건 릴리스를 만들었는데, `gh release
# create` 는 원격에 태그가 없으면 **기본 브랜치 끝에 태그를 새로 만든다** — push 가 실패했는데
# 릴리스는 생겨서, 릴리스가 가리키는 커밋이 우리가 의도한 커밋이라는 보장이 사라진다
# (실측 2026-08-03 thorvg v2.4.0: 사외 push 실패 + 사외 릴리스 생성).
FAILED=""
PUSHED=""
remote_has_tag() { # $1=remote — 원격에 같은 태그가 이미 있으면(재실행) 성공으로 본다
  local ls
  ls="$(git -C "$ROOT" ls-remote --tags "$1" "refs/tags/$TAG" 2>/dev/null \
        || git_noproxy -C "$ROOT" ls-remote --tags "$1" "refs/tags/$TAG" 2>/dev/null)"
  [ -n "$ls" ]
}
for remote in ${AGENT_REPO_REMOTES:-origin public}; do
  git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 || { ui_info "[release] 리모트 '$remote' 없음 — 건너뜀"; continue; }
  if git_push_resilient "$remote" "$BRANCH" "refs/tags/$TAG"; then
    ui_ok "[release] push: $remote ($BRANCH + $TAG)"
    PUSHED="$PUSHED $remote"
  elif remote_has_tag "$remote"; then
    ui_ok "[release] $remote 에 $TAG 가 이미 있다 — push 생략(멱등)"
    PUSHED="$PUSHED $remote"
  else
    ui_err "[release] push 실패: $remote — ${GIT_PUSH_ERR##*$'\n'}"
    FAILED="$FAILED push:$remote"
  fi
done

# ── GitHub 릴리스: 리모트 URL 에서 host/slug 를 뽑아 각각 생성 ──
gh_release() { # $1=remote
  local url host slug out
  url="$(git -C "$ROOT" remote get-url "$1" 2>/dev/null)" || return 1
  host="$(sed -E 's#^https?://([^/]+)/.*#\1#; s#^git@([^:]+):.*#\1#' <<<"$url")"
  slug="$(sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##' <<<"$url")"
  [ -n "$host" ] && [ -n "$slug" ] || return 1
  command -v gh >/dev/null 2>&1 || { ui_err "[release] gh CLI 없음 — $host 릴리스 불가"; return 1; }
  if GH_HOST="$host" gh release view "$TAG" --repo "$host/$slug" >/dev/null 2>&1; then
    ui_info "[release] $host 릴리스 $TAG 이미 존재 — 생략(멱등)"; return 0
  fi
  for i in 1 2 3; do
    out="$(GH_HOST="$host" gh release create "$TAG" --repo "$host/$slug" \
             --title "$TAG" --notes-file "$NOTES_FILE" 2>&1)" && { ui_ok "[release] $out"; return 0; }
    # 프록시가 github.com API 를 끊는 경우가 있다 — 마지막 시도는 프록시 없이.
    if [ "$i" = "3" ]; then
      out="$(env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u ALL_PROXY \
              GH_HOST="$host" gh release create "$TAG" --repo "$host/$slug" \
              --title "$TAG" --notes-file "$NOTES_FILE" 2>&1)" && { ui_ok "[release] $out"; return 0; }
    fi
    sleep 5
  done
  ui_err "[release] $host 릴리스 실패: $out"
  return 1
}
for remote in $PUSHED; do
  gh_release "$remote" || FAILED="$FAILED release:$remote"
done
for remote in ${AGENT_REPO_REMOTES:-origin public}; do
  case " $PUSHED " in *" $remote "*) continue ;; esac
  git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 || continue
  ui_warn "[release] $remote 는 push 가 안 됐으므로 릴리스를 만들지 않는다(커밋이 없는 릴리스 방지)"
done

if [ -n "$FAILED" ]; then
  ui_err "[release] 일부 단계 실패 —$FAILED (부분 성공도 실패로 보고한다)"
  exit 1
fi
ui_ok "[release] $TAG — 사내·사외 push + 릴리스 완료"
exit 0
