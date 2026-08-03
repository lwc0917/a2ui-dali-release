# a2ui-dali-release

dali-ui 새 릴리스를 추종해 a2ui-dali 를 자동 검증·릴리스하는 무인 에이전트 (uifw-agent-hub 에서 실행).

## 구조
| 경로 | 역할 |
|---|---|
| `automation/run.sh` | 오케스트레이터: detect→stack→build(+fix)→conformance→render→compare→judge→release→rotate |
| `automation/lib/` | ui(로그)·load_env·dali(태그/페어링/ledger)·claude(헤드리스 래퍼)·net(재시도) |
| `corpus/jsonl/` | 게이트 정본 36종 (a2ui-dali docs/는 git 미추적이라 vendored) |
| `tools/` | capture.sh(Xvfb 렌더), compare.py(diff+side카드+시트), build_report.py |
| `automation/release_agent.sh` | **이 에이전트 자신의** 릴리스(태그+사내·사외 push+GitHub 릴리스). `--check` 는 마커만, `--confirmed` 는 허브 버튼 전용 |
| `automation/lib/repo_publish.sh` | 자기 레포 게시 공통 루틴: allowlist 스테이징 · ahead/behind 가드 · 프록시 우회 폴백 |
| `state/` | 실행이 학습한 **사실**(비호환 조합 캐시). 판단이 필요 없으므로 실행이 스스로 커밋·push |
| `workspace/` | gitignored: 격리 스택(prefix/, src/), baseline/, ledger(done.json), runs/ |

## 불변 원칙
- **격리**: 사용자의 `generativeUI/dali-env/opt` 와 기존 dali-* 클론은 절대 건드리지 않는다. 모든 빌드는 `workspace/` 안.
- **게이트는 데스크톱(prev) vs 데스크톱(new)** 동일 백엔드 회귀 비교 — web-parity 판정 아님(그건 에뮬레이터 몫).
- **Claude 는 a2ui-dali 클론의 `src/` 만 수정 가능** (파일 도구만, Bash/git 금지). 게이트 스크립트·임계값·baseline·test/ 를 고쳐 통과시키는 행위는 fix.sh 가 diff 검사로 거부.
- 판정 불가/모호 → **DAMAGED(릴리스 차단)** 보수 기본값.
- 릴리스 커밋 author = `woochan lee <lwcc0917@gmail.com>`, **Co-Authored-By 트레일러 금지**.
- ledger 는 릴리스 성공 후에만 기록 — 실패는 다음 주기 자동 재시도.
- **자기 레포에 무엇을 올릴지는 두 갈래**: 판단이 필요 없는 *사실*(`state/`, 골든 회전)은 실행이 자동으로 커밋·push, 사람 판단이 필요한 것(에이전트 코드 릴리스)은 **허브 승인 버튼**(`release-agent` 액션)으로만. 어느 쪽이든 `git add -A` 금지 — `repo_publish` 에 경로를 명시해 allowlist 로만 올린다.

## 자주 쓰는 명령
```bash
bash automation/selftest.sh                 # 오프라인 가드레일 검증
bash automation/bootstrap.sh                # 최초 baseline 구축 (1회)
FORCE_TARGET=v2.5.28.10837 DRY_RUN=1 bash automation/run.sh   # 리허설 (push 없음)
bash automation/run.sh                      # 실전 (hub 가 이걸 실행)
```

## Gotchas
- 스택 교체 시 `$PREFIX` 전체 삭제 후 재설치 (stale 헤더 사고 방지).
- dali-ui 페어링: `vA.B.C.*` ↔ `dali_A.B.(C+1)` (dali-ui 가 core 보다 minor 1 낮음), 없으면 이하 최신 폴백+경고.
- `result.mode: file` 이라 리포트는 `workspace/last_report.md` — no-op 포함 매 실행이 덮어써야 이전 리포트가 오표시되지 않음.
- 이미지 리포트는 `$AGENTHUB_RUN_DIR/artifacts/` + `index.json` — hub 의 artifact gallery 확장이 렌더.
- 사내 프록시는 **큰 push 를 `HTTP 403`/`send-pack: unexpected disconnect` 로 끊는다**(실측 2026-08-03: 1.94MB 6회 실패 → 프록시 없이 1회 성공). 인증 문제로 오진하기 쉽다 — `repo_publish.sh` 의 `git_push_resilient` 가 프록시 우회로 자동 재시도한다.
