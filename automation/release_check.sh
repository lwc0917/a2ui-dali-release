#!/bin/bash
# release_check.sh — dali-ui 새 릴리스 태그 감지 + ledger.
# exit 0 = 새 타깃 ($WORKSPACE/.target 에 기록) / 3 = 할 일 없음 / 2 = 조회 실패
# 사용: release_check.sh            (감지)
#       release_check.sh --done TAG (ledger 기록)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/dali.sh"

if [ "${1:-}" = "--done" ]; then
  ledger_add "${2:?tag required}"
  ui_ok "ledger 기록: $2"
  exit 0
fi

ui_step "[release_check] dali-ui 새 릴리스 태그 확인"
if [ -n "$FORCE_TARGET" ]; then
  TAG="$FORCE_TARGET"
  ui_warn "FORCE_TARGET=$TAG (ledger 무시, 강제 재처리)"
else
  TAG=$(latest_dali_ui_tag) || { ui_err "dali-ui 태그 조회 실패 ($DALI_UI_REPO)"; exit 2; }
  ui_info "최신 dali-ui 태그: $TAG"
  if ledger_has "$TAG"; then
    ui_ok "$TAG 은 이미 처리됨 — 할 일 없음"
    exit 3
  fi
fi

PAIR_WARN="$WORKSPACE/.pair.warn"
: >"$PAIR_WARN"
PAIR=$(pair_core_adaptor_tag "$TAG" 2>"$PAIR_WARN") || {
  [ -s "$PAIR_WARN" ] && ui_err "$(cat "$PAIR_WARN")"
  ui_err "core/adaptor 페어링 실패: $TAG"
  exit 2
}
[ -s "$PAIR_WARN" ] && ui_warn "$(cat "$PAIR_WARN")"

cat >"$WORKSPACE/.target" <<EOF
DALI_UI_TAG=$TAG
CORE_ADAPTOR_TAG=$PAIR
EOF
ui_ok "타깃: dali-ui $TAG + core/adaptor $PAIR"
exit 0
