# CHANGELOG — Nomad Kant Looper

> 실행 경로: `~/.claude/skills/nomad-kant-looper` (main) · 개발 경로: `AGENTS/kant-looper-dev` (`Kant-looper-branch`)
> 프로젝트 시작: 2026-07-12

**버전 정책**: 0.x대 semver. `MINOR`(`0.X.0`)는 새 기능/아키텍처, `PATCH`(`0.X.Y`)는 인터페이스 변경 없는 버그 수정. `1.0.0`은 아직 사용하지 않음 — `--parallel` 실제 호출 검증과 claude 폴백 안정성이 더 쌓여야 붙임. 각 버전은 main의 해당 커밋에 `git tag v0.X.Y`로 소급 태깅되어 있음 (`git tag -l "v0.*"`로 확인).

---

## [Unreleased]

### Kant Dashboard Phase 0–3 — Standalone Read-only Dashboard

Kant Core(`kant-loop.sh`)는 다시 만들지 않고, 그 위에 얇은 관찰·시각화 계층만
얹는다는 원칙 아래 진행. 역할 분리: **Kant Core = Brain / dashboard/server =
Bridge / dashboard/web = Eyes**. Phase 3 완료 지점에서 한 번 평가하기로 계획돼
있었고(`docs/dashboard/*.md` 참고), 지금은 그 지점 — 여기서 멈춰도 Core엔
`run-state.json`/`events.jsonl`이라는 순수 개선물만 남는다.

- **Phase 0 — Scope Freeze** (`1d99cbb`, 직접 작업: 이바 + Claude Opus 4.8,
  kant-loop.sh 위임 아님)
  - `docs/dashboard/ARCHITECTURE.md`, `STATE-CONTRACT.md`, `API.md`,
    `UI-SCOPE.md` — Brain/Bridge/Eyes 경계와 `run-state.json`/`events.jsonl`
    스키마 v1, API 초안, UI 정보 구조 확정.

- **Phase 1 — Observability Contract** (`1d99cbb`, 직접 작업, 같은 커밋)
  - `scripts/lib/state_writer.py` 신규 — `phase-events.log`를 단일 소스로
    `run-state.json`(atomic write) + `events.jsonl`(append-only)을 재생성.
  - `kant-loop.sh`: `log_event` 확장 + 관찰성 메타 파일 훅(순수 20줄 추가,
    삭제 0 — 엔진 로직 무변경). 관찰성 실패는 `|| true`로 격리해 Core 실행에
    영향 없음. 기존 `phase-events.log`·flat 상태 파일은 그대로 유지.
  - 검증: `state_writer` 단위 29/29, 기존 회귀 스위트 23/23, full-run 통합
    13/13.

- **Phase 2 — Local Server** (`04cc3af`, 워커: `opencode:glm-5.2`,
  run: `task-20260722-140017-0f64`)
  - `dashboard/server/` 신규 — FastAPI, 읽기전용 GET 5개 엔드포인트
    (`/api/health`, `/api/runs`, `/api/runs/{id}`, `/api/runs/{id}/events`,
    `/api/runs/{id}/stream` SSE). `127.0.0.1` 전용 bind(`config.HOST` 하드코딩,
    CLI로도 우회 불가).
  - 검증: 칸트가 직접 curl로 5개 엔드포인트 확인, 깨진 `run-state.json`을
    실제로 주입해 malformed 격리(500 없이 해당 run만 `error`) 확인, 이 위임
    작업 자체의 `run-state.json` 자기참조 확인.

- **Phase 3 — Read-only Dashboard MVP**
  - 디자인 시안 3개 (`c1dd17b`, 워커: `agy:gemini-3.1-pro-preview`,
    run: `task-20260722-235625-0732`): `dashboard/web/design-drafts/draft-1~3.html`
    — Classic IDE / Kanban / Bento Grid, 각각 light/dark 지원. Stitch MCP
    사용을 지시했으나 로그·verdict에 사용 흔적이 없어 확인 불가로 남았고,
    이바가 Stitch에서 직접 3개 시안을 만들어 확인한 뒤 draft-2(정보 밀도)와
    draft-3(비주얼 톤)을 합치도록 지시.
  - draft-4 합성 (`5e063f6`, 워커: `agy:gemini-3.1-pro-preview`,
    run: `task-20260723-015123-5852`): 각 파이프라인 카드에 agent/model/verdict/
    findings를 인라인으로 보여주는 draft-2 구조 + draft-3의 카드 톤. 확정 시안.
  - 실제 API 연동 MVP (`e49e6d9`, 워커: `agy:gemini-3.1-pro-preview`,
    run: `task-20260723-020351-6fe0`): `dashboard/web/index.html` 신규,
    `dashboard/server/main.py`에 정적 파일 서빙 최소 추가(`/api/*` 라우트
    무변경). mock이 아닌 실제 `GET /api/runs`·`/api/runs/{id}`·SSE로 동작.
    파이프라인 카드는 `agents[]` 길이만큼 동적 렌더링(고정 칸수 없음), system
    처리 단계(엔진 내부 로직)와 실제 AI 실행 단계를 시각적으로 구분, Inspector는
    카드와 같은 정보를 반복하지 않고 선택한 stage의 이벤트 로그만 보여줌 —
    이바의 draft-2 리뷰 지적사항 반영.
  - 반응형 레이아웃 수정 (`4b29deb`, 워커: `agy:gemini-3.1-pro-preview`,
    run: `task-20260723-024225-6ce8`): 3컬럼 고정폭이 ~1400px 미만에서
    깨지던 문제(제목 잘림·컬럼 겹침)를 CSS만으로 수정, 1440px 이상 기존
    스타일·JS 로직 무변경.
  - 검증: Phase 3 전체를 칸트가 실제로 서버 기동 후 브라우저(723px/1024px/
    1440px, light/dark)로 직접 렌더링 확인. 클릭 인터랙션은 좌표 스케일링
    문제로 첫 시도가 빗나갔던 것을 JS 직접 호출과 정확한 bounding-rect
    좌표로 재확인.

모두 `kant-loop.sh promote ... --target Kant-looper-branch`로 ff-only 병합.
**main 병합은 아직 하지 않음** — 사용자 명시 승인 대기.

### TASK 파일 이름 운영 원칙 도입 (문서 전용, 코드 변경 없음)

- 작업지시 파일을 `TASK.md` 하나로 매번 덮어쓰던 관행 대신, `TASK-<slug>.md`
  형태로 사람이 파일명만 보고 무슨 작업인지 구분할 수 있게 하는 운영 원칙을
  도입. `<slug>` 규칙은 기존 `task_to_slug()`(`kant-loop.sh:150-158`)와 통일.
- 작업지시 첫 줄 제목도 `# Task`처럼 뭉뚱그리지 않고 구체적으로 쓰도록 명시 —
  `run_id` slug가 이 제목에서 자동 생성되므로, 제목이 뭉뚱그려지면 `status`나
  Dashboard 실행 목록에서 모든 run이 "Task"로만 보이는 문제가 있었음(Kant
  Dashboard Phase 3 MVP 도그푸딩 중 실사용에서 발견).
- **코드 변경 없음**: `cmd_run`은 이미 임의 파일 경로를 인자로 받고 있었다
  (`kant-loop.sh:741-742`) — `TASK.md`라는 고정 이름은 문서 관행이었을 뿐,
  스크립트가 강제한 적이 없었다.
- 반영 문서: `SKILL.md`(Step 3 "TASK 파일 이름 규칙" 신설, Rules·Example·
  Technical Reference 예시 갱신), `README.md`("빠른 시작" 절), `.gitignore`
  (`TASK-*.md`류 스크래치 파일이 실수로 커밋되지 않도록 패턴 추가).

### OpenCode `Kimi-K3` 모델 추가 (2026-08-03, 명시 호출 전용)

- opencode-go 프로바이더의 신규 모델 `Kimi-K3`(Moonshot AI)를 등록. glm-4.7/
  MiniMax-M2.7 같은 legacy 모델과 달리 예전에 primary였다가 격하된 게 아니라,
  **신규 추가라 아직 실측 데이터가 없는** 경우라 `UNVERIFIED_EXPLICIT_ONLY`라는
  별도 등급으로 분류 — `KANT_LEGACY_EMERGENCY_POOL`에도, T0~T3 자동 라우팅
  티어 풀에도 넣지 않았다. `--agent opencode --model Kimi-K3` 명시 호출만
  지원하고, 실패 시 `references/fallback-table.md`의 전용 고정 체인
  (codex → agy → grok → claude)으로만 넘어간다.
- 변경 파일: `scripts/lib/model-selector.sh`(선택 가능 모델 목록),
  `scripts/kant-loop.sh`(`validate_agent_model_compatibility` — opencode
  허용 목록에 추가, claude 쪽은 MiniMax와 함께 명시적으로 거부해 OpenCode
  전용 모델이 claude로 새는 걸 막음), `scripts/adapters/adapter-opencode.sh`
  (`Kimi-K3` → `opencode-go/kimi-k3` bare-name 정규화),
  `scripts/lib/fallback-dispatcher.sh`(`KANT_FALLBACK_CHAINS_LINEAR`에 특수
  케이스 추가), `scripts/tests/test-agent-default-models.sh`(호환성 테스트
  추가), `SKILL.md`·`references/multimodel-coding-agent-routing-guide.md`·
  `references/fallback-table.md`(문서 반영).
- 검증: `test-agent-default-models.sh` 40/40, `test-tier-fallback-chain.sh`
  26/26, `test-minimax-routing.sh` 50/50 — 기존 회귀 없음, Kimi-K3가 자동
  라우팅 티어에 새지 않음을 확인.
- 공식 출처 미확정 — 확인되면 라우팅 가이드 §5에 추가.

### detached worker 헛대기 회귀 수정 (2026-08-04, 칸트 직접 작업)

`--detach`로 띄운 자식이 시작도 못 하고 즉시 죽었는데, 실패 상태가 어디에도
기록되지 않아 `await`가 30분 timeout까지 헛대기한 사고에서 출발. 관측된 상태는
`status=preparing`, 이벤트는 `RUN_CREATED` 한 줄, `agents: []`, `result.txt`
없음, detached PID는 이미 종료. **외부 도구(그록)는 호출조차 되지 않았고**,
30분은 검토 시간이 아니라 죽은 프로세스를 감지하지 못한 시간이었다. detach를
쓰는 모든 도구에 공통인 오케스트레이션 계층 결함이지 특정 도구 문제가 아니다.

- **detach 시작 handshake** (`kant-loop.sh`) — PID를 띄웠다는 사실만으로 성공을
  반환하던 것을, 자식이 실제로 `_run_mode`에 진입했는지(`worker-started` 마커)
  확인한 뒤 반환하도록 변경. 미진입 시 `DETACH_HANDSHAKE_FAILED`로 terminal
  state를 남기고 exit 1. 시작도 못 한 워커가 뒤늦게 살아나 커밋까지 진행하지
  않도록 TERM으로 정리한다. 대기 상한은 `KANT_DETACH_HANDSHAKE_TIMEOUT`
  (기본 15초).
- **`await`의 워커 생존 검사** (`kant-loop.sh`) — `result.txt`만 폴링하던 루프에
  detached PID 생존 확인을 추가. PID가 사라졌는데 terminal result가 없으면
  `WORKER_VANISHED`로 그 자리에서 마감한다. 종료 직전 마지막 쓰기와의 경합을
  피하려 2초 뒤 한 번 더 확인. `detached.pid`가 없는 foreground run은 기존
  동작 그대로.
- **`_run_mode` trap** (`kant-loop.sh`) — `EXIT`/`ERR`/`HUP`/`INT`/`TERM`을 걸어
  어떤 경로로 죽어도 terminal state를 남긴다. trap 본문이 참조하는 state_dir은
  전역(`KANT_WORKER_STATE_DIR`)에 둔다 — local 변수는 EXIT trap이 도는 시점에
  스코프 밖일 수 있고 `set -u`에서 그대로 에러가 된다. 기존 `UNSUPPORTED_MODE`
  경로는 그대로 유지(먼저 기록되면 trap은 덮어쓰지 않음).
- **중단 위치 관측 이벤트** (`kant-loop.sh`, `state_writer.py`) —
  `WORKER_STARTED`/`ADAPTER_STARTED`/`WORKER_ERR` 추가로 중단이 kant-loop
  쪽인지 외부 도구 쪽인지 사후 구분 가능. `_derive_status`가 `agent_started`
  (`QUICK_CALL`)만 보던 것도 수정 — 워커가 그 전에 죽은 run이 영영 `preparing`
  으로 남던 직접 원인이었다.
- **TASK 스냅샷 전달** (`kant-loop.sh`) — 자식에게 원본 TASK 경로 대신 이미
  복사해 둔 `$state_dir/task.md`를 넘긴다. 백그라운드로 도는 동안 원본이
  수정·이동·삭제돼도 작업지시가 흔들리지 않는다.
- 검증: 신규 `scripts/tests/test-detach-worker-liveness.sh` 8/8(핵심 회귀 —
  죽은 워커를 timeout 60초가 아니라 2초 만에 감지, 살아있는 워커 오탐 없음,
  TERM 시그널 → `WORKER_DIED` 기록, 자식 인자가 스냅샷 경로임을 `ps`로 확인),
  전체 스위트 27/27 회귀 없음. 별도로 가짜 어댑터를 쓴 e2e 재현에서
  `status=running` → 워커 강제 종료 → `await`가 약 4초 만에 `WORKER_VANISHED`로
  마감, 이벤트가 `RUN_CREATED → WORKER_STARTED → QUICK_CALL → ADAPTER_STARTED
  → FAIL`로 남는 것까지 확인.
- **`--role review` 명문화** (`SKILL.md`) — 같은 사고에서 읽기 전용 검토가
  `--role` 없이 실행돼 기본값 `implement`(쓰기 역할·auto-commit·1800초)로
  돌아간 문제. SKILL.md에는 `--role` 자체가 한 번도 언급되지 않아 Meta Agent가
  붙일 근거가 없었다. "실행" 섹션에 읽기 전용 작업의 `--role review` 필수
  규칙과 실제로 달라지는 것(auto-commit 안 함, `CHANGES_REQUESTED`를 정상
  완료로 취급, timeout 900초, 읽기 전용 지시 자동 삽입)을 코드 근거와 함께
  기재하고, Rules에도 한 줄 추가. 작업지시에 "수정 금지"라고 쓰는 것으로
  대체하지 않는다는 점을 명시 — 프롬프트는 실행 계약이 아니다. `--chain`은
  역할을 자체 배분하므로 `--role`과 함께 쓰지 않는다는 것도 함께 적었다.
  코드 변경 없음(문서 전용).
- **하지 않은 것**: PID 재사용 방어 — 죽은 PID가 재할당되면 `kill -0`이
  성공해 생존으로 오판할 수 있다. 오류 방향이 안전한 쪽(기존과 같은 헛대기)이라
  이번 범위에서 제외했고, 막으려면 프로세스 시작 시각 비교가 필요하다.

## [0.8.0] — 2026-07-21 — Portable Runtime Hardening

v0.7.0(Host Contract 정의)을 실제로 닫는 릴리스. 새 오케스트레이션 기능을
더하지 않고, 문서상 portable였던 것을 실측·수리·회귀 테스트로 검증된 portable로
바꾼다. 맥스(Codex)가 웹에서 저장소를 조사해 작성한 0.8 제안 문서를 두 감사
에이전트로 검증한 뒤, 5개 phase를 워커(codex:gpt-5.6-sol, opencode:glm-5.2)에게
위임해 도그푸딩으로 진행. 각 phase는 칸트가 TASK.md 작성 → 위임 → diff·테스트
직접 검증 → dev 반영.

### Phase 1 — Active Metadata Drift 제거 (`ce708e3`, 워커: opencode:glm-5.2)

- `agents/openai.yaml`: name/display_name/version을 nomad-kant-looper·0.8.0으로,
  "Claude가 검증" 서술을 "Meta Agent가 검증"으로, "이바" 참조 제거, `full`/HPRAR
  모드 항목 삭제(이미 코드에서 제거된 기능이 메타데이터에 기본값처럼 남아있던
  드리프트)
- `references/fallback-table.md`: "코드가 가이드 파일을 동적 파싱한다"는 허위
  주장 삭제 — 실제 폴백 체인은 `fallback-dispatcher.sh`의 하드코딩 배열이 정의함을
  명시. Code is authoritative, documentation is descriptive 원칙으로 재서술
- `references/safety-promises.md`: destructive-commands 거부가 능동 차단이 아니라
  "그런 호출이 코드에 없다"는 구조적 보장임을 `platform/HOST-CONTRACT.md` §5와
  일치하게 명시. 예시 코드의 `user.name`/notify title을 실제 코드와 일치시킴
- `scripts/kant-loop.sh`: `cmd_update_guide()`의 하드코딩된 개인 절대경로를
  `${KANT_EXTERNAL_GUIDE_PATH:-$HOME/Downloads/...}`로 파라미터화(이 한 줄만)
- 검증: 개인 경로 잔존 0건, 구 이름 잔존 0건, `test-all.sh` 21 PASS

### Phase 2 — parallel role/slice_id 재발 버그 수리 (`d82f634`, 워커: codex:gpt-5.6-sol)

- **살아있던 잠재 버그 발견**: `run_parallel_mode`(`kant-loop.sh:610`)가 여전히
  어댑터 호출 role 인자에 `"review-$slice_id"`를 넘기고 있었다 — 2026-07-17에
  `59b187a`로 이미 고쳤던 것과 정확히 같은 role/slice_id 혼합 패턴의 재발.
  어댑터의 기본 분기가 우연히 read-only에 가까워 지금까지 겉으로 안 터졌을 뿐인
  잠재 위험이었다
- 어댑터 호출 줄 딱 한 곳만 수리: role은 순수 `"review"`로, slice_id는 파일명에만
- 새 회귀 테스트 `test-parallel-role-purity.sh`: 3개 mock worker로 role이 항상
  순수한지 검증. **자가 증명**: 버그를 임시 재현한 코드로 돌리면 3/3 FAIL,
  수리된 코드로 2/2 PASS 확인 후 원복
- 검증: `test-all.sh` 22 PASS

### Phase 3 — JSON schema_version + commit/commit_sha 통일 (`4d251c8`, 워커: codex:gpt-5.6-sol)

- `status`/`report --json` 양쪽 다 `schema_version: 1` 추가
- `status`는 `commit`만, `report`는 `commit_sha`만 노출하던 비대칭을 없애고
  양쪽 다 두 키(같은 값의 별칭) 노출 — 기존 env var 재사용, 새 플러밍 없음
- 기존 `test-status-report-json.sh`에 assertion 추가(구조는 그대로)
- 검증: 실물 run으로 `schema_version=1`, `commit==commit_sha` 눈으로 확인.
  `test-all.sh` 22 PASS

### Phase 4 — Dead code 삭제 + HPRAR 문서 아카이브 (`69b677f`, 워커: opencode:glm-5.2)

- `scripts/lib/no-progress-detector.sh` 삭제(v0.6.1부터 "결정 보류"로 남아있던
  죽은 코드 — 어디서도 호출되지 않음을 재확인 후 v0.8에서 삭제 확정)
- 폐기된 HPRAR 상태 모델 문서 3종(`loop-flow.md`, `failure-modes.md`,
  `verdict-schema.md`)을 `git mv`로 `references/archive/hprar/`로 이동(히스토리
  보존, 내용 무변경 — R100 확인). 새 `references/archive/hprar/README.md`로
  역사적 기록임을 명시
- `SKILL.md`·`agents/openai.yaml`·routing-guide.md의 경로 참조 갱신.
  **CHANGELOG.md는 각 시점의 역사적 기록이라 의도적으로 손대지 않음**
- 검증: "낡은 문서" 배너 3개 보존 확인, 깨진 경로 참조 0건, `test-all.sh` 22 PASS

### Phase 5a — PARALLEL_WRITE_DETECTED 회귀 테스트 (`5c683c7`, 워커: codex:gpt-5.6-sol)

- `run_parallel_mode`에 이미 구현돼 있던 zero-write 안전장치(`kant-loop.sh:655`,
  reviewer가 실제로 파일을 쓰면 PASS verdict여도 실패 처리)를 검증하는 테스트가
  지금까지 하나도 없었던 것을 신설. **`kant-loop.sh`는 전혀 수정하지 않음** —
  이미 있는 동작에 대한 테스트 추가만
- 새 `test-parallel-zero-write.sh`: 3개 mock worker 중 하나가 실제로 파일을
  쓰면 `PARALLEL_WRITE_DETECTED`로 실패하고 `pass_no_commit`으로 둔갑하지
  않는지 검증. **자가 증명**: mock의 쓰기 동작을 `MOCK_DISABLE_WRITE=1`로
  끄면 정확히 3/3 FAIL(테스트가 실제 메커니즘에 의존함을 증명)
- 검증: `test-all.sh` 23 PASS

### Phase 5b — 라이브 fault-injection 폴백 증명 (`a306ce5`, 칸트 직접 실행)

- grok이 사용량 제한으로 라이브 테스트 불가하다는 확인에 따라 codex를 대상으로
  실제 fault-injection 수행. 항상 실패하는 가짜 `codex` 바이너리를 스크래치
  디렉터리에 만들어 **단 한 번의 호출에서만** `PATH` 맨 앞에 배치(실제 codex
  설치나 전역 환경은 전혀 안 건드림)
- **실측된 실제 흐름** (`fallback.log`/`phase-events.log` 그대로):
  ```
  10:15:15 QUICK_CALL codex:gpt-5.6-sol → ADAPTER_FAIL INFRA_ERROR rc=201
  10:15:15 fallback 진입: chain=codex:gpt-5.6-terra,opencode:glm-5.2,
           agy:gemini-3.5-flash,grok:grok-4.5,claude:default
  10:15:20 attempt codex:gpt-5.6-terra → FAIL rc=201 (같은 가짜 codex)
  10:15:25 attempt opencode:glm-5.2 → 실제 라이브 호출 시작
  10:16:05 SUCCESS opencode:glm-5.2 (약 40초 — 실제 원격 LLM 호출 소요시간)
  10:16:06 COMMIT 0b1eeef8
  ```
- 같은 도구(codex)가 두 모델 다 연속 실패해도 fallback-dispatcher가 다른 도구로
  정상 전환해 실제로 완주함을 라이브로 확인. 증거:
  `references/archive/live-fault-injection-evidence-v0.8.md`

### 하지 않은 것

- HPRAR/`--full` 부활, 자동 dispatcher 부활, Routing SSOT 2.0, 범용 config
  generator, MCP abstraction 추가 — 전부 폐기 결정 유지
- Codex/OpenCode의 background 실행·완료 wake-up·permission 모델 capability
  실측 — 이번 범위 밖, "검증필요"로 유지(dev worktree로는 실측 불가, 각 런타임
  세션에서 직접 확인해야 함)
- grok 라이브 재검증 — 현재 사용량 제한으로 보류(대신 codex를 fault-injection
  대상으로 사용)
- 모든 런타임 기능 100% 동일화 — 차이는 정직하게 "검증필요"로 남김(Nomad 철학)

### 검증 (전체)

`scripts/tests/test-all.sh` 23개 스위트 전부 PASS(0.7.0의 21개 + Phase 2/5a
신규 2개). 각 phase 커밋에서 회귀 확인.

## [0.7.0] — 2026-07-21 — Runtime Contract & Conformance

v0.6.0("몸통이 없다")의 agent-agnostic 선언을 **검증 가능한 계약**으로 못박는
릴리스. 맥스(Codex) 제안 문서를 두 감사 에이전트로 검증한 뒤, 실제 구현은
`kant-loop.sh`로 워커(codex:gpt-5.6-sol, opencode:glm-5.2)에게 위임해 칸트루퍼
자체를 라이브 도그푸딩했다. 각 stage는 칸트(Meta Agent)가 TASK.md 작성 → 워커
위임 → diff·테스트 직접 검증 → dev 반영. 워커 커밋에 섞인 `.kant-looper/` 실행
로그는 매번 제외하고 의도한 파일만 반영.

> **🔁 이 릴리스의 상징적 순간 — 칸트루퍼가 자기 버그를 잡다.**
> Stage 3에서 codex(워커)가 자신이 방금 작성한 conformance 스위트를 돌리다,
> 백엔드의 실제 계약 위반을 발견했다 — `cmd_run`의 `--dry-run` 분기가
> `validate_task_md`보다 먼저 `exit 0` 하여 "목표 섹션 없는 TASK는 거부된다"는
> 계약이 dry-run 경로에서 깨져 있었다. codex는 이를 임의로 고치지 않고(수정
> 범위 밖) 정직하게 `CHANGES_REQUESTED`로 보고했고, 칸트(감독자)가 갭을
> 수리했다. **테스트는 수리 전엔 실패(2 FAIL)하고 수리 후 통과(4 PASS)** —
> conformance 스위트가 껍데기가 아니라 실제로 계약 위반을 잡아낸다는 증명이다.
> AI가 만든 검증 도구가 AI가 만든 코드의 결함을 잡고, 인간이 승인한 원칙 아래
> 다른 AI가 고친 — Nomad Kant Looper가 지향하는 "검증 가능한 자율"의 실제 사례.

### Host Contract v1 (Stage 1, 워커: codex:gpt-5.6-sol)

- **`platform/HOST-CONTRACT.md` 신설** (`e5d0235`): Meta Agent Host가 되기 위한
  6개 최소 계약을 실제 코드 앵커와 함께 명세 — skill 발견 / `$SKILL_DIR` 해석 /
  사용자 선택(graceful degradation) / 백엔드 호출 / 인간 주권·안전 경계 /
  완료 확인.
- 계약 5(안전 경계)는 "구조적 보장(파괴적 op가 자동 경로에 없음)"과 "능동 차단
  (`safety-check.sh`의 protected-path/secret 검사)"을 명확히 구분 — 없는 능동
  차단기를 있다고 과장하지 않음.
- 칸트 검증: 인용된 함수 11종·서브커맨드 전부 실제 코드에 존재함을 grep 교차 확인.

### `status`/`report --json` (Stage 2, 워커: codex:gpt-5.6-sol)

- **런타임 중립 JSON 출력 추가** (`1b4e36d`): `cmd_status`/`cmd_report`에 `--json`
  플래그. `$state_dir`의 기존 flat 파일을 python3 `json.dump`로 직렬화(이스케이프
  안전, 신규 데이터 수집 없음). `--json` 없으면 기존 출력 100% 불변.
- 회귀 테스트 `test-status-report-json.sh` 신설, `test-all.sh` 등록.
- 칸트 검증: 실물 run으로 `status`/`report --json`이 `python3 -m json.tool` 통과,
  기본 출력 불변 확인.

### Runtime Conformance Suite + 백엔드 갭 수리 (Stage 3, 워커: codex:gpt-5.6-sol)

- **`scripts/tests/runtime-conformance/` 3종 신설** (`171fc5f`): 백엔드에서 관측
  가능한 계약 속성을 결정적으로 검증(외부 CLI 호출 없음, `--dry-run`·정적 grep·
  격리 git repo만). check-direct-routing(provider 임의 변경 없음), check-task-contract
  (목표 없는 TASK 거부), check-safety-contract(push 부재/merge는 ff-only만/promote
  completed 게이트/protected path 차단). 각 검사에 음성 케이스 포함.
- **도그푸딩이 실제 백엔드 버그를 발견·수리**: codex가 conformance를 돌리다
  "`cmd_run`의 `--dry-run` 분기가 `validate_task_md`보다 먼저 exit 0 하여 목표
  섹션 없는 TASK가 dry-run에서 통과한다"는 계약 위반을 정직하게 `CHANGES_REQUESTED`로
  보고. `validate_task_md`를 dry-run 분기 앞으로 이동해 dry-run·실제 실행 모두
  목표 섹션을 강제하도록 수정(칸트, Task-Failure repair).
- 검증: 수리 전 task-contract 2 FAIL → 수리 후 4 PASS(테스트가 실제 위반을
  잡음을 증명). `test-all.sh` 21 PASS/0 FAIL.

### Platform Capability Matrix + frontmatter 결정 (Stage 4, 워커: opencode:glm-5.2)

- **capability 표 추가** (`e7ab707`): `platform/claude-runtime·codex·opencode.md`에
  7개 capability 등급 표. 이번 세션 실측된 것만 native — Claude Code는 7개 전부
  native, Codex/OpenCode는 발견·구조화 UI·$SKILL_DIR·foreground native, background·
  wake-up·permission은 `검증필요`로 정직하게 남김(추측 없음). 세 런타임을 억지로
  동일 등급으로 만들지 않음.
- **frontmatter 이식성 결정**: `user-invocable`/`allowed-tools`를 SKILL.md에 그대로
  유지 — 세 런타임 모두 unknown 필드를 무시하고 정상 실행함이 관측됨. config
  generation 시스템 안 만듦(YAGNI).

### 하지 않은 것 (제안 문서와 동일)

- HPRAR/`--full` 부활, 자동 dispatcher 부활, Routing SSOT 2.0, MCP 전환 목표화 —
  전부 폐기 결정 유지. 세 런타임 기능 100% 동일 강제 안 함(차이 명시 + 핵심 계약만 동일).

## [0.6.1] — 2026-07-21 — 문서 정합성 패치 (워커: opencode:glm-5.2)

v0.6.0 이후 확인된 문서 드리프트 정리(코드 변경 없음). Stage 0 도그푸딩.

- **문서 드리프트 4종 정리** (`5399313`, 담당: opencode:glm-5.2, 검증: 칸트):
  - `platform/codex.md`: Codex 설치를 "독립 clone(예정)"에서 "이미 worktree(완료)"로
    현실화 — v0.6.0 `install.sh --agent codex`로 전환 완료된 사실 반영.
  - `CHANGELOG` 버전정책: 1.0 조건에서 이미 삭제된 `--full` 제거(`--parallel` 유지).
  - `references/loop-flow`·`failure-modes`·`verdict-schema`: 폐기된 HPRAR 상태
    모델 문서에 "낡은 문서" 경고 배너 추가(내용은 역사적 기록으로 보존).
  - `platform/README`: `no-progress-detector.sh` 삭제 여부는 v0.7에서 결정 노트.

## [0.6.0] — 2026-07-21 — Nomad Kant Looper 정체성 확립 + Agent-agnostic Stage 1

### MANIFESTO 문구 정정 — Human Sovereignty + "왜 몸통이 없는가" (2026-07-21)

- **`f987686`**: Human Sovereignty 섹션에 "인간은 판단을 외주하지 않습니다"
  문장 추가, "사람"을 "인간"으로 통일
- **"왜 몸통이 Claude인가" → "왜 몸통이 없는가"로 재작성**: 아래 Stage 1
  리팩터로 SKILL.md에서 "Claude=오케스트레이터" 하드코딩을 걷어냈는데,
  MANIFESTO에는 "이 원칙을 실제로 조율하는 몸통은 Claude"라는 모순된 문장이
  남아있던 것을 발견해 정정. 이름의 철학적 기원은 Claude와의 설계 대화에서
  나왔지만, 원칙 자체는 어떤 Runtime의 몸에도 정착하지 않는다는 내용으로 수정

### Stage 1 — Agent-agnostic 아키텍처 스켈레톤 (2026-07-20)

맥스(Codex)와 상의해 작성된 설계 문서를 바탕으로, Nomad Kant Looper를
Claude Code 전용 스킬에서 Claude Code·Codex·OpenCode 모두가 오케스트레이터
(Meta Agent Host)로 쓸 수 있는 구조로 1단계 리팩터. 이 세션에서 세 런타임
모두 실제로 Meta Agent 역할을 수행하는 것을 라이브로 확인한 뒤 진행함.

- **증분 1·2 — SKILL.md 어휘 일반화** (`8e02b18`): 프론트매터
  description·Step 2 자동 선택 서술·설계 원칙 등 약 10곳의 "클로드/Claude"를
  "Meta Agent"로, `AskUserQuestion` 명칭을 "구조화된 선택 UI"로 치환. 순수
  어휘 치환이라 동작 불변 — `grep "클로드\|AskUserQuestion" SKILL.md` 0건 확인
- **증분 3 — `platform/` 스켈레톤** (`b593b4a`): 기존 `scripts/adapters/`
  (Worker Provider 축, 워커 호출용, 미변경)와 이름이 겹치지 않도록 런타임별
  Meta Agent Host 차이를 `platform/README.md`·`claude-runtime.md`·`codex.md`·
  `opencode.md` 4개 문서로 분리. `agents/openai.yaml`이 이미 Codex 전용
  메타데이터 분리 역할을 하고 있음을 문서화(신규 파일 불필요)
- **증분 4 — `$SKILL_DIR` 도입** (`ad7ec49`): SKILL.md의 `$HOME/.claude/skills/nomad-kant-looper/...`
  하드코딩 경로 3곳을 `$SKILL_DIR`로 치환. 본문과 Technical Reference에
  중복 서술돼 있던 `--detach`+`run_in_background`+PostToolUse 훅 상세
  내용을 `platform/claude-runtime.md`로 이동
- **증분 5 — `install.sh`** (`478b98d`): `./install.sh --agent claude|codex|opencode|all|auto [--dry-run] [--force]`.
  symlink나 단순 clone이 아니라 `git worktree` 방식 채택(Claude 쪽은 이미
  이 방식으로 검증됨). 기존 foreign clone(`~/.codex/skills/nomad-kant-looper`)은
  자동으로 지우지 않고 감지 후 거부, `--force`로만 제거 후 worktree로 재연결.
  실제로 `--agent claude`/`--agent codex` 둘 다 라이브 실행해 worktree 생성 확인
- **`d05ad74`**: `test-meta-agent-loop.sh`의 스킬 리네임(kant-looper→
  nomad-kant-looper) 이전 하드코딩 경로 수정
- **보류(이번 범위 밖)**: 설계 결정 6(config priority의 ENV 위치), PLAN/VERIFY를
  bash phase로 재구현하는 것(2026-07-17 HPRAR 포기 결정과 충돌하므로 문서
  라벨링으로만 처리), `fallback-dispatcher.sh` 체인 내부 로직,
  `no-progress-detector.sh`(죽은 코드), `references/loop-flow.md` 등 이미
  낡은 참고문서 — 전부 그대로 둠
- **검증**: `scripts/tests/test-all.sh` 17개 스위트 전부 PASS, `bash -n`으로
  `install.sh`/`kant-loop.sh` 문법 확인

### Nomad Kant Looper 정체성 확립 — 매니페스토·리네임·저장소 이전 (2026-07-19)

- **MANIFESTO.md 신설** (`16c9856`): "Nomad Kant Looper" 정체성 선언 —
  6개 핵심 가치(Principle Sovereignty, Switchability, AI Pluralism, Bounded
  Delegation, Human Sovereignty, Verifiable Autonomy)
- **README 재작성 + MANIFESTO.md로 파일명 확정** (`f784230`): 제목·본문의
  "Kant Looper" 표기를 "Nomad Kant Looper"로 전환. 기존 철학 설명 섹션
  155줄을 MANIFESTO.md 링크 + 태그라인 3줄로 축약(270→123줄)
- **스킬 리네임** (`577d730`): SKILL.md 프론트매터 `name`을
  `nomad-kant-looper`로, 슬래시 커맨드 `/kant-looper`→`/nomad-kant-looper`
  전면 교체
- **인프라 이전** (커밋 아님, 수동 작업): GitHub 저장소를
  `codegrahper/Kant-Looper`→`codegrahper/nomad-kant-looper`로 `gh repo
  rename`, 배포 디렉터리를 `~/.claude/skills/kant-looper`→
  `~/.claude/skills/nomad-kant-looper`로 이전(메인 워크트리라
  `git worktree move` 불가 — `mv` 후 `git worktree repair`로 두 linked
  worktree 복구), 로컬 3곳(`kant-looper-dev`, 배포 워크트리,
  `fix/claude-subscription-login` 워크트리)의 origin remote URL을 새
  저장소로 갱신해 "저장소 이동" 경고 제거

### PostToolUse 훅 자동 완료 알림 — 도입 후 신뢰성 미달로 되돌림, 그 과정에서 발견한 체인 버그는 수정 (2026-07-19)

- **PostToolUse asyncRewake 훅 도입** (`7a1ff94`, 담당: 클로드)
  - `--detach`로 던진 외부 도구 실행이 끝나면 `.claude/settings.json`의
    `PostToolUse(Bash)` 훅(`scripts/hooks/kant-loop-auto-await.sh`,
    `asyncRewake: true`)이 자동으로 `await`를 백그라운드에 걸고 클로드를
    깨우도록 만듦. 클로드가 매번 수동으로 `await`를 background로 이어
    거는 단계를 없애려는 시도.
- **실전 3회 테스트 결과 신뢰할 수 없다고 판명, 도입 전 수동 패턴으로 복원**
  (`e1c8968` SKILL.md 되돌림, `9bff2cc` 훅 등록/스크립트 삭제)
  - 1회 정상 작동 / 1회 조기 오탐(아래 버그가 원인) / 1회는 실제로
    완료·커밋까지 됐는데도 원인 불명으로 완전히 침묵 — 아무 신호도 없이
    조용히 실패하는 쪽이 "깜빡함"보다 더 나쁜 실패 모드라고 판단
  - Step 3 실행 절/Rules 절/Technical Reference 모두 `--detach` 후
    `await`를 Bash 도구 `run_in_background: true`로 즉시 이어 거는 기존
    수동 패턴으로 되돌림. 훅 파일 자체는 침묵 원인 조사용 증거로 잠시
    남겨뒀다가, 신뢰하지 않기로 한 채 등록만 방치하면(매 Bash 호출마다
    불필요한 서브프로세스 스폰 + 나중에 경고를 놓치고 재의존할 위험)
    의미가 없다고 판단해 완전히 삭제함
- **원인 조사 중 발견한 진짜 버그: 체인 중간 단계 `result.txt` 조기 기록**
  (수정 `e65df54`, 회귀 테스트 `0a3740a`)
  - `run_quick_mode`가 `commit_at_end=0`이면 무조건 공유 `result.txt`에
    `pass_no_commit`을 썼는데, `run_quick_chain`은 implement/review/repair
    3단계 모두 `commit_at_end=0`으로 호출해서, 체인이 아직 안 끝났는데도
    중간 단계 하나가 PASS할 때마다 마치 최종 완료처럼 `result.txt`가
    덮어써졌다. `cmd_await`(및 위 훅)는 이 조기 기록을 완료로 오판했다.
  - `run_quick_mode`에 8번째 파라미터 `defer_terminal_result`(기본값 0,
    기존 standalone 호출 동작 불변) 추가. `run_quick_chain`만 각 단계
    호출에 `1`을 넘겨 중간 단계가 `result.txt`를 건드리지 않게 함.
    실제 위임(codex:gpt-5.6-sol)으로 구현했고, 클로드가 diff와
    `test-all.sh` 재실행으로 직접 검증함.
  - 회귀 테스트 `scripts/tests/test-chain-result-race.sh` 신설,
    `test-all.sh`에 등록. 즉시 응답하는 가짜 adapter로 4가지(중간 단계
    `result.txt` 무결성, 체인 성공 시 최종 기록, standalone review 기존
    동작 유지, 체인 중간 실패 시 즉시 실패) 검증
  - 실전 라이브 체인(opencode:glm-4.7 → codex:gpt-5.6-terra → codex:gpt-5.6-luna)
    으로 재검증: implement PASS(08:44:30) 후 review가 끝날 때까지
    (08:47:42) 조기 완료 신호 없음 확인. review는 별개로
    `CHANGES_REQUESTED`(내용 리뷰, 메커니즘과 무관)를 냈고 chain은
    설계대로 즉시 실패 처리, repair 미호출을 확인함

### 오픈소스 공개 대비 + 라우팅 가이드 간소화 (2026-07-18)

- **SKILL.md 오픈소스 대응** (`f55443e`, 담당: 클로드)
  - 특정 사용자 이름("이바") 참조 3곳을 일반 표현으로 교체
  - Step 1 오프닝 문구를 "Nomad Kant, 칸트와 유랑합니다. 🙏"로 교체 (이전: "어떤 작업을 할까요?")
  - agy가 선택되는 모든 경로(Step 0 단축입력/자동 선택/직접 선택)에 Google
    Stitch(UI 디자인 생성 MCP) 사용 여부를 묻는 대화창 추가 — agy가 Stitch
    MCP에 연결돼 있어도 프롬프트에 명시하지 않으면 안 쓰던 공백을 메움
- **라우팅 가이드 대폭 간소화** (`10bf729`) — `references/multimodel-coding-agent-routing-guide.md` 637줄 → 139줄
  - 시장 전체 모델 서베이에서 SKILL.md Step 2로 실제 선택 가능한 12개 모델만 남김
  - 실제와 다른 가상의 MCP 요청 스키마/툴 분리 절을 실제 어댑터 호출 계약
    (CLI 직접 호출 → stdout 파싱)으로 재작성
  - HPRAR와 같은 발상이던 자동 상향 상태 머신, `safety-promises.md`와 겹치던
    보안 체크리스트, 미사용 평가 가중치표, 지켜지지 않던 유지보수 주기표 삭제
  - 라이브 재현 결과도 함께 기록: opencode glm-4.7 verdict 누락 재현이
    엇갈려(다른 세션 2/2 실패, 이 세션 2/2 통과) 확실한 반복 재현 없이는
    모델을 제거하지 않기로 함
- **어댑터 주석 오류 수정** (`6473efc`) — `adapter-opencode.sh`의 예시 주석이
  실제 provider(`zai-coding-plan`)가 아니라 무관한 `opencode-go`를 가리키던
  오기 정정
- **GLOSSARY.md 신설 — 16→84개 용어** (`3eb9aa1`, `bb884f0`, `a738a8c`,
  `180d69a`, `1ad5a91`)
  - 비개발자가 클로드와 소통하는 데 필요한 개발 용어 사전. 서브에이전트
    실행 중에만 등장하고 대화에 직접 드러나지 않은 용어까지 포함
  - Git/프로세스·시스템/데이터 형식/테스트·품질/LLM·에이전트/CLI 관례/
    칸트루퍼 고유 용어 7개 카테고리로 구성

### 이벤트 기반 에이전트 간 자동 디스패처 POC — 추가 후 되돌림 (2026-07-17, 이바 확정)

- **agy 어댑터 프롬프트 인자 순서 버그 수정** (`214ca0b`)
  - agy가 `--print`류 플래그를 값 받는 플래그로 처리해 프롬프트를 마지막
    위치인자로 넘기면 무시함, 게다가 `--sandbox`가 `-p`보다 뒤에 오면
    `bubbletea: could not open TTY`로 죽는 인자 순서 의존성을 실측으로 확인
    — `-p`를 맨 앞으로 이동
  - verdict-extractor의 `validate` 호출이 `set -e` 아래에서 실패 시 어댑터를
    죽이던 문제에 가드 추가, 죽은 중복 폴백 코드를 `process` 서브커맨드
    호출로 교체해 `<verdict>` 태그 폴백이 실제로 동작하게 함
- **event/dispatcher POC 구현 후 라이브 검증, 구조적 결함 발견해 되돌림**
  (`87eb498` 추가 → `26618bc` 되돌림)
  - `scripts/event/`, `scripts/dispatcher/`, `config/dispatch-routes.json`으로
    에이전트 간 자동 콜백·라우팅 POC를 구현, `agy-ui-test-codex` 3단계를
    실제 라이브로 기계적으로 완주까지 확인
  - 그 과정에서 `--no-auto-commit`이 `--detach`에서 항상 무시되는 버그도
    발견해 수정 — `export AUTO_COMMIT=0`이 `--detach`의 nohup 재실행 자식
    에는 전파되지 않던 문제. `KANT_AUTO_COMMIT`도 함께 export하도록 고침
  - 하지만 `dispatcher.py`의 `verify()`가 에이전트의 실제 verdict(PASS/
    CHANGES_REQUESTED)를 전혀 보지 않고 diff+safety+gate 통과 여부만
    확인해, codex가 명확히 `CHANGES_REQUESTED`를 낸 리뷰도 워크플로우가
    `completed`로 마감하는 구조적 결함 발견 — 리뷰어가 거부한 코드가
    완료로 보고된 것
  - 이바는 이 판정 로직을 기계 검증에 반영하는 대신, 에이전트 간 자동
    디스패처·콜백 자체를 포기하고 클로드가 감독자로 남는 구조
    (`클로드 → 외부 에이전트 → 콜백 → 클로드 검증`)로 확정 —
    `scripts/event/`, `scripts/dispatcher/`, 관련 테스트 5종,
    `cmd_workflow`/`--workflow`/`--step` 전부 제거. `run --quick
    [--detach]`/`await`/`status`/`report`/`--existing-worktree` 등
    클로드가 직접 쓰는 기존 primitive는 유지
  - 자세한 경위는 `PLAN-lightweight-kant-looper.md` 참고

### quick 안정화 + HPRAR(`--full`) 포기 (2026-07-17, 이바 확정)

- **--parallel/--full 라이브 버그 3건 수정** (`59b187a`, 담당: OpenCode/GLM-5.2,
  검증: 클로드)
  - `run_parallel_mode`가 role을 파일명용 "implement-N"으로 만들어 어댑터
    `call`에도 그대로 넘겨, `adapter-codex.sh`/`adapter-opencode.sh`의
    정확 문자열 비교(`"implement"`/`"repair"`)에 안 걸려 codex는 읽기전용
    으로 폴백, opencode는 `--auto` 없이 실행되던 문제 — role과 파일명용
    slice_id를 분리
  - parallel 프롬프트가 "위 quick 모드와 동일"이라고 참조했지만 parallel은
    독립 파일이라 "위"가 없어 opencode가 파싱 가능한 verdict를 못 냄 —
    quick 모드와 같은 JSON 스키마+`<verdict>` 태그 안내를 parallel/full
    프롬프트에 그대로 인라인
  - agy CLI 1.1.3이 짧은 모델 ID(`gemini-3.5-flash`)를 거부하고 표시 이름
    (`Gemini 3.5 Flash (Medium)`)만 받게 바뀜 — 어댑터에 정규화 로직 추가,
    사라진 `gemini-3.1-flash-lite`는 모델 목록에서 제거
  - 검증: codex/opencode/agy 세 조합 모두 `--quick`/`--parallel --chain`으로
    실제 PASS 재현 확인
- **HPRAR(`--full`) 포기 결정 기록** (`a80dc7d`)
  - `--parallel`/`--full` 라이브 실패를 계기로 "자동 라운드 체이닝(HPRAR)
    자체가 구조적으로 반복 실패한다"는 근거가 논의됐으나, 클로드가 근거로
    제시된 별도 프로젝트의 실제 기록을 직접 확인한 결과 뒷받침이 불충분함을
    확인해 이바에게 보고. 이바는 그 검증 결과를 기다리지 않고 이 시점에
    독립적으로 HPRAR 포기를 확정
  - 대안: 복잡한 작업은 클로드가 `--quick` 호출을 여러 번 조합해 대화 중
    직접 운영
- **run_full_mode 및 HPRAR 코드 제거** (`7477faf`, 담당: 클로드)
  - `kant-loop.sh`에서 `run_full_mode`와 관련 full 시나리오 전부 삭제
    (kant-loop.sh 순감소 487줄), 기본 quick·3단계 quick 체인·읽기 전용
    parallel 계약으로 정리
  - `--full` 호출 시 "HPRAR 모드는 중단되었습니다. --quick 또는 --quick
    --chain을 사용하세요" 에러로 명시 안내
  - OpenCode 라이브 3회 연속 성공으로 quick 경로 재검증

### 경량화 5단계 — SSOT/자기개선 코드 제거 (2026-07-17, 이바 승인)

`PLAN-lightweight-kant-looper.md` 방향 전환에 따라, 아래 `routing-ssot-integration`
섹션이 설명하는 기능 전체(2주 관찰 시험 포함)를 **되돌리고 제거**했다. 판단은
셸 스크립트가 아니라 클로드가 그 자리에서 하는 쪽으로 확정.

- **삭제**: `scripts/lib/routing-parser.sh`(834줄), `ssot-shadow.sh`(170줄),
  `ssot_loader.py`, `routing-ssot/` 디렉토리 전체, 관련 테스트 6종
  (`test-ssot-stress-simulation.sh`, `test-self-improvement.sh`,
  `test-ssot-shadow.sh`, `test-routing-source-ssot.sh`,
  `test-routing-ssot-sync.sh`, `test-meta-aware-routing.sh`),
  `references/ssot-shadow-mode.md`, `ssot-2WEEK-trial.md`
- **`kant-loop.sh`**: `self-scan`/`self-dispatch` 서브커맨드와 관련 함수군
  전부 제거. quick/parallel/full 모드의 `AUTO_ROUTE`·`ssot_shadow_observe`
  분기 제거 — 기존에 이미 있던 하드코딩 기본값(`codex:gpt-5.6-terra` 등)만
  남김. `--parallel` 모드는 자동 슬라이싱이 없어졌으므로 `--chain` 명시가
  필수로 바뀜(생략 시 즉시 에러).
- **`model-selector.sh`**: `auto` 서브커맨드(routing-parser 의존) 제거,
  `list-agents`/`list-models`/`validate`/`select`는 유지.
- **`fallback-dispatcher.sh`**: `KANT_ROUTING_SOURCE=ssot` 분기 제거,
  하드코딩 fallback chain만 사용.
- **문서**: SKILL.md의 "자동 선택"/"자동 라우팅" 절을 코드 판정 서술에서
  "클로드가 판단, 표는 참고용 휴리스틱"으로 재작성. `references/loop-flow.md`,
  `references/fallback-table.md` 동기화. postmortem
  (`references/postmortems/2026-07-15-routing-keyword-collision.md`)은
  역사적 기록으로 보존하고 후기만 추가.
- **검증**: `test-all.sh`(14개 테스트), `run-scenarios.sh`(A/B/C 시나리오
  dry-run) 전부 재통과 확인.

### `routing-ssot-integration` → 병합 시 `v0.5.0` 예정 (main 병합 대기 — 2주 `KANT_ROUTING_SOURCE=ssot` 관찰 + 이바 승인 필요)

> **상태(2026-07-17)**: 위 "경량화 5단계"에서 이 섹션이 설명하는 코드 전체가
> 제거됐다. 아래는 왜/어떻게 만들어졌는지에 대한 역사적 기록으로 남긴다.

- **SSOT 라우팅 통합 — 5단계** (담당: OpenCode, 검증: 클로드)
  - **Phase 1** (`3842c68`) — `/Users/drumqube/Downloads/kant-looper-routing-ssot-package`를 `routing-ssot/`로 이식, agy 검증 리포트가 지적한 코드 불일치 해소: Anthropic/Claude provider 및 `claude:default` 모델 등록(치명 결함이던 "최종 안전망 누락" 해결), agent-model 바인딩 필드 추가, `review` route 추가, `o3` 등록. models 15→16, routes 6→7
  - **Phase 2** (`85e7c98`) — `validate-routing-ssot.py`에 코드-정합 invariant 5종 추가: agent-model 호환성, fallback 최종 안전망(Claude) 존재, scoring 가중치 합계=100, route tier ↔ 모델 tier 교차, provider별 최소 1개 모델. 음성 케이스 8개(`tests/test_validator.py`) 전부 실패로 잡히는지 확인
  - **Phase 3** (`d4b63d9`) — `scripts/lib/ssot-shadow.sh` 신설: `KANT_SHADOW_MODE=on`일 때만 활성화되는 비침해 관찰 모드. 하드코딩 라우팅 결과와 SSOT 라우팅 결과를 TSV로 기록만 하고 실제 판정에는 개입하지 않음 (기본 OFF, 로그 생성 안 됨 확인)
  - **Phase 4** (`a820684`) — `KANT_ROUTING_SOURCE=ssot` 토글 추가. 기본값(`hardcode`)은 기존 동작 100% 보존, 명시적으로 켜야 SSOT가 실제 라우팅 소스가 됨
  - **Phase 5** (`c703d91`) — hardcode↔SSOT drift 감지 회귀 테스트 4종 추가 (6개 라우트 primary 동기화, fallback chain 동기화, 전체 chain이 claude 안전망으로 끝남, 기본 상태 유지). **하드코딩 제거는 보류** — `PHASE-3-5-PLAN.md`에 "2주 이상 SSOT 모드 운영 + 이바의 명시적 승인" 조건 명시, 자의적 제거는 안전 약속 위반으로 판단해 보수적으로 유보
  - 검증: `test-all.sh` 16/16 PASS, 검증기 `VALID` (models=16, routes=7), 기본 상태·shadow ON·SSOT 토글 전부 클로드가 직접 재현 확인 (hardcode/SSOT 모드 route 완전 일치)

### `fix/claude-subscription-login` — 병합 완료 (`d2c8dce`로 `Kant-looper-branch`에, 이후 main까지 반영됨. `v0.5.1` 별도 태깅은 안 함 — v0.5.0 범위에 이미 포함)

- **Claude 어댑터를 구독 로그인 방식으로 고정 + MiniMax-M3 잔재 제거** (`cd56f6c`, 담당: OpenCode, 검증: 클로드)
  - 근본 원인: `health-check.sh`의 claude 분기가 `~/.claude/credentials.json` 또는 `ANTHROPIC_API_KEY` 존재를 요구 → OAuth 구독 로그인 상태에서는 둘 다 없어 claude가 항상 `UNAVAILABLE`로 오판, 8개 fallback chain의 최종 안전망이 무력화됨 (`QUICK_CALL_FAILED / INFRA_ERROR exit=201`)
  - 수정: 인증 확인을 claude CLI 자체에 위임 (파일/API키 강제 조건 제거), 인증 실패는 호출 시점에 `FAIL:FINAL_FALLBACK_FAILED`로 감지
  - `agents/openai.yaml`, `references/fallback-table.md`, `references/failure-modes.md`에 남아있던 "claude = MiniMax-M3" 표기 전부 `claude:default`로 정렬 (실행 코드 `fallback-dispatcher.sh`는 이미 정상이었음 — 문서만 어긋나 있었음)
  - 신규 회귀 테스트 `test-claude-health-subscription.sh` (mock claude + 격리 HOME, 5/5 PASS)
  - 검증: 실제 구독 로그인 상태에서 `health-check tool claude` rc=0, 실제 `--quick --agent claude --model default` 호출이 `pass_no_commit`으로 완주 (이전엔 실패하던 시나리오) — 클로드가 직접 재현·확인
  - **범위 밖으로 명시 보호**: `failure-context.sh`의 `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL` 마스킹 정규식은 시크릿 삭제 대상이 아니라 보안 기능이라 변경하지 않음

---

## [0.4.0] — 2026-07-15 — `@도구[:모델]` 단축 입력

- **`/kant-looper @도구[:모델]` 단축 입력** (`54d5050`, 담당: 클로드)
  - Step 0 신설 — 메시지 맨 앞 `@codex`/`@opencode`/`@grok`/`@agy`/`@claude` 토큰 인식
  - `@도구:모델` + 작업 설명 → Step 1/2 스킵, 바로 Step 3 / `@도구`만 있으면 모델 선택 UI로 직행 (자동 기본값 임의 선택 금지) / 무효 토큰은 무시하지 않고 안내 후 정상 흐름 복귀
  - Claude는 별도 모델 목록이 없어 Step 0에서 바로 default로 처리하도록 예외 처리 확인 (실사용 중 발견)

---

## [0.3.0] — 2026-07-15 — 라우팅 판정 일원화

- **라우팅 판정 일원화 — 5단계** (`routing-unification`, 담당: Codex/GPT-5.6, 검증: 클로드)
  - **Phase 1** (`a259dc2`) — `judge_task_routing()` 단일 판정 함수 도입 + 증거 점수화(긍정/부정 신호 가중치). `접근`→`접근성|a11y|accessibility`, bare `전체`→저장소/코드베이스 문맥 한정으로 좁혀 오탐 제거
  - **Phase 2** (`79cdc19`, 정리 `e9daca0`) — `match`/`match-with-judgment`/dry-run 3개 진입점을 전부 `judge_task_routing()`로 통합, `judged_route`/`effective_route`/`fallback_reason` 구분 도입. (`e9daca0`: 초기 커밋에 실수로 섞여 들어간 세션 로그·잡파일 7개를 별도 정리 커밋으로 제거, `.gitignore`에 `.DS_Store`/`.omo/run-continuation/*.json` 추가)
  - **Phase 3** (`b9582db`, 배선 수정 `ede4aab`) — `--chain`을 `--full`/`--parallel` 실제 실행에 연결. 최초 구현에서 dry-run 출력 누락과 `--detach` 경로에서 체인이 조용히 사라지는 배선 버그 2건을 클로드가 발견해 같은 세션에서 수정
  - **Phase 4** (`8335145`) — SSOT 전략 B 확정: 코드가 판정 규칙의 SSOT, 가이드 문서는 모델명만 제공. SKILL.md의 "가이드를 매번 파싱해서 동적으로 결정"이라는 부정확한 서술 정정
  - **Phase 5** (`a81dbf8`) — 실제 문서형 fixture 18개 + 속성 기반 부정 테스트 추가, 60개 회귀 테스트 전체 PASS
  - 근본 원인이었던 오분류 사례: 순수 bash 어댑터 작업이 `ui`/`T3`로 오분류되어 `agy:gemini-3.5-flash`(브라우저 전용 도구)로 잘못 라우팅되던 문제 — `references/postmortems/2026-07-15-routing-keyword-collision.md`에 포스트모템 기록 (`77c4114`)
  - 병합 경로: `routing-unification` → main ff-only(`26bca47`), `Kant-looper-branch`를 main과 동기화(`8044cc4`)

---

## [0.2.1] — 2026-07-15 — MiniMax 경계·에이전트 기본모델 정리 (패치)

- **MiniMax 모델 경계 정리** (`4c00ff1`) — `is_official_minimax_model()` 3-모델 allowlist 도입, claude 어댑터가 provider prefix와 무관하게 모든 MiniMax 변형 거부, `fallback-dispatcher.sh`의 `claude|MiniMax-M3`를 `claude|default`로 전면 교체, 51개 MiniMax 라우팅 테스트 추가
- **에이전트 기본 모델 + 상대경로 프롬프트** (`4c0737c`) — `--agent`만 지정 시 도구별 기본 모델 사용(`get_default_model()`), 모델-도구 호환성 사전 검증(`validate_agent_model_compatibility()`), 모든 에이전트 프롬프트에 "워크트리 루트 기준 상대경로만 사용" 규칙 추가 (32+9 assertions)
- **커밋 전 Python 런타임 캐시 자동 정리** (`83d3e66`) — quick 모드에서 4개 에이전트 실행 중 생성되는 `__pycache__`가 protected-path 정책에 걸려 정상 산출물 커밋을 막던 문제 해결 (경로는 워크트리 내부로 제한, 소스에 커밋된 캐시 차단 정책은 유지)

---

## [0.2.0] — 2026-07-14 — meta-agent 자가치유 루프 + 멀티모델 확장

- **모델 지원 확장**: codex 5.6 sol/terra/luna, opencode glm-5.2/4.7 (`a440349`)
- **라우팅 SSOT 기반 + health-check 폴백** (`85d4463`)
- **meta-agent 자가치유 모듈 신설** (`05ba7ce`, `2bb5f29`, `d5c13e3`, `c005945`, `4043870`, `342eb88`, `c9ddfc8`)
  - `failure-context.sh`(실패 시 YAML 컨텍스트 캡처 + secret redaction) → `failure-analyzer.sh`(claude 메타 분석) → `fix-apply.sh`(제안된 패치를 `fix/` 브랜치에 안전 적용)의 자가치유 루프. 최초 모듈 테스트 7/7 PASS(`2bb5f29`)
  - 리뷰 피드백 반영 P0/P1 보안 가드 전면 재설계(`c005945`): 모델의 임의 shell 명령 실행(`commands_to_run`) 인터페이스 완전 제거, Python 인라인 보간 제거(별도 스크립트 분리), branch명 강제 검증(`fix/[a-zA-Z0-9._/-]+`, main/master 명시 거부), 작업트리 clean 검증 + 파일별 개별 staging(광역 `add -A` 금지), canonical path 검증(realpath 기반 저장소 외부 경로 거부), idempotency marker, 재진입 가드
  - 실제 git worktree에서 fix-apply를 호출하는 e2e 통합 테스트 추가(`342eb88`, 리뷰어 P1 "테스트가 실제 주요 경로를 검증하지 않음" 피드백 대응) — 핵심 보안 가드 6/6 PASS
  - BSD sed(`\{\}` 멀티라인) + 한글 멀티바이트 헤더 패턴 매칭 실패로 `guard_path_in_repo`가 source 후 미정의되던 테스트 인프라 버그 수정(`4043870`) — 회귀 총 38/38 PASS로 갱신
  - `jq` 의존성 추가, `mark_applied`가 커밋 성공 시에만 마커를 쓰도록 수정, `commands_to_run` 필드는 무시하되 경고 로그만 남기도록 처리(`c9ddfc8`) — e2e 11/11 PASS
  - 테스트: `test-fix-apply-redesign.sh` 12/12, `test-fix-apply-guards.sh` 8/8, `test-meta-agent-loop.sh` 7/7
- **secret redaction 영구 회귀 테스트** (`90bd27f`, `620e175`) — `failure-context.sh`의 `redactor()`가 보안 critical인데 이전 inline 검증(7/7 PASS)이 커밋 없이 사라졌던 걸 발견, `test-redactor.sh`로 영구화(OpenAI/MiniMax/Anthropic 키 prefix, Bearer 헤더, URL userinfo, 홈 디렉터리, 여러 줄 분산 secret 등 8종 시나리오), `test-all.sh` wrapper에 등록
- **테스트 통합** (`bdc217c`) — `scripts/tests/test-all.sh` 신설, 산재한 6~7개 회귀 테스트를 한 명령으로 통합 실행

---

## [0.1.1] — 2026-07-13 ~ 07-14 — 어댑터 verdict 파싱 안정성 (패치)

- **grok 샌드박스 감지 + opencode 모델 정규화** (`29f6f4c`) — `~/.grok/sandbox.toml` 부재/프로필 미정의 시 `--sandbox` 플래그 생략, bare 모델명(`glm-5.2` 등)을 `opencode-go/model` 포맷으로 정규화
- **JSON 추출 하드닝** (`ceef89d`, `da03576`) — brace-counting 파서가 중첩 JSON에서 실패하던 문제, `<verdict>` 태그 폴백 추가, 모델 자기보고 대신 실제 `git diff`로 `changed_files` 교차검증. 9회 반복 호출 실패율 1/9 → 0/9로 개선
- **`do_fallback()` verdict 누락 수정** (`d8c675e`, `e939521`, `ed531b8` PR A) — fallback 성공 시 `tool:model` 문자열을 그대로 echo해 quick 모드가 이를 verdict로 오인, 성공한 fallback도 항상 실패 처리되던 버그 수정

---

## [0.1.0] — 2026-07-13 — verdict 검증 정확도

- **`changed_files` 실제 diff 교차검증** (`5499dba`) — opencode/glm-4.7이 실제로 파일을 쓰지 않고도 자신 있게 `verdict=PASS` + 상세 `changed_files`를 보고하는 사례를 재현, `verify_changed_files()`를 3개 모드 전체에 배선해 모델 자기보고와 실제 git 상태 불일치 시 `CHANGED_FILES_MISMATCH`로 차단
- **claude/grok JSON envelope 언랩** (`c5b55de`) — `claude --output-format json`이 응답을 `"result"` 문자열로 한 겹 감싸 codefence/brace 파서가 못 찾던 문제, grok의 `"text"` 래핑도 동일 처리

---

## [0.0.1] — 2026-07-12 — 최초 스냅샷

- **kant-looper 스킬 초기 아키텍처 전체** (`e551c9d`, 23개 파일 · 6,135줄 · "버전 관리 시작 전 스냅샷"으로 한 커밋에 통째로 커밋됨 — 이전 개발 이력은 git에 없음)
  - **SKILL.md** — Meta Agent 3단계(Step1 작업 확인 → Step2 자동/직접 도구 선택 → Step3 작업지시 생성) + `--quick`/`--parallel`/`--full` 3모드 설계
  - **5개 어댑터** (`scripts/adapters/`) — codex, grok, opencode, agy, claude 각각 독립 호출 인터페이스
  - **8개 lib 스크립트** (`scripts/lib/`):
    - `routing-parser.sh` — 라우팅 가이드 파싱 + 키워드 매칭
    - `health-check.sh` — 호출 전 도구 가용성 점검
    - `safety-check.sh` — protected path·forbidden pattern(시크릿) 검사
    - `gate-runner.sh` — 테스트/빌드 게이트
    - `no-progress-detector.sh` — 동일 diff 반복·무진전 자동 중단
    - `timeout-runner.sh` — 프로세스 실행 + 타임아웃 관리
    - `fallback-dispatcher.sh` — 도구 실패 시 대체 체인
    - `verdict-extractor.sh` — 모델 응답에서 verdict JSON 추출
  - **references 6종** — `multimodel-coding-agent-routing-guide.md`(SSOT 라우팅 가이드, 637줄), `loop-flow.md`, `verdict-schema.md`, `safety-promises.md`, `failure-modes.md`, `fallback-table.md`
  - **`agents/openai.yaml`** — 인터페이스 메타 정의
  - **`scripts/tests/run-scenarios.sh`** — 초기 시나리오 테스트
  - **안전 원칙**: 자동 push 금지 · main 직접 커밋 금지 · rebase/`reset --hard` 금지 · protected paths 차단 · merge는 `promote` 명령으로만 사용자 승인 후 실행 — 이 5원칙은 이후 지금까지 한 번도 변경되지 않음
- **agy `--sandbox` read-only 우회 차단** (`93f8b34`) — `--sandbox`는 터미널 실행만 제한하고 파일 쓰기는 막지 않아, `--dangerously-skip-permissions`와 결합 시 plan/review/verify 같은 읽기 전용 역할도 파일을 쓸 수 있었던 취약점. `--mode plan`(읽기 전용) / `--mode accept-edits`(쓰기 허용)로 역할별 분리
- **모든 외부 CLI 어댑터의 격리 cwd 강제** (`7e07863`) — `kant-loop.sh`가 워크트리를 생성하고도 실제로 `cd`하지 않아, 5개 어댑터가 스폰하는 프로세스가 전부 사용자의 원본 체크아웃에서 실행되던 문제. `timeout-runner.sh`의 `run_with_timeout()`에 `cwd`를 fail-closed 필수 인자로 추가
- **README 요구사항 + 퀵스타트 추가** (`ee70fad`)
- **safety-check staging 버그 + 패턴 quoting 버그** (`88bf44c`) — 신규 파일만 생성하는 작업에서 `git add` 없이 `git diff --cached`를 검사해 secret 스캔이 아무 내용도 못 보던 문제, `FORBIDDEN_PATTERNS`의 unquoted 순회로 인한 glob 오전개(cwd의 dotfile을 패턴으로 오인) 수정
- **agy CLI 실전 노트** (`cfba3a9`) — `--sandbox`/`--add-dir`/`--dangerously-skip-permissions`의 실제 동작을 공식 문서와 재현으로 교차검증해 `references/agy-cli-notes.md`로 기록
