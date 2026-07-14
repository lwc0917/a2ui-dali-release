# 사내 uifw-agent-hub 배포 가이드 (Handoff)

> **한 줄 요약** — ① hub 에 `agenthub-artifact-gallery.patch` 적용(이미지 리포트 표시, 필수)
> → ② 이 repo 를 GitHub 주소로 에이전트 설치 → ③ 스케줄 등록. 첫 사이클은 자동
> 부트스트랩(릴리스 없음), **둘째 사이클부터 실제 dalihub 릴리스가 발생**한다.

## 0. 호스트 전제조건 (에이전트가 실행될 사내 컴퓨터)

| 항목 | 확인 방법 | 없으면 |
|---|---|---|
| github.com egress (clone) | `git ls-remote https://github.com/dalihub/dali-ui.git` | 프록시/방화벽 오픈 |
| **dalihub/a2ui-dali push 권한 SSH 키** | `ssh -T git@github.com` → 계정 확인 | 없으면 게이트까지만 가고 release-push 실패 리포트로 멈춤(안전) |
| `claude` CLI 로그인 (opus 호출) | `claude -p "hi" --output-format json` | 로그인 갱신. 만료돼도 판정이 전부 차단(DAMAGED)으로 안전하게 멈춤 |
| DALi 빌드 시스템 패키지 | 최초 스택 빌드 로그 확인 | 1회 `dali-core/build/scripts/dali_env -c` (apt 일괄 설치) 또는 수동: cmake g++ pkg-config libgles2-mesa-dev libefl-all-dev 등 |
| 렌더/비교 도구 | `which xvfb-run xwd ffmpeg` + `python3 -c "import PIL, numpy"` | `sudo apt install xvfb x11-apps ffmpeg python3-pil python3-numpy` |

## 1. hub 확장 패치 적용 — **필수** (이미지 리포트)

hub 의 결과 렌더러는 보안상 텍스트만 표시한다. 이 패치가 per-run `artifacts/` 이미지
갤러리(인증 라우트 + escape-first 유지)를 추가한다 — 없으면 리포트에 이미지가 안 뜬다.

```bash
cd <사내 uifw-agent-hub>
git apply <이 repo>/handoff/agenthub-artifact-gallery.patch   # 5개 파일, 테스트 포함
make test                                                      # 전체 스위트 green 확인
# web/worker 재기동
```

포함 내용: `views.py`(인증 라우트 `GET /runs/{id}/artifacts/{file}` + index.json 검증 헬퍼),
`artifact_gallery.html`(신규 partial), `run.html`/`result_card.html`(include),
`tests/smoke/test_run_artifacts.py`(경로 탈출 404·escape 검증 6케이스).

## 2. 에이전트 설치

```bash
# 방법 A — hub UI: 카탈로그 "에이전트 추가" 에 repo URL 입력
# 방법 B — API:
curl -X POST http://127.0.0.1:8000/api/agents/install -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/lwc0917/a2ui-dali-release"}'
# 방법 C — 수동: agents/ 에 clone (30초 내 자동 발견)
git clone https://github.com/lwc0917/a2ui-dali-release <hub>/agents/a2ui-dali-release
```

`.env` 는 불필요(전 키 기본값 동작). 첫 릴리스만 사람이 확인하고 싶으면 설치 직후
`agent.yaml` 의 `confirm_before_run` 을 `true` 로 잠시 바꿔도 된다(검토 후 원복).

## 3. 스케줄 등록 (권장: 매일 새벽 — 릴리스 발생일만 30~60분 빌드)

```bash
curl -X POST http://127.0.0.1:8000/api/schedules -H 'Content-Type: application/json' \
  -d '{"agent_id":"a2ui-dali-release","kind":"interval","config":{"every_minutes":1440},"enabled":true}'
```

⚠️ worker 를 (재)기동하기 전에 **기존 스케줄들의 next_run_at** 을 확인할 것 — 과거로
밀린 스케줄은 기동 즉시 발화한다 (`GET /api/schedules`).

## 4. 첫 두 사이클에서 일어나는 일

1. **1차 실행**: baseline 없음 감지 → 자동 부트스트랩 — 격리 스택(dali_2.5.29 +
   dali-ui v2.5.28.10837) + a2ui-dali(main) 빌드, conformance 68/68, 코퍼스 36종
   baseline 렌더, ledger 시드. **약 10~15분, 릴리스 없음.**
2. **2차 실행**: 새 dali-ui 태그 처리 — 이 문서 작성 시점 기준 **v2.5.29.10863 →
   a2ui-dali v0.11.1 이 실제로 dalihub 에 릴리스**된다(이 시나리오는 샌드박스 원격으로
   전 과정 검증 완료). run 페이지에서 리포트(4파일 범프·게이트 결과·이미지)를 확인하라.
3. 이후: 새 태그 없으면 수 초 no-op. dali-ui 가 core/adaptor 보다 앞서 태그되면
   "페어 대기" 로 스킵하고 페어가 나오면 처리한다.

## 5. 실행 인자 (Run 폼 / API params)

| 인자 | 값 | 용도 |
|---|---|---|
| `gate_level` | strict / **normal** / lenient | 게이트 강도(픽셀 탐지+비전 판정 기준 동시 전환). 상세는 README |
| `diff_threshold` | 예 0.10 | 픽셀 탐지 임계 직접 지정 |
| `dry_run` | true | 리허설 — push/baseline/ledger 미변경 |
| `force_accept` | true | 게이트 RED 1회 수동 승인 — **이전 실패 리포트의 side-by-side 이미지 확인 후에만** |

## 6. 트러블슈팅

| 증상 (리포트) | 원인/조치 |
|---|---|
| 게이트 RED | side-by-side 이미지 확인 → 의도된 변화면 `force_accept=true` 로 재실행, 진짜 회귀면 방치(차단 유지·매 주기 재시도) |
| 판정 근거가 "판정 실패(호출/파싱 불가)" | claude CLI 로그인 만료 — 갱신 후 재실행 |
| build-break (fix 예산 소진) | 대규모 API 재편 — 에러 로그 보고 사람이 1회 포팅 후 다음 주기 |
| release-push 실패 | SSH 키/권한 확인 — ledger 미기록이라 다음 주기 자동 재시도 |
| infra (스택 빌드 실패) | 시스템 패키지/네트워크 — §0 전제조건 재확인 |

## 7. 이 repo 가 통과한 검증 (2026-07-14, 원 개발 호스트)

- selftest 26항목(페어링·타깃 선정·ledger·fix 범위 가드·judge 보수 기본값·게이트 매핑·compare 스모크)
- 실전: 실제 dali-ui v2.5.29.10863 무인 감지 → 스택 재빌드 → 게이트 36/36 →
  **v0.11.1 자동 릴리스**(샌드박스 원격, 커밋/태그/4파일 범프 전수 검수)
- RED 경로: 실제 렌더 변화 2건을 opus 가 차단 + 이미지 리포트 (hub 화면 확인)
- hub 표시: 성공=개별 렌더 36종 전수, 실패=샘플별 baseline|new|diff 카드 (스크린샷 검증)
