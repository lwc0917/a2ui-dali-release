#!/bin/bash
# golden_publish.sh <reason> — 회전된 골든(baseline)을 이 에이전트 레포에 커밋하고 push.
#
# 왜 필요한가: 골든은 원래 $WORKSPACE/baseline/ 에만 있었고 workspace/ 는 gitignored 라
# 이 머신에만 존재했다. 그래서 (1) 유실되면 다음 실행이 bootstrap 으로 '현재 렌더'를 조용히
# 새 기준선으로 삼아 그 사이 회귀가 영구히 정상으로 굳고, (2) UPSTREAM 자동 골든 승격은
# 사람 승인 없이 일어나는데 사후 감사할 이력이 없었다. thorvg 의 svg_golden_review.sh 와
# 같은 방식으로 레포에 올려 백업 + 변천사 감사를 확보한다.
#
# 파일은 항상 같은 이름을 '덮어쓴다'(누적 아님). 다만 git 특성상 이전 버전은 히스토리에
# 남는다 — 그 이력이 곧 감사 수단이다. 용량이 문제가 되면 GOLDEN_PUBLISH=0 으로 끄거나
# golden 브랜치를 주기적으로 squash 한다(36장 ≈ 2.2MB/회전).
#
# DRY_RUN=1 이면 파일 동기화까지만 하고 커밋/push 는 하지 않는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

REASON="${1:-golden rotation}"
GOLDEN_DIR="$ROOT/golden"
BASE="$WORKSPACE/baseline"

[ "${GOLDEN_PUBLISH:-1}" = "1" ] || { ui_info "[golden] GOLDEN_PUBLISH=0 — 게시 생략"; exit 0; }
[ -d "$BASE" ] || { ui_warn "[golden] baseline 없음 — 게시 생략"; exit 0; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { ui_warn "[golden] 에이전트 레포가 git 이 아님 — 게시 생략"; exit 0; }

ui_step "[golden] 골든 게시 (레포 반영 + push)"

# ── 동기화: 같은 파일명 덮어쓰기 + 사라진 샘플 정리(코퍼스가 줄면 골든도 줄어야 한다) ──
mkdir -p "$GOLDEN_DIR"
rm -f "$GOLDEN_DIR"/*.png
cp "$BASE"/*.png "$GOLDEN_DIR"/ 2>/dev/null
[ -f "$BASE/meta.json" ] && cp "$BASE/meta.json" "$GOLDEN_DIR/"
ui_info "골든 $(ls -1 "$GOLDEN_DIR"/*.png 2>/dev/null | wc -l) 장 동기화 → golden/"

if [ "$DRY_RUN" = "1" ]; then
  ui_ok "[golden] DRY_RUN — 파일만 동기화, 커밋/push 생략"
  exit 0
fi

# ── 커밋 (golden/ 만 스테이징 — 다른 로컬 수정을 끼워 올리지 않는다) ──
git -C "$ROOT" add -A golden || { ui_err "[golden] git add 실패"; exit 1; }
if git -C "$ROOT" diff --cached --quiet -- golden; then
  ui_ok "[golden] 변경 없음 — 커밋 불필요"
  exit 0
fi
GIT_AUTHOR_NAME="$GIT_RELEASE_NAME" GIT_AUTHOR_EMAIL="$GIT_RELEASE_EMAIL" \
  GIT_COMMITTER_NAME="$GIT_RELEASE_NAME" GIT_COMMITTER_EMAIL="$GIT_RELEASE_EMAIL" \
  git -C "$ROOT" commit -q -m "golden: ${DALI_UI_TAG:-?} 기준으로 갱신 ($REASON)" -- golden \
  || { ui_err "[golden] 커밋 실패 — 파일은 갱신됐지만 기록이 남지 않았다"; exit 1; }
ui_ok "커밋: $(git -C "$ROOT" rev-parse --short HEAD)"

# ── push: 사내(origin)·사외(public) 양쪽. thorvg 와 같은 안전장치 —
#    내 커밋 1개만 앞서 있을 때만 직접 push, 아니면 별도 브랜치로 올려 사람이 머지. ──
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { ui_warn "[golden] detached HEAD — push 생략(커밋은 로컬에 있다)"; exit 0; }
FALLBACK="a2ui-golden/update"
ok=""; bad=""
for remote in ${GOLDEN_REMOTES:-origin public}; do
  git -C "$ROOT" remote get-url "$remote" >/dev/null 2>&1 || { ui_info "리모트 '$remote' 없음 — 건너뜀"; continue; }
  if ! git -C "$ROOT" fetch -q "$remote" "$BRANCH" 2>/dev/null; then
    ui_warn "fetch 실패($remote) — 건너뜀(커밋은 로컬에 있다)"; bad="$bad $remote"; continue
  fi
  ahead="$(git -C "$ROOT" rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo 0)"
  behind="$(git -C "$ROOT" rev-list --count HEAD..FETCH_HEAD 2>/dev/null || echo 0)"
  if [ "$ahead" = "0" ]; then
    ui_info "$remote/$BRANCH 에 이미 반영됨"; ok="$ok $remote"; continue
  fi
  if [ "$behind" != "0" ] || [ "$ahead" != "1" ]; then
    ui_warn "직접 push 보류($remote/$BRANCH: ahead=$ahead behind=$behind) — 골든 커밋만 브랜치로 올린다"
    if git -C "$ROOT" push -q "$remote" "HEAD:refs/heads/$FALLBACK" 2>/dev/null; then
      ui_ok "push: $remote/$FALLBACK — PR 로 머지하세요"; ok="$ok $remote($FALLBACK)"
    else
      ui_warn "push 실패($remote/$FALLBACK) — 커밋은 로컬에 남아있다"; bad="$bad $remote"
    fi
    continue
  fi
  if git -C "$ROOT" push -q "$remote" "$BRANCH" 2>/dev/null; then
    ui_ok "push: $remote/$BRANCH"; ok="$ok $remote"
  else
    ui_warn "push 실패($remote/$BRANCH) — 커밋은 로컬에 남아있다"; bad="$bad $remote"
  fi
done
[ -n "$bad" ] && ui_warn "[golden] 반영 실패 리모트:$bad (다음 회전에서 재시도된다)"
ui_ok "[golden] 완료 — 반영:${ok:- 없음}"
exit 0
