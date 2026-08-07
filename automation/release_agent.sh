#!/bin/bash
# release_agent.sh — 이 '에이전트 자신'의 코드를 태그하고 **사내에만** 릴리스한다.
#
# 대상은 마이그레이션 산출물(a2ui-dali)이 아니라 **에이전트 레포 자체**다. 지금까지 이 일은
# 전부 수동이었고, 그 결과 매니페스트 버전이 태그보다 앞서 나가 있었다(실측 2026-08-03:
# a2ui 는 커밋 2개와 v1.1.0 태그가 사외에 아예 없었고, 다른 두 에이전트도 태그가 매니페스트보다
# 2~3단계 뒤처져 있었다). 무엇이 배포됐는지 리포만 보고는 알 수 없는 상태였다.
#
# 2026-08-07 정책 변경: **에이전트 코드는 사내 전용**이다. 사외(github.com)로는 push 도
# 릴리스도 하지 않는다(제품 발행 경로는 이 규칙과 무관 — 그건 그대로 사외로 나간다).
# 그래서 사람 승인 버튼도 없앴다: 승인 게이트가 있던 이유는 '바깥 세상에 공개' 였는데,
# 사내 레포에 자기 매니페스트 버전으로 태그를 다는 일은 공개가 아니라 판단이 필요 없는
# **사실**이다(레포 원칙: 판단이 필요 없는 사실은 무인 자동, 사람 판단이 필요한 것만 버튼).
#
#   --auto (기본) : 매니페스트 버전이 미태그 + 워킹트리 깨끗 → 태그 → 사내 push → 사내
#                   GitHub 릴리스. 이미 태그됐거나 트리가 더러우면 아무것도 하지 않는다.
#   --check       : 무엇을 할지만 출력한다(부작용 없음).
#
# 실패해도 실행(run)을 죽이지 않는다: 이건 실행의 본래 일(제품 릴리스/마이그레이션)이 이미
# 끝난 뒤에 남기는 기록이고, 버전은 여전히 미태그로 남으므로 **다음 실행이 자동 재시도**한다.
# 대신 실패는 경고로 반드시 로그에 남긴다(조용한 성공으로 위장하지 않는다).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/repo_publish.sh" # git_push_resilient (프록시 우회 폴백)

MODE="${1:---auto}"
# 사내 전용(정책 2026-08-07). 예전 기본값은 "origin public" 이었다.
RELEASE_REMOTES="${AGENT_REPO_REMOTES:-origin}"

manifest_version() { sed -n 's/^version:[[:space:]]*//p' "$ROOT/agent.yaml" | head -1 | tr -d '"'; }
tag_exists() { git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; }
tree_dirty() { [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; }

VER="$(manifest_version)"
TAG="v$VER"

case "$MODE" in
--auto | --check) : ;;
*)
  ui_err "[release] 사용법: release_agent.sh [--auto|--check]"
  exit 2
  ;;
esac

# ── 할 일이 있는가 (두 모드 공통 판정 — 한 규칙에서만 나온다) ─────────────────
# 판정과 실행이 갈리면 "할 거라고 해놓고 안 하는" 자리가 생긴다.
skip_reason() {
  [ -n "$VER" ] || { echo "agent.yaml 에서 버전을 못 읽었다"; return 0; }
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "에이전트 레포가 git 이 아니다"; return 0; }
  tag_exists "$TAG" && { echo "$TAG 는 이미 태그돼 있다(멱등)"; return 0; }
  # 커밋되지 않은 변경이 있는 채로 태그하면 '릴리스된 것'과 '디스크에 있는 것'이 갈린다.
  tree_dirty && { echo "워킹트리가 깨끗하지 않다 — 커밋 후 다음 실행에서 자동 재시도"; return 0; }
  return 1
}

if REASON="$(skip_reason)"; then
  ui_info "[release] 에이전트 코드 태그 생략 — $REASON"
  exit 0
fi

if [ "$MODE" = "--check" ]; then
  ui_info "[release] 다음 실행에서 $TAG 태그 + 사내 push + 사내 릴리스를 만든다"
  exit 0
fi

# ── --auto: 실제 태그 + 사내 반영 ────────────────────────────────────────────
ui_step "[release] 에이전트 코드 릴리스 $TAG (사내 전용)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || {
  ui_warn "[release] detached HEAD — 태그 생략(다음 실행에서 재시도)"
  exit 0
}

PREV="$(git -C "$ROOT" tag --list 'v*' | sort -V | tail -1)"
git -C "$ROOT" tag -a "$TAG" -m "$TAG" || {
  ui_warn "[release] 태그 생성 실패 — 다음 실행에서 재시도"
  exit 0
}
ui_ok "[release] 태그 생성: $TAG"

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

# ── push: 브랜치 + 태그를 사내에 ──
# push 에 성공한 리모트만 릴리스 대상이 된다. 예전엔 무조건 릴리스를 만들었는데, `gh release
# create` 는 원격에 태그가 없으면 **기본 브랜치 끝에 태그를 새로 만든다** — push 가 실패했는데
# 릴리스는 생겨서, 릴리스가 가리키는 커밋이 우리가 의도한 커밋이라는 보장이 사라진다
# (실측 2026-08-03 thorvg v2.4.0: 사외 push 실패 + 사외 릴리스 생성).
PUSH_FAILED=""
RELEASE_FAILED=""
PUSHED=""
remote_has_tag() { # $1=remote — 원격에 같은 태그가 이미 있으면(재실행) 성공으로 본다
  local ls
  ls="$(git -C "$ROOT" ls-remote --tags "$1" "refs/tags/$TAG" 2>/dev/null \
        || git_noproxy -C "$ROOT" ls-remote --tags "$1" "refs/tags/$TAG" 2>/dev/null)"
  [ -n "$ls" ]
}
for remote in $RELEASE_REMOTES; do
  git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 || { ui_info "[release] 리모트 '$remote' 없음 — 건너뜀"; continue; }
  if git_push_resilient "$remote" "$BRANCH" "refs/tags/$TAG"; then
    ui_ok "[release] push: $remote ($BRANCH + $TAG)"
    PUSHED="$PUSHED $remote"
  elif remote_has_tag "$remote"; then
    ui_ok "[release] $remote 에 $TAG 가 이미 있다 — push 생략(멱등)"
    PUSHED="$PUSHED $remote"
  else
    ui_err "[release] push 실패: $remote — ${GIT_PUSH_ERR##*$'\n'}"
    PUSH_FAILED="$PUSH_FAILED $remote"
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
  gh_release "$remote" || RELEASE_FAILED="$RELEASE_FAILED $remote"
done
for remote in $RELEASE_REMOTES; do
  case " $PUSHED " in *" $remote "*) continue ;; esac
  git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 || continue
  ui_warn "[release] $remote 는 push 가 안 됐으므로 릴리스를 만들지 않는다(커밋이 없는 릴리스 방지)"
done

# push 실패와 릴리스 실패는 결과가 다르다 — 되돌림 여부가 갈린다.
#
#  · push 실패  = 태그가 사내에 없다 → **로컬 태그를 지운다**. 안 지우면 다음 실행의
#    '이미 태그됨' 판정에 걸려 재시도가 영영 안 일어나고, 태그는 로컬에만 있는 채 굳는다.
#  · 릴리스 실패 = 태그는 이미 사내에 올라갔다 → **태그를 유지한다**. 여기서 되돌리면
#    GitHub 이 아닌 리모트(릴리스 개념이 없는 git 서버)에서는 매 실행이 태그를 만들고
#    지우기를 무한 반복한다. 목적(무엇이 배포됐는지 태그로 안다)은 이미 달성됐다.
if [ -n "$PUSH_FAILED" ]; then
  git -C "$ROOT" tag -d "$TAG" >/dev/null 2>&1
  ui_warn "[release] push 실패 —$PUSH_FAILED · 로컬 태그 되돌림, 다음 실행에서 자동 재시도"
  ui_warn "[release] 에이전트 코드 $TAG 는 아직 사내에 반영되지 않았다"
  exit 0 # 실행 본연의 일은 이미 끝났다 — 기록 실패로 run 을 빨갛게 만들지 않는다
fi
if [ -n "$RELEASE_FAILED" ]; then
  ui_warn "[release] $TAG 태그는 사내에 반영됐지만 GitHub 릴리스 생성 실패 —$RELEASE_FAILED"
  exit 0
fi
ui_ok "[release] $TAG — 사내 push + 릴리스 완료"
exit 0
