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
PAIR_WARN="$WORKSPACE/.pair.warn"
: >"$PAIR_WARN"
if [ -n "$FORCE_TARGET" ]; then
  # 사람이 명시한 태그 — exact 페어가 없으면 이하 최신으로 폴백 허용
  TAG="$FORCE_TARGET"
  ui_warn "FORCE_TARGET=$TAG (ledger 무시, 강제 재처리)"
  PAIR=$(pair_core_adaptor_tag "$TAG" 2>"$PAIR_WARN") || {
    [ -s "$PAIR_WARN" ] && ui_err "$(cat "$PAIR_WARN")"
    ui_err "core/adaptor 페어링 실패: $TAG"
    exit 2
  }
  [ -s "$PAIR_WARN" ] && ui_warn "$(cat "$PAIR_WARN")"
else
  # 자동 경로 — '정확한 페어가 존재하는' 최신 미처리 태그만 타깃.
  # (dali-ui 가 core/adaptor 보다 앞서 태그되면 그 태그는 페어가 나올 때까지 대기 —
  #  실측: dali-ui 2.5.30 을 core 2.5.30 으로 빌드하면 컴파일 실패)
  SEL=$(select_processable_target 2>"$PAIR_WARN")
  rc=$?
  [ -s "$PAIR_WARN" ] && while IFS= read -r line; do ui_info "$line"; done <"$PAIR_WARN"
  if [ $rc -eq 2 ]; then
    ui_err "dali-ui/core/adaptor 태그 조회 실패"
    exit 2
  elif [ $rc -ne 0 ]; then
    ui_ok "처리 가능한 새 dali-ui 태그 없음 — 할 일 없음"
    exit 3
  fi
  TAG=${SEL%% *}
  PAIR=${SEL##* }
fi

cat >"$WORKSPACE/.target" <<EOF
DALI_UI_TAG=$TAG
CORE_ADAPTOR_TAG=$PAIR
EOF
ui_ok "타깃: dali-ui $TAG + core/adaptor $PAIR"
exit 0
