# load_env.sh — a2ui-dali-release 자동화 공통 env 로더.
# 스크립트 맨 위에서:
#   set -uo pipefail
#   ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   source "$ROOT/automation/lib/load_env.sh"

# ROOT = 이 에이전트 레포 루트. 이 파일 위치: $ROOT/automation/lib/load_env.sh
if [ -z "${ROOT:-}" ]; then
  _SELF="${BASH_SOURCE[0]}"
  ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
  export ROOT
fi

# .env 로드 (있으면). set -a 로 export.
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

# 동적 산출물(격리 스택 / baseline / ledger / 락) 루트.
: "${WORKSPACE:=$ROOT/workspace}"
# 격리 DALi 스택 설치 prefix — 사용자의 dali-env/opt 는 절대 건드리지 않는다.
: "${PREFIX:=$WORKSPACE/prefix}"
: "${SETENV:=$WORKSPACE/setenv}"
: "${SRC:=$WORKSPACE/src}"

# ── 릴리스 대상 (github.com/dalihub/a2ui-dali) ──────────────────
: "${A2UI_GIT_REMOTE:=git@github.com:dalihub/a2ui-dali.git}"
: "${GIT_RELEASE_NAME:=woochan lee}"
: "${GIT_RELEASE_EMAIL:=lwcc0917@gmail.com}"

# ── 업스트림 소스 (읽기 전용 소비 — 절대 수정/push 안 함) ────────
: "${DALI_UI_REPO:=https://github.com/dalihub/dali-ui.git}"
: "${DALI_CORE_REPO:=https://github.com/dalihub/dali-core.git}"
: "${DALI_ADAPTOR_REPO:=https://github.com/dalihub/dali-adaptor.git}"

# ── 게이트 (데스크톱 prev vs new 회귀 — web-parity 판정 아님) ────
: "${RENDER_W:=480}"
: "${RENDER_H:=1280}"
: "${RENDER_WAIT:=5}"
: "${DIFF_THRESHOLD:=0.05}"
: "${MAX_FIX_ATTEMPTS:=3}"

# ── Claude 에스컬레이션 ─────────────────────────────────────────
: "${CLAUDE_MODEL:=opus}"
: "${CLAUDE_TIMEOUT:=900}"

# ── 실행 모드 ───────────────────────────────────────────────────
: "${DRY_RUN:=0}"
: "${FORCE_TARGET:=}"
: "${FORCE_REBUILD:=0}"
: "${JOBS:=$(nproc)}"

export WORKSPACE PREFIX SETENV SRC \
       A2UI_GIT_REMOTE GIT_RELEASE_NAME GIT_RELEASE_EMAIL \
       DALI_UI_REPO DALI_CORE_REPO DALI_ADAPTOR_REPO \
       RENDER_W RENDER_H RENDER_WAIT DIFF_THRESHOLD MAX_FIX_ATTEMPTS \
       CLAUDE_MODEL CLAUDE_TIMEOUT DRY_RUN FORCE_TARGET FORCE_REBUILD JOBS

mkdir -p "$WORKSPACE" "$SRC"
