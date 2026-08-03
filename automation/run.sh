#!/bin/bash
# run.sh — a2ui-dali 자동 릴리스 오케스트레이터 (hub 진입점).
# dali-ui 새 태그 감지 → 격리 스택 빌드 → a2ui 빌드(+Claude 적응) → conformance
# → 갤러리 렌더 → baseline 비교 → 시각 판정 → GREEN 이면 자동 릴리스 → baseline 회전.
# no-op 외 모든 경로는 report.sh 로 리포트+이미지 산출. exit 0=성공/no-op, 1=실패.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/dali.sh" # incompatible_add (스택 빌드 비호환 기록)
source "$ROOT/automation/lib/repo_publish.sh" # repo_publish (학습/상태를 레포에 반영)

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
# 컴파일 에러로 실패하면 그 (dali-ui, core/adaptor) 조합을 '비호환'으로 기록한다. 업스트림
# 세 레포의 태그가 어긋나 어떤 단일 태그로도 빌드되지 않는 dali-ui 태그가 실재하기 때문이다
# (실측 2026-07-28 v2.5.31.10949 — 근거는 lib/dali.sh 의 비호환 캐시 주석). 기록해 두지 않으면
# 매 주기 수십 분짜리 스택 빌드를 무한 재시도한다. 인프라성 실패(네트워크/디스크)는 기록하지
# 않는다 — 다음 주기에 그냥 성공할 수 있으므로 영구 스킵하면 안 된다.
if ! bash "$ROOT/automation/build_stack.sh" "$CORE_ADAPTOR_TAG" "$DALI_UI_TAG"; then
  if grep -q "error:" "$RUNDIR/stack_build.log" 2>/dev/null; then
    incompatible_add "$DALI_UI_TAG" "$CORE_ADAPTOR_TAG" "stack build compile error"
    ui_warn "[stack] $DALI_UI_TAG + $CORE_ADAPTOR_TAG 을 비호환으로 기록 — 새 core/adaptor 태그가 나올 때까지 재시도하지 않는다"
    # 이 기록은 '사람이 판단할 것'이 아니라 빌드가 증명한 사실이므로 승인 버튼 없이 바로
    # 레포에 올린다. 여기서 안 올리면 워크스페이스가 사라질 때 학습이 같이 사라져(gitignored)
    # 다음 설치가 같은 수십 분짜리 빌드를 다시 태운다. allowlist 는 이 파일 하나뿐이다.
    repo_publish "chore(state): $DALI_UI_TAG + $CORE_ADAPTOR_TAG 을 빌드 비호환으로 기록" \
      state/incompatible.json \
      || ui_warn "[stack] 비호환 기록을 리모트에 올리지 못했다 — 로컬에는 남아있다"
    fail upstream-mismatch "업스트림 태그 비호환 — $DALI_UI_TAG 는 $CORE_ADAPTOR_TAG 로 컴파일되지 않는다"
  fi
  fail infra "격리 DALi 스택 빌드 실패 ($CORE_ADAPTOR_TAG + $DALI_UI_TAG)"
fi

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
AUTO_GOLDEN_UPSTREAM=0   # 업스트림 렌더링 변화를 사람 승인 없이 자동 골든 승격했는지(감사용)
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
      # 업스트림 렌더링 변화로 분류 — 모든 손상 샘플이 UPSTREAM 이다(코드 버그가 하나라도 있으면
      # triage 가 CODE 를 출력해 위 fix 경로를 탄다; any_code). 정책(2026-07-23, 사용자 결정):
      # 이 경우 사람 승인 없이 이번 렌더를 새 골든으로 '자동 승격' 하고 릴리스한다.
      # ⚠️ 리스크: triage(비전 판정)가 미세한 코드 회귀를 UPSTREAM 으로 오분류하면 깨진 렌더가
      #   기준선이 되어 이후 '깨짐 vs 깨짐 → diff 0 → GREEN' 으로 자기은폐된다. 결정적 백스톱과
      #   '불명 → CODE' 보수 기본값이 이를 완화하지만 0 은 아니다. 그래서 무엇을 자동 승격했는지
      #   리포트에 명시해, 사람이 사후에 감사하고 필요하면 baseline 을 재부트스트랩할 수 있게 한다.
      GATE_OVERRIDE=1
      AUTO_GOLDEN_UPSTREAM=1
      AUTO_UP_NAMES=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(", ".join(e["name"] for e in d if e.get("class")=="UPSTREAM"))' "$RUNDIR/compare/triage.json" 2>/dev/null || echo "")
      ui_warn "⚠️ 시각 게이트 RED → 업스트림 렌더링 변화로 분류 — 사람 승인 없이 자동 골든 승격 + 릴리스 (정책). 자동 승격 대상: ${AUTO_UP_NAMES:-?}"
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
  # 골든을 레포에 올려 백업 + 변천사 감사를 남긴다(workspace/ 는 gitignored 라 이 머신에만
  # 있었다). 실패해도 릴리스는 이미 끝났으므로 경고만 하고 실행을 죽이지 않는다.
  bash "$ROOT/automation/golden_publish.sh" "${2:-golden rotation}" \
    || ui_warn "[golden] 게시 실패 — 골든은 로컬에만 갱신됨 (다음 회전에서 재시도)"
}

NEW_VER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("new_version","?"))' \
  "$RUNDIR/release.json" 2>/dev/null || echo "?")

case "$REL_STATUS" in
released)
  # 자동 골든 승격이었는지 커밋 메시지에 남긴다 — 사람 승인 없이 기준선이 바뀐 건이라
  # 나중에 git log 로 골라내 감사할 수 있어야 한다.
  if [ "$AUTO_GOLDEN_UPSTREAM" = "1" ]; then
    rotate_baseline "$NEW_VER" "v$NEW_VER — UPSTREAM 자동 승격(사람 승인 없음): ${AUTO_UP_NAMES:-?}"
  else
    rotate_baseline "$NEW_VER" "v$NEW_VER release"
  fi
  bash "$ROOT/automation/release_check.sh" --done "$DALI_UI_TAG"
  if [ "$AUTO_GOLDEN_UPSTREAM" = "1" ]; then
    REL_NOTE="v$NEW_VER released — 업스트림 렌더링 변화를 사람 승인 없이 자동 골든 승격(${AUTO_UP_NAMES:-?}). 코드 회귀 오분류 대비 감사 필요 — 의심되면 baseline 재부트스트랩."
    bash "$ROOT/automation/report.sh" success "$REL_NOTE"
    ui_warn "[run] 완료 — $REL_NOTE"
  elif [ "$GATE_OVERRIDE" = "1" ]; then
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
    rotate_baseline "$NEW_VER" "v$NEW_VER — 멱등 생략 경로(이미 릴리스됨)"
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

# ── 에이전트 '자기 코드'의 릴리스 대기 알림 ──
# agent.yaml 의 버전이 아직 태그되지 않았다면 마커를 찍는다. 허브의 후속 작업 버튼
# (available_when 이 이 마커에 물려 있다)이 뜨고, 사람이 누르면 태그+push+GitHub 릴리스가
# 사내·사외 양쪽에 나간다. 여기(케이스 분기 뒤)에 두는 이유: `fail` 은 위에서 이미 exit 1 로
# 빠지므로, 막힌 실행에는 이 제안이 아예 뜨지 않는다 — 승인 요청은 '그 결정이 유일한 잔여
# 차단 요인' 일 때만 올린다는 원칙(에이전트 하네스 안티패턴 #6).
bash "$ROOT/automation/release_agent.sh" --check || true
exit 0
