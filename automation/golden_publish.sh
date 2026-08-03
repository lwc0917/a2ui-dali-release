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
source "$ROOT/automation/lib/repo_publish.sh"

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

# ── 커밋 + push: 공통 헬퍼(automation/lib/repo_publish.sh)가 allowlist 스테이징·
#    ahead/behind 가드·프록시 우회 폴백을 한 곳에서 담당한다. 예전엔 이 블록이 여기에
#    통째로 복붙돼 있었고, 그래서 프록시 우회 같은 개선이 이 스크립트에만 적용됐다. ──
REPO_PUBLISH_FALLBACK="a2ui-golden/update" \
AGENT_REPO_REMOTES="${GOLDEN_REMOTES:-origin public}" \
  repo_publish "golden: ${DALI_UI_TAG:-?} 기준으로 갱신 ($REASON)" golden
rc=$?
[ "$rc" = "0" ] || ui_warn "[golden] 일부 리모트에 반영하지 못했다 — 커밋은 로컬에 있다"
ui_ok "[golden] 완료"
exit 0
