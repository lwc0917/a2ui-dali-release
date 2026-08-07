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
| `automation/lib/gh_release.sh` | **태그 push ≠ 릴리스** — GitHub 릴리스 객체 생성(멱등 · 원격에 태그 없으면 거부 · 프록시 우회) |
| `automation/gh_release_sync.sh` | 릴리스 누락 복구 CLI(허브 `gh-release-sync` 버튼이 호출). `--list`/`--tag vX`/`--missing [N]` |
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
- **`git push --atomic origin main vX` 는 태그만 만든다 — Releases 탭은 릴리스 '객체'가 있어야 채워진다.** 실측 2026-08-07: v0.13.0~v0.18.0 태그가 전부 원격에 있는데 GitHub 최신 릴리스는 v0.12.0(6주 전)이었고, 그동안 허브는 매 실행을 초록 "vX 릴리스 완료" 로 보고했다 — 로그로는 절대 안 드러나는 거짓이다. 이제 `release.sh` 가 push 직후 릴리스를 만들고, 실패하면 `[gh-release-missing: vX]` 마커 + 비-0 종료로 허브에 복구 버튼을 띄운다. 릴리스가 없으면 그 실행은 **성공이 아니다**.
- GitHub 의 **`Latest` 배지는 버전이 아니라 `created_at` 으로 정해진다** — 옛 태그를 소급 릴리스하면 그 옛 버전이 최신 자리를 빼앗는다(실측 2026-08-07: v0.13~v0.17 소급 직후 페이지 최신이 v0.17.0). `gh_ensure_release` 의 6번째 인자로 항상 명시하고, 소급은 원격 최신 태그 하나만 `true` 로.
- `git remote get-url` 은 `insteadOf` 를 확장한 **전송용** URL 을 준다 — 어느 GitHub 인지(host/slug) 알아내려면 `git config --get remote.<name>.url` 로 raw 값을 읽어야 한다(`gh_remote_url`).

## 사내 전용 정책 (2026-08-07)
- **이 에이전트 레포의 코드는 사내에서만 쓴다.** `origin`(사내)에만 push 하고 사외(`public`)로는 push·릴리스하지 않는다. 클론에 `public` 리모트가 남아 있어도 쓰지 않는다.
- 단, **제품 발행 경로는 그대로 사외로 나간다**(아래 줄) — 레포 코드와 제품을 헷갈리지 말 것.
- 기본값 `AGENT_REPO_REMOTES=origin` 이 코드에 박혀 있고 selftest 가 "사외 리모트가 있어도 push 하지 않는다" 를 실제 bare 레포로 검증한다.
- **에이전트 코드 릴리스에 승인 버튼이 없다.** `run.sh` 가 끝에서 `release_agent.sh --auto` 로 사내 태그+릴리스를 직접 남긴다(미태그 + 깨끗한 트리일 때만, 멱등). 실패해도 run 을 죽이지 않고 다음 실행이 재시도한다.
- 제품 발행(사외 유지): `github.com/dalihub/a2ui-dali` 커밋·태그·**GitHub 릴리스**.
