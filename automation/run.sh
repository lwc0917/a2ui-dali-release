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

# ── 환경 사전점검: 없으면 무엇이 안 되는지 먼저 알려준다(빌드 한참 뒤에 깨지는 대신). ──
# PREFLIGHT_SKIP=1 로 우회 가능(오프라인 리허설/셀프테스트용).
if [ "${PREFLIGHT_SKIP:-0}" != "1" ]; then
  bash "$ROOT/automation/preflight.sh" || { ui_err "[run] 환경 미충족 — 중단"; exit 1; }
fi

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
  bash "$ROOT/automation/fix.sh" build; frc=$?
  # 3 = LLM 을 아예 쓸 수 없었던 경우(사용량 한도 등). '고치지 못했다' 와 구분해 보고해야
  # 사람이 '재시도하면 될 일' 임을 안다.
  [ "$frc" -eq 3 ] && fail llm-unavailable "LLM 호출 불가로 코드 적응을 시도하지 못함 — 잠시 후 재실행"
  [ "$frc" -ne 0 ] && fail build-break "새 dali-ui API 적응 실패 (fix 예산 소진)"
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
    # ── [triage] RED 의 원인을 가른다 ────────────────────────────────────────
    # 화면이 달라진 데는 두 가지 다른 이유가 있고, 대응이 정반대다:
    #   CODE     = 우리 렌더러가 새 dali-ui 에서 잘못 그림 → AI 가 src/ 를 고칠 문제.
    #   UPSTREAM = 플랫폼 렌더링 자체가 바뀜 → 기준선을 갱신할지 '사람'이 결정할 문제.
    # 예전엔 둘을 구분하지 않고 전부 사람에게 "이걸 골든으로 승인할래?" 라고 물었다.
    # 그래서 코드 버그도 승인 한 번이면 깨진 화면이 새 기준선이 될 수 있었다.
    # judge 와 같은 tee: triage 의 진행/근거 로그(ui_*)는 stdout 으로 나가는데 명령치환이
    # 통째로 삼켜버려, run.log 에는 분류 '결과'만 남고 '왜' 가 사라졌었다(실측). 사람이 콘솔에서
    # 분류 근거를 볼 수 있어야 오분류를 잡아낼 수 있으므로 stderr 로 흘려보낸다.
    TRIAGE=$(bash "$ROOT/automation/triage.sh" "$RUNDIR/compare" | tee /dev/stderr | tail -1)
    if [ "$TRIAGE" = "CODE" ]; then
      ui_step "[fix] 시각 회귀가 코드 문제로 분류됨 — AI 수정 루프 진입"
      bash "$ROOT/automation/fix.sh" visual; vrc=$?
      [ "$vrc" -eq 3 ] && fail llm-unavailable "LLM 호출 불가로 시각 회귀 수정을 시도하지 못함 — 잠시 후 재실행"
      if [ "$vrc" -eq 0 ]; then
        # fix.sh visual 은 게이트가 실제로 GREEN 이 된 경우에만 0 을 반환한다
        # (재빌드 → 전수 재렌더 → 재비교 → 재판정까지 통과). 그 렌더가 릴리스에 실린다.
        GATE=GREEN
        ui_ok "시각 회귀 AI 수정 성공 — 게이트 GREEN 재확인, 릴리스 진행"
      else
        fail gate-damage "시각 게이트 RED — 코드 수정 시도했으나 미해결 (리포트의 원인 분류/시도 내역 참조)"
      fi
    else
      # 업스트림 렌더링 변화로 분류 → 코드를 뜯어고칠 일이 아니다. 사람이 side-by-side 를
      # 보고 골든 갱신을 승인하면 force_accept 재실행으로 릴리스된다.
      fail gate-damage "시각 게이트 RED — 업스트림 렌더링 변화로 분류, 골든 갱신 승인 필요 (리포트 참조)"
    fi
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
