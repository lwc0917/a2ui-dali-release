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
: "${MAX_FIX_ATTEMPTS:=3}"
# 무인 운영 하드 상한/정리 (P1-9/P1-10): 멈춘 프로세스가 실행을 무한 점유하거나
# runs/ 가 디스크를 무한 증가시키지 않도록.
: "${RENDER_SAMPLE_TIMEOUT:=90}"   # 샘플 1건 렌더 하드 상한(초) — 멈춘 Xvfb/렌더러 격리
: "${CONFORMANCE_TIMEOUT:=900}"    # conformance 실행 하드 상한(초)
: "${KEEP_RUNS:=20}"               # workspace/runs 보관 개수 — 오래된 실행 디렉터리 정리

# 게이트 강도 — hub run 입력(env_from_inputs) 또는 env 로 지정.
#  strict  : 사람 눈에 띄는 변화면 차단   (픽셀 탐지 기본 0.02)
#  normal  : 구조 훼손만 차단 (기본)       (0.05)
#  lenient : 치명 파손만 차단              (0.30)
: "${GATE_LEVEL:=normal}"
case "$GATE_LEVEL" in strict | normal | lenient) : ;; *) GATE_LEVEL=normal ;; esac
# hub 입력은 미지정 시 빈 문자열로 오므로 비어있지 않을 때만 반영
[ -n "${DIFF_THRESHOLD_INPUT:-}" ] && DIFF_THRESHOLD="$DIFF_THRESHOLD_INPUT"
case "${DRY_RUN_INPUT:-}" in true | 1) DRY_RUN=1 ;; esac
# FORCE_ACCEPT: 게이트 RED 를 수동 승인할 '정확한 dali-ui 태그'(예: v2.5.29.10863).
# 값이 현재 타깃 태그와 일치할 때만 1회 오버라이드(target-bound). '1/true' 같은 포괄값은
# 무력화 — 스케줄 inputs/.env 에 남겨둬도 다음(다른) 타깃엔 적용되지 않아 sticky 우회 불가.
: "${FORCE_ACCEPT:=}"
[ -n "${FORCE_ACCEPT_INPUT:-}" ] && FORCE_ACCEPT="$FORCE_ACCEPT_INPUT"
case "$FORCE_ACCEPT" in 1 | true | yes | on | 0 | false | no | off) FORCE_ACCEPT="" ;; esac
export FORCE_ACCEPT
if [ -z "${DIFF_THRESHOLD:-}" ]; then
  case "$GATE_LEVEL" in
  strict) DIFF_THRESHOLD=0.02 ;;
  lenient) DIFF_THRESHOLD=0.30 ;;
  *) DIFF_THRESHOLD=0.05 ;;
  esac
fi

# ── Claude 에스컬레이션 ─────────────────────────────────────────
: "${CLAUDE_MODEL:=opus}"
: "${CLAUDE_TIMEOUT:=900}"
# REVIEW 샘플당 비전 판정 투표수(다수결이 아니라 '하나라도 DAMAGED 면 RED' — fail-closed
# 강화). 1=기존 단일 판정(비용 동일). 2~3 이면 단일 오판(ACCEPTABLE 새는 것)을 줄인다.
: "${JUDGE_VOTES:=1}"

# ── 실행 모드 ───────────────────────────────────────────────────
: "${DRY_RUN:=0}"
: "${FORCE_TARGET:=}"
: "${FORCE_REBUILD:=0}"
: "${JOBS:=$(nproc)}"

# ── 네트워크 가드 (무인 운영: 어떤 git 호출도 hang 하지 않도록) ──
export GIT_TERMINAL_PROMPT=0   # 자격증명 프롬프트로 무한 대기 금지(fresh 머신)
: "${GIT_HTTP_LOW_SPEED_LIMIT:=1000}"  # 전송이 <1KB/s 로
: "${GIT_HTTP_LOW_SPEED_TIME:=30}"     # 30초 지속되면 스톨로 간주해 중단
: "${NET_TIMEOUT:=900}"                # net_retry / ls-remote 각 시도 wall-clock 상한(초)
: "${GIT_SSH_COMMAND:=ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new}"
export GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME NET_TIMEOUT GIT_SSH_COMMAND

export WORKSPACE PREFIX SETENV SRC \
       A2UI_GIT_REMOTE GIT_RELEASE_NAME GIT_RELEASE_EMAIL \
       DALI_UI_REPO DALI_CORE_REPO DALI_ADAPTOR_REPO \
       RENDER_W RENDER_H RENDER_WAIT GATE_LEVEL DIFF_THRESHOLD MAX_FIX_ATTEMPTS \
       RENDER_SAMPLE_TIMEOUT CONFORMANCE_TIMEOUT KEEP_RUNS JUDGE_VOTES \
       CLAUDE_MODEL CLAUDE_TIMEOUT DRY_RUN FORCE_TARGET FORCE_REBUILD JOBS

mkdir -p "$WORKSPACE" "$SRC"
