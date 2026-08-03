# repo_publish.sh — 이 에이전트 레포에 '자기 상태/산출물'을 커밋하고 사내·사외로 올린다.
#
# 왜 공통 함수인가: golden_publish.sh 가 쓰던 커밋+push 루틴(안전장치 포함)을 비호환 캐시
# 게시와 릴리스 태그 push 도 똑같이 필요로 한다. 규칙이 스크립트마다 갈리면 어떤 경로는
# 안전장치가 빠진다 — 한 곳에서만 정의한다.
#
# 안전장치 (전부 실측 근거):
#  · **경로 allowlist 로만 스테이징**한다. `git add -A` 는 절대 쓰지 않는다 — 실행이 워킹트리에
#    남긴 다른 산출물까지 딸려 올라간다(실측 2026-08-03, thorvg: 실행 한 번에 렌더 PNG 500장이
#    수정 상태로 남아 있었다).
#  · 내 커밋 1개만 앞서 있을 때만 브랜치에 직접 push. 그 외(behind 이거나 여러 커밋)는 별도
#    브랜치로 올려 사람이 PR 로 머지한다 — 무인 실행이 남의 커밋 위에 덮어쓰지 않는다.
#  · **프록시 우회 폴백.** 사내 프록시(10.112.1.184:8080)는 큰 push 를 `HTTP 403` /
#    `send-pack: unexpected disconnect` 로 끊는다(실측 2026-08-03: 1.94MB push 6회 연속 실패 →
#    프록시 없이 1회 성공). 인증 문제로 오진하기 쉬워서 폴백을 기본 동작에 넣는다.
#
# 사용:
#   source "$ROOT/automation/lib/repo_publish.sh"
#   repo_publish "chore(state): ..." state/incompatible.json
# 반환: 0 = 반영 완료(또는 변경 없음) · 1 = 커밋은 됐으나 어느 리모트에도 못 올림

# 프록시를 벗긴 git — 위 폴백용.
git_noproxy() {
  env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u ALL_PROXY \
    git "$@"
}

# git_push_resilient <remote> <refspec...> — 프록시로 먼저, 실패하면 프록시 없이 한 번 더.
# 실패 원문은 절대 삼키지 않는다: 예전엔 `2>/dev/null` 로 버려서, 프록시가 끊은 건지 태그가
# 이미 있는 건지 권한이 없는 건지 로그만 보고는 알 수 없었다(실측 2026-08-03 — 원인을 찾으려고
# --no-thin 으로 재현해야 HTTP 403 이 드러났다). 마지막 에러를 GIT_PUSH_ERR 에 남긴다.
GIT_PUSH_ERR=""
git_push_resilient() {
  local out
  out="$(git -C "$ROOT" push "$@" 2>&1)" && return 0
  GIT_PUSH_ERR="$out"
  out="$(git_noproxy -C "$ROOT" push "$@" 2>&1)" && return 0
  GIT_PUSH_ERR="$out"
  return 1
}

# repo_publish <commit_msg> <path...>
repo_publish() {
  local msg="$1"
  shift
  [ $# -gt 0 ] || { ui_warn "[publish] 대상 경로가 없다 — 게시 생략"; return 0; }

  [ "${DRY_RUN:-0}" = "1" ] && { ui_ok "[publish] DRY_RUN — 커밋/push 생략"; return 0; }
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || { ui_warn "[publish] 에이전트 레포가 git 이 아님 — 게시 생략"; return 0; }

  # allowlist 경로만 스테이징(삭제 포함). 다른 dirty 파일은 손대지 않는다.
  git -C "$ROOT" add -- "$@" || { ui_err "[publish] git add 실패"; return 1; }
  if git -C "$ROOT" diff --cached --quiet -- "$@"; then
    ui_info "[publish] 변경 없음 — 커밋 불필요"
    return 0
  fi
  GIT_AUTHOR_NAME="${GIT_RELEASE_NAME:-agent}" GIT_AUTHOR_EMAIL="${GIT_RELEASE_EMAIL:-agent@local}" \
    GIT_COMMITTER_NAME="${GIT_RELEASE_NAME:-agent}" GIT_COMMITTER_EMAIL="${GIT_RELEASE_EMAIL:-agent@local}" \
    git -C "$ROOT" commit -q -m "$msg" -- "$@" \
    || { ui_err "[publish] 커밋 실패 — 파일은 갱신됐지만 기록이 남지 않았다"; return 1; }
  ui_ok "[publish] 커밋: $(git -C "$ROOT" rev-parse --short HEAD)"

  repo_push_current_branch
}

# repo_push_current_branch — 현재 브랜치를 사내·사외에 올린다(위 안전장치 적용).
# 커밋을 이미 만든 뒤 호출한다. 태그는 올리지 않는다(release_agent.sh 가 따로 처리).
repo_push_current_branch() {
  local branch fallback ok bad remote ahead behind
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$branch" ] && [ "$branch" != "HEAD" ] \
    || { ui_warn "[publish] detached HEAD — push 생략(커밋은 로컬에 있다)"; return 1; }
  fallback="${REPO_PUBLISH_FALLBACK:-agent-state/update}"
  ok=""; bad=""
  for remote in ${AGENT_REPO_REMOTES:-origin public}; do
    git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 \
      || { ui_info "[publish] 리모트 '$remote' 없음 — 건너뜀"; continue; }
    if ! git -C "$ROOT" fetch -q "$remote" "$branch" 2>/dev/null \
      && ! git_noproxy -C "$ROOT" fetch -q "$remote" "$branch" 2>/dev/null; then
      ui_warn "[publish] fetch 실패($remote) — 건너뜀(커밋은 로컬에 있다)"; bad="$bad $remote"; continue
    fi
    ahead="$(git -C "$ROOT" rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo 0)"
    behind="$(git -C "$ROOT" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)"
    if [ "$ahead" = "0" ]; then
      ui_info "[publish] $remote/$branch 에 이미 반영됨"; ok="$ok $remote"; continue
    fi
    if [ "$behind" != "0" ] || [ "$ahead" != "1" ]; then
      ui_warn "[publish] 직접 push 보류($remote/$branch: ahead=$ahead behind=$behind) — 브랜치로 올린다"
      if git_push_resilient "$remote" "HEAD:refs/heads/$fallback"; then
        ui_ok "[publish] push: $remote/$fallback — PR 로 머지하세요"; ok="$ok $remote($fallback)"
      else
        ui_warn "[publish] push 실패($remote/$fallback) — 커밋은 로컬에 남아있다"; bad="$bad $remote"
      fi
      continue
    fi
    if git_push_resilient "$remote" "$branch"; then
      ui_ok "[publish] push: $remote/$branch"; ok="$ok $remote"
    else
      ui_warn "[publish] push 실패($remote/$branch) — 커밋은 로컬에 남아있다"; bad="$bad $remote"
    fi
  done
  [ -n "$bad" ] && ui_warn "[publish] 반영 실패 리모트:$bad (다음 실행에서 재시도된다)"
  [ -n "$ok" ] || return 1
  ui_ok "[publish] 반영:$ok"
  return 0
}
