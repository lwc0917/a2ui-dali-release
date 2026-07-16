#!/bin/bash
# run.sh — a2ui-dali 자동 릴리스 오케스트레이터 (hub 진입점).
# dali-ui 새 태그 감지 → 격리 스택 빌드 → a2ui 빌드(+Claude 적응) → conformance
# → 갤러리 렌더 → baseline 비교 → 시각 판정 → GREEN 이면 자동 릴리스 → baseline 회전.
# no-op 외 모든 경로는 report.sh 로 리포트+이미지 산출. exit 0=성공/no-op, 1=실패.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"

RUN_ID="${AGENTHUB_RUN_ID:-local-$(date +%Y%m%d-%H%M%S)-$$}"
export RUNDIR="$WORKSPACE/runs/$RUN_ID"
mkdir -p "$RUNDIR"

fail() { # $1=outcome $2=detail
  ui_err "$2"
  bash "$ROOT/automation/report.sh" "$1" "$2" || true
  exit 1
}

# ── [rotate] 오래된 실행 디렉터리 정리 (P1-9: 무인 운영 시 runs/ 무한 증가 방지) ──
# workspace/runs 하위에서 최신 KEEP_RUNS 개만 남기고 삭제. 방금 만든 현재 실행은 mtime 이
# 가장 최신이라 항상 보존. 경로 가드(case)로 workspace/runs 밖은 절대 건드리지 않는다.
prune_old_runs() {
  local base="$WORKSPACE/runs" keep="${KEEP_RUNS:-20}" d
  [ -d "$base" ] || return 0
  [ "$keep" -ge 1 ] 2>/dev/null || return 0   # keep<1 은 현재 실행까지 지울 위험 → 스킵
  ls -1dt "$base"/*/ 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in
    "$base"/*/) rm -rf "$d" ;;
    esac
  done
}
prune_old_runs

ui_step "[run] a2ui-dali 자동 릴리스 워크플로 시작 (run=$RUN_ID)"
ui_info "게이트 설정: level=$GATE_LEVEL · 픽셀 임계 $DIFF_THRESHOLD · DRY_RUN=$DRY_RUN · FORCE_ACCEPT=${FORCE_ACCEPT:-0}"
printf 'GATE_LEVEL=%s\nDIFF_THRESHOLD=%s\n' "$GATE_LEVEL" "$DIFF_THRESHOLD" >"$RUNDIR/gate.env"

# ── [lock] 동시 실행 금지 (hub single_flight + 이중 안전벨트) ──
exec 9>"$WORKSPACE/.run.lock"
flock -n 9 || { ui_err "다른 실행이 진행 중 — 종료"; exit 1; }

# ── [detect] ──
bash "$ROOT/automation/release_check.sh"
rc=$?
if [ "$rc" -eq 3 ]; then
  bash "$ROOT/automation/report.sh" no-op "" || true
  ui_ok "[run] 새 릴리스 없음 — 종료 (no-op)"
  exit 0
fi
[ "$rc" -eq 0 ] || fail infra "release_check 실패 (rc=$rc — 태그 조회/페어링)"
cp "$WORKSPACE/.target" "$RUNDIR/.target"
set -a
# shellcheck disable=SC1091
source "$WORKSPACE/.target" # DALI_UI_TAG, CORE_ADAPTOR_TAG
set +a

# ── [boot] baseline 없으면 부트스트랩만 하고 종료 (다음 주기가 새 태그 처리) ──
if [ ! -f "$WORKSPACE/baseline/meta.json" ]; then
  ui_warn "baseline 없음 — 이번 실행은 부트스트랩(현행 릴리스 기준선 구축)만 수행"
  exec bash "$ROOT/automation/bootstrap.sh"
fi

# ── [stack] ──
bash "$ROOT/automation/build_stack.sh" "$CORE_ADAPTOR_TAG" "$DALI_UI_TAG" \
  || fail infra "격리 DALi 스택 빌드 실패 ($CORE_ADAPTOR_TAG + $DALI_UI_TAG)"

# ── [a2ui build] (+Claude 적응 루프) ──
bash "$ROOT/automation/build_a2ui.sh" checkout main || fail infra "a2ui-dali 소스 준비 실패"
if ! bash "$ROOT/automation/build_a2ui.sh" build; then
  bash "$ROOT/automation/fix.sh" build \
    || fail build-break "새 dali-ui API 적응 실패 (fix 예산 소진)"
fi

# ── [conformance] ──
if ! bash "$ROOT/automation/conformance.sh"; then
  bash "$ROOT/automation/fix.sh" conformance \
    || fail conformance "conformance 미해결 (fix 예산 소진)"
fi

# ── [render] ──
bash "$ROOT/automation/render.sh" "$RUNDIR/new" || fail render "갤러리 코퍼스 렌더 실패"

# ── [compare] ──
bash "$ROOT/automation/compare.sh" "$WORKSPACE/baseline" "$RUNDIR/new" "$RUNDIR/compare" \
  || fail infra "픽셀 비교 실패"

# ── [judge] ── (judge 의 진행 로그는 stderr 로 그대로, 마지막 줄만 판정)
GATE=$(bash "$ROOT/automation/judge.sh" "$RUNDIR/compare" | tee /dev/stderr | tail -1)
GATE_OVERRIDE=0
if [ "$GATE" != "GREEN" ]; then
  # FORCE_ACCEPT 오버라이드: RED 를 사람이 side-by-side 이미지로 확인하고 의도된 변화로
  # 승인했을 때만. 값이 '현재 dali-ui 타깃 태그와 정확히 일치'해야 1회 적용된다(target-bound)
  # — 포괄값(1/true)은 load_env 에서 무력화되므로, 스케줄/.env 에 남겨둬도 다음(다른)
  #   타깃엔 절대 적용되지 않아 sticky 우회가 불가능하다.
  if [ -n "${FORCE_ACCEPT:-}" ] && [ "$FORCE_ACCEPT" = "$DALI_UI_TAG" ]; then
    GATE_OVERRIDE=1
    ui_warn "⚠️ 게이트 RED 를 FORCE_ACCEPT=$DALI_UI_TAG 로 수동 승인 — 릴리스 진행 (판정 기록 유지)"
  else
    [ -n "${FORCE_ACCEPT:-}" ] \
      && ui_warn "FORCE_ACCEPT='$FORCE_ACCEPT' 가 타깃 '$DALI_UI_TAG' 과 불일치 — 오버라이드 무시(차단)"
    fail gate-damage "시각 게이트 RED — 손상 판정 샘플 존재 (리포트 참조)"
  fi
else
  ui_ok "게이트 GREEN"
fi

# ── [release] ──
bash "$ROOT/automation/release.sh" || fail release-push "릴리스 커밋/태그/push 실패"
REL_STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","?"))' \
  "$RUNDIR/release.json" 2>/dev/null || echo "?")

rotate_baseline() {
  local new_ver=$1
  rm -rf "$WORKSPACE/baseline"
  mkdir -p "$WORKSPACE/baseline"
  cp "$RUNDIR/new/"*.png "$WORKSPACE/baseline/"
  python3 -c '
import json, sys, datetime
json.dump({"dali_ui": sys.argv[2], "core_adaptor": sys.argv[3], "a2ui_version": sys.argv[4],
           "date": datetime.date.today().isoformat()},
          open(sys.argv[1], "w"), indent=1)
' "$WORKSPACE/baseline/meta.json" "$DALI_UI_TAG" "$CORE_ADAPTOR_TAG" "$new_ver"
  ui_ok "baseline 회전 → $DALI_UI_TAG 기준"
}

NEW_VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("new_version","?"))' \
  "$RUNDIR/release.json" 2>/dev/null || echo "?")

case "$REL_STATUS" in
released)
  rotate_baseline "$NEW_VER"
  bash "$ROOT/automation/release_check.sh" --done "$DALI_UI_TAG"
  if [ "$GATE_OVERRIDE" = "1" ]; then
    REL_NOTE="v$NEW_VER released — ⚠️ 게이트 RED 를 FORCE_ACCEPT 로 수동 승인(손상 판정을 무시하고 릴리스)"
    bash "$ROOT/automation/report.sh" success "$REL_NOTE"
    ui_warn "[run] 완료 — $REL_NOTE"
  else
    bash "$ROOT/automation/report.sh" success "v$NEW_VER released"
    ui_ok "[run] 완료 — v$NEW_VER 릴리스"
  fi
  ;;
skipped)
  if [ "$DRY_RUN" = "1" ]; then
    ui_ok "[run] 완료 — 멱등 생략 (DRY_RUN: baseline/ledger 미변경)"
  else
    rotate_baseline "$NEW_VER"
    bash "$ROOT/automation/release_check.sh" --done "$DALI_UI_TAG"
    ui_ok "[run] 완료 — 멱등 생략 (이미 릴리스됨)"
  fi
  bash "$ROOT/automation/report.sh" skipped ""
  ;;
dry-run)
  bash "$ROOT/automation/report.sh" dry-run ""
  ui_ok "[run] 완료 — DRY RUN (baseline/ledger 미변경)"
  ;;
*)
  fail infra "release.json 해석 불가 (status=$REL_STATUS)"
  ;;
esac
exit 0
