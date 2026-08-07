# gh_release.sh — push 된 태그에 GitHub '릴리스'를 만든다. (태그 push 와는 별개의 일이다.)
#
# 왜 별도 단계인가: `git push --atomic origin main vX.Y.Z` 는 **태그만** 만든다. GitHub 의
# Releases 탭은 릴리스 '객체'가 있어야 채워지므로, 태그만 올라간 버전은 사람이 보는 화면에서는
# 릴리스되지 않은 것과 같다 — 그런데 로그는 "릴리스 완료" 라고 말한다. 실측 2026-08-07:
# dalihub/a2ui-dali 에 v0.13.0~v0.18.0 태그가 전부 올라가 있는데 Releases 최신은 v0.12.0
# (2026-07-16)이었고, 그동안 허브는 매 실행을 초록 "vX 릴리스" 로 보고했다. 사용자가 릴리스
# 페이지를 열어보고서야 드러났다 — 로그를 아무리 읽어도 알 수 없는 종류의 거짓이다.
#
# 안전장치 (전부 실측 근거):
#  · **원격에 태그가 없으면 릴리스를 만들지 않는다.** `gh release create` 는 원격에 태그가
#    없으면 기본 브랜치 끝에 태그를 새로 만든다 — push 가 실패했는데 릴리스는 생겨서, 릴리스가
#    가리키는 커밋이 우리가 의도한 커밋이라는 보장이 사라진다(실측 2026-08-03 thorvg v2.4.0:
#    사외 push 실패 + 사외 릴리스 생성). release_agent.sh 가 배운 규칙을 여기서도 지킨다.
#  · **멱등**: 이미 릴리스가 있으면 그대로 둔다. 노트를 덮어쓰지 않는다 — 사람이 손으로 다듬은
#    노트(v0.9.0~v0.12.0 이 그렇다)를 자동 실행이 지우면 안 된다.
#  · **프록시 우회 폴백**: 사내 프록시(10.112.1.184:8080)는 github.com 을 끊는 경우가 있다
#    (실측 2026-08-03: push 6회 연속 HTTP 403 → 프록시 없이 1회 성공). 인증 문제로 오진하기
#    쉬워서 폴백을 기본 동작에 넣는다.
#
# 사용:
#   source "$ROOT/automation/lib/gh_release.sh"
#   gh_changelog_section "$REPO" HEAD 0.18.0 >"$NOTES"
#   gh_ensure_release "$REPO" origin v0.18.0 "$(gh_release_title "$REPO" v0.18.0)" "$NOTES"
# 반환: 0 = 릴리스 있음(created|exists) · 1 = 없음. 상세는 GH_RELEASE_STATE / GH_RELEASE_ERR.

# 프록시를 벗긴 gh — 위 폴백용.
gh_noproxy() {
  env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u ALL_PROXY \
    gh "$@"
}

# gh_url_host_slug <remote-url> → "host slug" (해석 불가면 1)
gh_url_host_slug() {
  local url=$1 host slug
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/.*#\1#; s#^git@([^:]+):.*#\1#')"
  slug="$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')"
  # sed 는 매치가 없으면 입력을 그대로 뱉는다 → "바뀌지 않았다" 를 실패로 본다.
  [ -n "$host" ] && [ -n "$slug" ] && [ "$host" != "$url" ] && [ "$slug" != "$url" ] || return 1
  printf '%s %s\n' "$host" "$slug"
}

# gh_remote_url <repo_dir> <remote(name|url)> — 리모트의 '정체' URL.
# `git remote get-url` 이 아니라 raw config 를 읽는다: get-url 은 insteadOf 를 확장해 전송용
# 경로(사내 미러/로컬 경로)를 돌려주므로, 그걸로 host/slug 를 뽑으면 어느 GitHub 인지 알 수 없다.
gh_remote_url() {
  local url
  url="$(git -C "$1" config --get "remote.$2.url" 2>/dev/null)"
  [ -n "$url" ] || url="$2"
  printf '%s\n' "$url"
}

# gh_remote_has_tag <repo_dir> <remote(name|url)> <tag>
gh_remote_has_tag() {
  local ls
  ls="$(git -C "$1" ls-remote --tags "$2" "refs/tags/$3" 2>/dev/null)"
  [ -n "$ls" ] && return 0
  ls="$(env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u ALL_PROXY \
        git -C "$1" ls-remote --tags "$2" "refs/tags/$3" 2>/dev/null)"
  [ -n "$ls" ]
}

# gh_release_title <repo_dir> <tag> [product]
# 태그 주석 제목을 그대로 쓴다(release.sh 가 이미 사람이 읽을 문장으로 만든다).
gh_release_title() {
  local subj
  subj="$(git -C "$1" tag -l --format='%(contents:subject)' "$2" 2>/dev/null | head -1)"
  subj="${subj% (automated release)}"
  [ -n "$subj" ] || subj="${3:-a2ui-dali} ${2#v}"
  printf '%s\n' "$subj"
}

# gh_changelog_section <repo_dir> <ref> <version> — CHANGELOG.md 의 그 버전 절만 stdout 으로.
# 절을 못 찾으면 1 을 반환하고 아무것도 내지 않는다(호출자가 폴백을 고르게).
gh_changelog_section() {
  git -C "$1" show "$2:CHANGELOG.md" 2>/dev/null | python3 -c '
import re, sys
ver = sys.argv[1]
text = sys.stdin.read()
# "## [0.18.0] — 2026-08-05" 부터 다음 "## [" 직전까지. 헤딩 줄 자체는 릴리스 제목과
# 중복되므로 버린다.
m = re.search(r"^##\s*\[" + re.escape(ver) + r"\][^\n]*\n(.*?)(?=^##\s*\[|\Z)",
              text, re.S | re.M)
if not m:
    sys.exit(1)
body = m.group(1).strip()
if not body:
    sys.exit(1)
print(body)
' "$3"
}

#: gh_ensure_release 결과: created | exists | no-tag | failed
GH_RELEASE_STATE=""
GH_RELEASE_ERR=""
GH_RELEASE_URL=""

# gh_ensure_release <repo_dir> <remote(name|url)> <tag> <title> <notes_file>
gh_ensure_release() {
  local repo=$1 remote=$2 tag=$3 title=$4 notes=$5
  local url hs host slug out i notes_full
  GH_RELEASE_STATE="failed"
  GH_RELEASE_ERR=""
  GH_RELEASE_URL=""

  url="$(gh_remote_url "$repo" "$remote")"
  hs="$(gh_url_host_slug "$url")" || {
    GH_RELEASE_ERR="리모트 URL 해석 실패: $url"
    return 1
  }
  host="${hs%% *}"
  slug="${hs##* }"

  command -v gh >/dev/null 2>&1 || {
    GH_RELEASE_ERR="gh CLI 없음 — $host 릴리스 불가"
    return 1
  }

  # 태그가 원격에 있어야만 릴리스를 만든다(위 안전장치 1).
  if ! gh_remote_has_tag "$repo" "$url" "$tag"; then
    GH_RELEASE_STATE="no-tag"
    GH_RELEASE_ERR="원격 $slug 에 $tag 태그가 없다 — 릴리스를 만들면 엉뚱한 커밋을 가리킨다"
    return 1
  fi

  if GH_HOST="$host" gh release view "$tag" --repo "$host/$slug" >/dev/null 2>&1; then
    GH_RELEASE_STATE="exists"
    GH_RELEASE_URL="https://$host/$slug/releases/tag/$tag"
    return 0
  fi

  # 노트 끝에 CHANGELOG 전문 링크 — 기존 수동 릴리스(v0.9.0~v0.12.0)의 관례를 따른다.
  # 호출자의 파일은 건드리지 않는다(사본에 덧붙인다).
  notes_full="$(mktemp)"
  { [ -s "$notes" ] && cat "$notes"; } >"$notes_full" 2>/dev/null
  printf '\n\n**Full changelog:** https://%s/%s/blob/%s/CHANGELOG.md\n' "$host" "$slug" "$tag" \
    >>"$notes_full"

  for i in 1 2 3; do
    out="$(GH_HOST="$host" gh release create "$tag" --repo "$host/$slug" \
             --title "$title" --notes-file "$notes_full" 2>&1)" && {
      GH_RELEASE_STATE="created"
      GH_RELEASE_URL="$out"
      rm -f "$notes_full"
      return 0
    }
    # 마지막 시도는 프록시 없이 — 사내 프록시가 API 를 끊는 경우가 있다.
    if [ "$i" = "3" ]; then
      out="$(GH_HOST="$host" gh_noproxy release create "$tag" --repo "$host/$slug" \
               --title "$title" --notes-file "$notes_full" 2>&1)" && {
        GH_RELEASE_STATE="created"
        GH_RELEASE_URL="$out"
        rm -f "$notes_full"
        return 0
      }
    fi
    sleep "${GH_RELEASE_RETRY_SLEEP:-3}"
  done

  rm -f "$notes_full"
  GH_RELEASE_STATE="failed"
  GH_RELEASE_ERR="$out"
  return 1
}
