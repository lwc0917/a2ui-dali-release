#!/bin/bash
# build_a2ui.sh checkout [ref]  — a2ui-dali 소스 준비 (기본 origin/main; 태그도 가능)
# build_a2ui.sh build           — 클린 빌드 (fix 루프가 반복 호출; 워킹트리 수정 보존)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/net.sh"

REPO="$SRC/a2ui-dali"

case "${1:?checkout|build}" in
checkout)
  REF="${2:-main}"
  ui_step "[a2ui] 소스 준비: $REF ($A2UI_GIT_REMOTE)"
  # 손상/부분 클론은 재클론으로 자가복구(무인 운영: 매 주기 영구 실패 방지)
  if [ -d "$REPO/.git" ] && ! git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    ui_warn "a2ui-dali: 손상/부분 클론 감지 — 재클론"
    rm -rf "$REPO"
  fi
  if [ -d "$REPO/.git" ]; then
    git -C "$REPO" remote set-url origin "$A2UI_GIT_REMOTE" # .env 변경 반영
    if ! net_retry git -C "$REPO" fetch --tags --force origin; then
      ui_warn "a2ui-dali: fetch 실패 — 재클론으로 자가복구"
      rm -rf "$REPO"
      net_retry git clone "$A2UI_GIT_REMOTE" "$REPO" || { ui_err "clone 실패"; exit 1; }
    fi
  else
    net_retry git clone "$A2UI_GIT_REMOTE" "$REPO" || { ui_err "clone 실패"; exit 1; }
  fi
  if [ "$REF" = "main" ]; then
    git -C "$REPO" checkout -f -B main origin/main || exit 1
  else
    git -C "$REPO" checkout -f "$REF" || exit 1
  fi
  git -C "$REPO" clean -fdx >/dev/null
  ui_ok "체크아웃: $(git -C "$REPO" log -1 --format='%h %s')"
  ;;
build)
  LOG="${RUNDIR:-$WORKSPACE}/a2ui_build.log"
  ui_step "[a2ui] 빌드 (log: $LOG)"
  [ -f "$SETENV" ] || { ui_err "setenv 없음 — build_stack 먼저"; exit 1; }
  ( . "$SETENV" && cd "$REPO" \
      && rm -rf build \
      && cmake -S . -B build \
      && cmake --build build -j"$JOBS" ) >"$LOG" 2>&1 \
    || { ui_err "a2ui-dali 빌드 실패 (tail: $(tail -3 "$LOG" | tr '\n' ' '))"; exit 1; }
  ui_ok "빌드 성공"
  ;;
*)
  ui_err "unknown mode: $1"
  exit 2
  ;;
esac
