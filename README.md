# a2ui-dali-release

> **한 줄 요약** — [dali-ui](https://github.com/dalihub/dali-ui) 에 새 릴리스 태그가 생기면
> 격리 스택 재빌드 → [a2ui-dali](https://github.com/dalihub/a2ui-dali) 빌드(깨지면 Claude 가 코드 적응)
> → 갤러리 코퍼스 36종을 이전 릴리스 렌더와 비교 → 심각한 훼손이 없으면 **자동 릴리스**
> (버전 범프 + `vX.Y.Z` 태그 + push). 사람은 [uifw-agent-hub](../../uifw-agent-hub) run 페이지에서
> 이미지 포함 리포트만 확인하면 된다.

**One-liner (EN)** — Unattended release agent: when dali-ui publishes a new tag, it rebuilds an
isolated DALi stack, builds a2ui-dali (delegating API-drift fixes to headless Claude), renders the
36-sample gallery corpus on the Ubuntu desktop backend, compares against the previous release's
renders, and — if nothing is seriously damaged — cuts a fully automatic a2ui-dali release.
Humans review the image report in the agent hub.

## 파이프라인

```
[detect]  dali-ui 최신 태그 vs ledger (없으면 no-op 종료)
[stack]   dali-core → dali-adaptor → dali-ui 를 workspace/prefix 로 격리 빌드
[build]   a2ui-dali(main) 빌드 — 실패 시 Claude 코드 적응 루프 (≤3회, src/ 만)
[verify]  conformance 전수 통과 → 코퍼스 36종 Xvfb 렌더 (480×1280)
[gate]    baseline 대비 mean-abs-diff (>0.05 → REVIEW) → REVIEW 만 Claude 시각 판정
          (DAMAGED = 레이아웃 붕괴/겹침/미렌더/잘림; 판정 불가 → DAMAGED 보수 기본값)
[release] GREEN: 코드 변경 있으면 minor, 리빌드만이면 patch 범프 —
          CHANGELOG/CMakeLists/README 호환표/spec 갱신 → 커밋+태그 → push
[rotate]  새 렌더가 다음 비교의 baseline 이 됨 · ledger 기록
[report]  모든 경로(성공/실패)에서 리포트 + 이미지 산출
```

- 게이트는 **데스크톱(이전) vs 데스크톱(새 빌드)** 동일 백엔드 회귀 비교라 폰트가 같다
  — 웹 렌더러와의 parity 판정(에뮬레이터 필요)과는 별개 목적이다.
- 실패(RED/빌드 미해결/인프라)는 릴리스 없이 리포트만 남기고, ledger 를 기록하지 않아
  다음 주기에 자동 재시도된다.

## 설치 (uifw-agent-hub)

```bash
# 1) 허브 agents/ 에 클론 (30초 내 자동 발견)
git clone <this-repo> ~/tizen/uifw-agent-hub/agents/a2ui-dali-release
cd ~/tizen/uifw-agent-hub/agents/a2ui-dali-release
cp .env.example .env            # 필요 시 값 수정 (기본값으로도 동작)

# 2) 최초 1회 baseline 구축 (~30-60분: DALi 3종 풀빌드 + 36종 렌더)
bash automation/bootstrap.sh    # 또는: 첫 hub 실행이 자동으로 수행

# 3) 스케줄 등록 — 주기는 hub UI(/schedules) 또는 API 로 사용자가 직접 지정
#    예: 매일 1회
curl -X POST http://127.0.0.1:8000/api/schedules -H 'Content-Type: application/json' \
  -d '{"agent_id":"a2ui-dali-release","kind":"interval","config":{"every_minutes":1440},"enabled":true}'
```

리포트의 **결과 이미지**(갤러리 시트 + 변경 샘플 side-by-side)는 hub 의 per-run artifact
gallery 확장이 렌더한다 — 에이전트는 `$AGENTHUB_RUN_DIR/artifacts/` 에 PNG 와 `index.json`
을 쓰기만 하면 된다.

## 로컬 실행 / 리허설

```bash
bash automation/selftest.sh                                  # 오프라인 가드레일 검증
FORCE_TARGET=v2.5.28.10837 DRY_RUN=1 bash automation/run.sh  # 전체 리허설 (push 없음)
bash automation/run.sh                                       # 실전과 동일
```

| env | 효과 |
|---|---|
| `DRY_RUN=1` | 커밋/태그/push/baseline 회전/ledger 기록 생략 (리포트는 생성) |
| `FORCE_TARGET=vA.B.C.N` | ledger 무시하고 해당 dali-ui 태그 재처리 |
| `FORCE_REBUILD=1` | 스택 스탬프 무시하고 클린 재빌드 |

## 안전장치

- **격리**: 자체 클론/prefix (`workspace/`) 만 사용 — 개발용 dali-env 불변.
- **Claude 가드레일**: 파일 도구만(Bash/git 금지), `src/` 밖 수정은 diff 검사로 거부+원복,
  자격증명 env 스트립, 시도 예산 ≤3회, 시각 판정 기본값 DAMAGED.
- **멱등**: origin/main 이 이미 해당 dali-ui 기준이거나 릴리스 태그가 이미 있으면 생략.
- **stale 가드**: push 직전 origin/main 이동 감지 시 중단(다음 주기 재시도).
- 릴리스 커밋 author 는 사용자(`woochan lee`) — 자동화 트레일러 없음.
