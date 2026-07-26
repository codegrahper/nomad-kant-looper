# agy (Antigravity CLI) 실전 노트

> 오늘 실제로 겪은 시행착오를 기록. 공식 문서(https://antigravity.google/docs/cli/using ,
> https://antigravity.google/docs/cli/reference)로 교차 확인된 내용만 "확인됨"으로 표시.
> agy를 라우팅하거나 adapter-agy.sh를 다시 건드리기 전에 먼저 이 문서를 읽을 것.

## 1. `--sandbox`는 터미널만 막는다 (파일 쓰기는 안 막힘)

**확인됨** — 공식 reference의 `settings.json` 표에 정확히 이렇게 나와 있다:

```
enableTerminalSandbox (boolean, default false)
  "Restricts all local execution commands launched by agents to OS containment rings."
```

`--sandbox`는 이 `enableTerminalSandbox`의 launch-time override다. **파일 읽기/쓰기와는 무관.**
read-only 롤(plan/review/verify)에서 `--sandbox read-only`만 주고 안심하면 안 된다 —
실제로 이 조합 + `--dangerously-skip-permissions`로 hello-world 테스트 중 agy가
스킬 스크립트 5개를 실제로 수정하는 사고가 있었다 (`fix/agy-read-only-sandbox-bypass` 커밋 참고).

파일 쓰기를 막는 실제 옵션은 `--mode plan`이다 (아래 3번 참고).

## 2. `--add-dir`은 cwd를 바꾸지 않는다 — 그냥 "추가 접근 허용"

**확인됨** — reference 문서의 슬래시 커맨드 표: `/add-dir <path>` = "Add a directory path
to the active workspace." (추가일 뿐, 전환이 아님)

실측으로도 확인: `--add-dir /some/other/dir`을 줘도 agy의 실제 `workspaceDirs`는
프로세스가 실행된 cwd를 그대로 가리켰다 (`cli.log`에서 직접 확인). 그래서 nomad-kant-looper는
agy를 포함한 5개 어댑터 전부, **프로세스 자체의 cwd를 격리된 worktree로 강제**하는 방식으로
고쳤다 (`scripts/lib/timeout-runner.sh`의 fail-closed cwd 인자, `fix/adapter-worktree-cwd-isolation` 커밋).
`--add-dir`에만 의존해서 worktree를 격리했다고 믿으면 안 된다.

## 3. `--mode plan` vs `--mode accept-edits`

**확인됨** (agy --help): `--mode` = "Set the agent execution mode for this session
(accept-edits, plan)".

- `plan`: 읽기 전용. 실제로 파일 수정 지시를 줘도 무시하고 분석/보고만 한다 (실측 확인 —
  `--mode plan`에서 "이 파일 한 줄 고쳐봐"라고 시켜도 파일이 전혀 안 바뀜).
- `accept-edits`: 편집 허용. 이 모드에서만 `--dangerously-skip-permissions`(아래 4번)와
  같이 써야 한다.

adapter-agy.sh는 role에 따라 이 둘을 나눠 쓰도록 고쳐져 있다 (plan/review/verify → plan,
implement/repair → accept-edits).

## 4. `--dangerously-skip-permissions`가 정확히 우회하는 것

**확인됨** — settings.json 표의 `toolPermission` 옵션:

```
toolPermission (string, default "request-review")
  "request-review"      : write/bash/web 도구 승인 요청
  "proceed-in-sandbox"  : 샌드박스 안에서는 자동 진행
  "always-proceed"      : 절대 승인 요청 안 함  ← --dangerously-skip-permissions가 이걸로 강제
  "strict"              : read 아닌 모든 도구에 승인 요청
```

즉 이 플래그는 **모든 도구 권한 요청(파일 편집 포함)을 자동 승인**한다. read-only 롤에서
이 플래그를 쓰면 `--mode plan`이 있어도 위험하니 절대 같이 쓰지 않는다 (adapter-agy.sh가
이미 이렇게 분기돼 있음 — `skip_permissions=0`은 plan/review/verify, `=1`은 implement/repair만).

별도로 `artifactReviewPolicy`(코드 작성 전 리뷰 여부)도 있는데 이건 아직 CLI 플래그로
직접 건드리지 않고 있음 — 필요해지면 추가 조사.

또한 GEMINI.md(`~/.gemini/GEMINI.md`)에는 agy가 `ask_permission` 도구로 이바에게 직접
권한을 요청하도록 지시돼 있다. nomad-kant-looper처럼 `--print`(비대화형) 모드로 부르면 물어볼
상대가 없어서, `--dangerously-skip-permissions`와 이 기대 동작이 충돌해 agy가 프롬프트를
무시하고 엉뚱한 응답(예: 자기소개, 무관한 상태 보고)을 내는 현상을 여러 번 관찰했다.
read-only 롤에서 스킵 플래그 자체를 없앤 이후로는 재현되지 않았다.

## 5. 모델 ID — agy 1.1.x부터 `--model` 플래그는 표시 이름만 받는다

agy 1.1.x(2026-07 확인, `agy --version` = 1.1.3)에서 `--model` 플래그에 raw ID를
주면 즉시 거부된다:

```
Error: invalid --model "gemini-3.5-flash": model gemini-3.5-flash is not
recognized as a known model or custom model in settings

Available models:
  Gemini 3.5 Flash (Medium)
  Gemini 3.5 Flash (High)
  Gemini 3.5 Flash (Low)
  Gemini 3.1 Pro (Low)
  Gemini 3.1 Pro (High)
  Claude Sonnet 4.6 (Thinking)
  Claude Opus 4.6 (Thinking)
  GPT-OSS 120B (Medium)
```

`agy models`가 보여주는 표시 이름(공백 포함)을 그대로 `--model`에 넘겨야 동작한다.
`gemini-3.1-flash-lite`는 목록에서 사라졌다 — 대체품이 필요하면
`Gemini 3.5 Flash (Low)`가 가장 가깝다. "Gemini 3.5 Pro"는 존재하지 않는다
(3.5는 Flash만, Pro는 3.1 계열).

kant-looper 내부 식별자(`model-selector.sh`, `fallback-dispatcher.sh`,
`kant-loop.sh`에 하드코딩된 `gemini-3.5-flash`, `gemini-3.1-pro-preview` 등)는
짧고 안정적인 형태 그대로 유지하고, 표시 이름 변환은
`scripts/adapters/adapter-agy.sh`의 normalization case가 책임진다
(opencode 어댑터의 provider 정규화 패턴과 동일). 매핑 테이블에 없는
이름은 WARN 로그 후 raw 값 그대로 시도(어댑터 방어적 폴백).

### 5-1. agy 1.1.5 갱신 (2026-07-24 확인) — Gemini 3.6 Flash 추가 + `--effort` 신규 플래그

`agy --version` = 1.1.5에서 `agy models`가 내놓는 형식이 표시 이름이 아니라
소문자 canonical ID(`gemini-3.6-flash-medium` 등)로 바뀌었다:

```
gemini-3.6-flash-high
gemini-3.6-flash-medium
gemini-3.6-flash-low
gemini-3.5-flash-high
gemini-3.5-flash-medium
gemini-3.5-flash-low
gemini-3.1-pro-high
gemini-3.1-pro-low
claude-sonnet-4-6
claude-opus-4-6-thinking
gpt-oss-120b-medium
```

실측 확인 결과 (`--sandbox read-only --mode plan`으로 실제 호출):

- `--model "gemini-3.6-flash-medium"` (canonical ID) → **동작함**
- `--model "Gemini 3.6 Flash (Medium)"` (기존 표시 이름 패턴) → **여전히 동작함**
- `--model "Gemini 3.6 Flash (Low)"` / `"Gemini 3.6 Flash (High)"` → **동작함**
- `--model "gemini-3.6-flash"` (레벨 없는 bare 이름) → **거부됨**:
  ```
  Error: invalid model selection (--model "gemini-3.6-flash" --effort ""):
  --model gemini-3.6-flash requires --effort (available: low, medium, high)
  ```
  즉 CLI에 새 `--effort low|medium|high` 플래그가 생겼고, bare 모델 이름은
  이 플래그와 짝지어야 한다. kant-looper는 이 신규 인터페이스를 채택하지
  않고 기존처럼 **완전한 표시 이름을 `--model`에 통째로 넘기는 방식을 유지**한다
  (`adapter-agy.sh`의 `gemini-3.6-flash` → `"Gemini 3.6 Flash (Medium)"` 정규화).
  `--effort` 플래그 자체는 아직 어댑터에서 쓰지 않음 — 필요해지면 별도 조사.

결론: 표시 이름 정규화 방식(5번 항목의 패턴)은 agy 1.1.5에서도 그대로 유효하다.
`gemini-3.5-flash` 관련 매핑은 회귀 없이 계속 동작 확인됨.

## 6. Stitch MCP는 시켜야 쓴다 — 알아서 안 씀

agy는 GEMINI.md 설정으로 Stitch MCP(Google의 UI 디자인 생성 도구, GCP 프로젝트 "Stitch")에
이미 연결돼 있지만, **TASK.md/프롬프트에 "Stitch를 먼저 호출해서 시안을 만들어라"라고
명시하지 않으면 그냥 코드를 직접 짜고 끝낸다.** "UI 만들어줘" 정도로는 Stitch를 안 쓴다.
필요하면 "필수 절차"로 명시하고, `notes_for_reviewer`에 실제 호출 여부를 남기라고 요구할 것
(이번에 이렇게 명시하니 실제로 호출하고 프로젝트 ID까지 verdict JSON에 남겼다).

같은 이유로, "사람 이미지 쓰지 마"처럼 지켜야 할 제약도 애매하게 말하면 (예: "저작권
문제 없게") 모델이 스스로 "AI로 새로 생성한 인물 사진이면 괜찮다"고 자체 해석해서 위반할
수 있다. 금지 항목은 실사/AI생성/일러스트/실루엣 등 구체적 형태까지 나열해야 한다.

## 7. IDE 쪽엔 네이티브 worktree 모드가 있다 (CLI --print엔 해당 없음)

공식 문서(Getting Started)에 Antigravity **IDE**의 에이전트 시작 모드로 "New Worktree Mode:
The agent operates in an isolated Git worktree"가 있다. 이건 IDE의 대화형 세션 개념이고,
kant-looper가 쓰는 `agy --print`(비대화형 단발 호출) 경로에는 노출되지 않는 것으로 보임 —
CLI reference에서 이에 대응하는 `--worktree` 류 플래그를 찾지 못했다. 그래서 nomad-kant-looper는
worktree 격리를 agy에 맡기지 않고 `timeout-runner.sh`의 cwd 강제로 직접 보장한다
(위 2번). 나중에 CLI에도 동등한 옵션이 생기면 이중 방어로 추가 검토.

## 8. Playwright MCP 연동 완료 (2026-07-25, 니체/agy 보고) — 브라우저 실시간 시각 검증

**확인됨** — 로컬 환경에서 직접 확인:

- `~/.gemini/antigravity/mcp_config.json`에 `playwright` 서버 등록됨
  (`npx -y @playwright/mcp@latest`).
- `npx playwright install chromium`으로 `~/Library/Caches/ms-playwright/`에
  Chromium 바이너리 설치 확인됨 (`chromium-1234`, 설치일 2026-07-25).

이 연동으로 agy는 UI를 정적 코드 생성으로 끝내지 않고, 실행 중인 개발 서버를
Playwright MCP(`navigate`, `click`, `snapshot` 등)로 직접 조작하며 콘솔 에러·DOM
렌더링 결함·반응형 레이아웃을 스스로 검증할 수 있다.

**Stitch(§6)와 같은 원칙이 적용된다 — 시켜야 쓴다.** MCP가 연결돼 있다는 사실이
곧 agy가 알아서 브라우저 검증을 수행한다는 뜻은 아니다. "UI 만들어줘" 정도로는
검증 단계를 건너뛸 수 있으므로, TASK.md나 프롬프트에 검증을 **필수 절차**로
명시해야 한다. 예: "구현 후 개발 서버를 띄우고 Playwright MCP로 실제 렌더링과
동작을 최종 검증하라. 검증 결과(스크린샷 유무, 콘솔 에러 여부)를
`notes_for_reviewer`에 남겨라."

아직 확인 안 된 것: agy가 read-only 롤(plan/review/verify, `--mode plan`)에서도
Playwright MCP의 `navigate`/`click` 같은 조작형 툴을 실제로 실행하는지, 아니면
이것도 `--mode plan`의 "쓰기 무시" 범위에 걸리는지는 실측 전이다. write 계열
role(implement/repair)에서 먼저 실측하고 이 항목을 갱신할 것.

## 9. `--print-timeout`을 outer role timeout과 동기화 (2026-07-26)

**확인됨** — 로컬 `agy --version`은 `1.1.7`, `agy --help`에는 다음 옵션이 있다:

```
--print-timeout   Timeout for print mode wait (default 5m0s)
```

`agy --print`는 별도의 응답 대기 타이머를 가진다. 이전 `adapter-agy.sh`는 이
플래그를 넘기지 않아 기본 5분이 적용됐고, 긴 implement/repair 요청이
`Error: timeout waiting for response`로 약 306~309초에 종료될 수 있었다. 이는
`timeout-runner.sh`의 role별 outer timeout(기본: plan 600초, review/verify 900초,
implement/repair 1800초)과 독립적으로 발생하는 조기 실패다.

adapter는 이제 `timeout-runner.sh timeout-for <role>`가 돌려준 실제 값(환경변수
override 포함)을 `${timeout}s` 형식으로 `--print-timeout`에 명시 전달한다. 따라서
agy 내부 대기 제한과 harness outer 제한은 항상 동일하다. 기본 적용값은 plan
`600s`, review/verify `900s`, implement/repair `1800s`이고, read-only role을
별도로 과도하게 늘리지 않는다. 기존 sandbox/mode/permission role 분기는
변경하지 않았다.

## 10. headless 호출이 사용자 확인 대기로 멈추는 문제 수정 (2026-07-27)

codex(gpt-5.6-sol, review role) 진단에 따라 비대화형 `--print`/`exec` 호출이
사용자 응답을 기다리며 outer timeout(최대 1800초)까지 낭비되는 현상의 원인을
세 군데에서 수정했다.

### 10-1. codex LSP 설치 게이트 (`adapter-codex.sh`)

codex CLI의 OMO 플러그인(lsp-daemon)이 headless `implement`/`repair` 호출 중
"ACTION REQUIRED — ASK THE USER whether to install this LSP server"를 반복
출력하는데, 모델이 `lsp_install_decision` 도구를 호출하지 않고 그대로
멈추는 현상이 실측됐다 (19회 안내, 0회 decision 호출). approval policy는
core 승인 요청만 억제하고 이 별도 플러그인 게이트는 해결하지 못한다.

**수정 1 (승인 정책 명시)**: `adapter-codex.sh`의 `codex exec` 호출에
`-c approval_policy=never`를 명시적으로 추가했다 (기존: 사용자
`~/.codex/config.toml`의 `approval_policy=never`에 암묵적 의존). **주의**:
`-a`/`--ask-for-approval`은 최상위 `codex` 명령 전용이고 `codex exec`
서브커맨드에는 없다 — 실측 결과 `codex exec -a never`는
`unexpected argument '-a' found`로 즉시 실패한다. `codex exec`에서 같은
설정을 넘기려면 반드시 `-c approval_policy=<value>`를 써야 한다.

**수정 2 (플러그인 훅 게이트 자체 차단)**: `--disable plugin_hooks`만으로는
훅이 계속 발화함을 실측했다 (22건). `--disable plugins`를 추가하니 훅 호출이
0건으로 떨어졌다 — OMO 훅 시스템 자체가 등록되지 않아 LSP 설치 안내문이
생성되는 경로 자체가 없어진다. `adapter-codex.sh`의 모든 `codex exec` 호출에
기본으로 추가했고 (`KANT_CODEX_DISABLE_PLUGINS=0`으로 끌 수 있음), 사용자의
`~/.codex/config.toml` 전역 plugins 설정은 건드리지 않는다 — 플러그인이 없는
환경에서도 무해한 no-op이라 범용적으로 안전하다. 프롬프트 지시문(아래
10-3)은 이 수정에도 불구하고 최후 안전망으로 유지한다.

### 10-2. stdin 중앙화 (`timeout-runner.sh`)

5개 어댑터 중 `adapter-agy.sh`만 `timeout-runner.sh` 호출 시 `< /dev/null`로
stdin을 막고 있었다. 나머지 4개(codex, opencode, grok, claude)는 stdin이
열린 상태로 외부 CLI 프로세스가 실행될 수 있어, tty 기반 상호작용 경로가
있으면 멈출 위험이 있었다.

**수정**: `timeout-runner.sh`의 `run_with_timeout` 내부 `timeout_cmd` 분기와
fallback 분기에 공통으로 `< /dev/null`를 추가했다. Python wrapper 분기는
이미 `stdin=subprocess.DEVNULL`로 처리되어 있어 변경 없음. 한 곳에서 5개
어댑터 모두 안전해진다.

### 10-3. 프롬프트 headless 지시문 (`kant-loop.sh`)

두 프롬프트 빌더(`run_quick_mode` = quick 단일/chain 호출용,
`run_parallel_mode` = 병렬 검토용) 모두에 "비대화형(headless) 환경 — 확인
대기 금지" 섹션을 추가했다:

- 권한/설치/승인 여부를 묻는 도구(ask_permission, lsp_install_decision류)를
  만나면 응답을 기다리지 말고 즉시 보수적인 기본값을 선택.
- 확인이 꼭 필요하면 대기하지 말고 즉시 BLOCKED verdict로 보고하고 종료.

이 지시문은 agy의 `ask_permission`(`--dangerously-skip-permissions`가
대상이 아닌 별도 상호작용 경로)과 codex의 플러그인 LSP 게이트 모두에
대응한다. 프롬프트에 의존하는 방식이므로 모델이 지시문을 따르지 않을
가능성은 남아 있으며, 이 경우 timeout이 최종 안전망이다.

### 10-4. agy `ask_permission` — 개인 설정이 필요한 유일한 항목

agy는 codex와 달리 "컨텍스트 파일(GEMINI.md)을 무시하라"는 CLI 플래그가
없다 (`agy --help` 확인, `--dangerously-skip-permissions`는 일반 tool
permission 자동승인만 다루고 `ask_permission`은 대상이 아니다). 따라서 이
문제는 어댑터 플래그만으로 완결되지 않고, **사용자의 `~/.gemini/GEMINI.md`
자체에 예외 조항이 있어야** headless 호출이 멈추지 않는다.

이 저장소를 새로 설치하는 사용자는 자신의 `GEMINI.md`에 `ask_permission`
지시문이 있다면(또는 앞으로 추가한다면) 아래 취지의 예외를 함께 넣을 것을
권장한다:

> 단, `--print`(비대화형/headless) 모드로 실행 중일 때는 예외입니다. 이때는
> 응답할 사람이 없으므로 `ask_permission`을 호출하지 않습니다. 권한이
> 필요하면 스스로 판단해 가장 보수적인 기본값으로 진행하거나, 대기하지
> 말고 그 사유를 남기고 종료합니다.

10-3의 프롬프트 지시문이 최후 안전망 역할을 하지만, GEMINI.md 자체의
전역 지시문이 매 세션 초기에 강하게 주입되므로 예외 조항 없이는 프롬프트
지시문과 상충할 수 있다. 이 항목만은 어댑터 스크립트로 자동화할 수 없는
개인 설정 영역이라 문서화로 남긴다.

### 하지 않은 것 (범위 제한)

- "확인 대기 상태를 조기 감지해 강제 종료하는" 감시 로직은 재도입하지
  않았다 (v0.8에서 의도적으로 제거된 no-progress detector와 유사 범주).
- agy의 미문서화된 내부 설정(`auto_interaction_behavior` 등)은 건드리지
  않았다 (공식 CLI 인터페이스로 확인되지 않음).
- opencode/grok/claude 어댑터의 개별 상호작용 정책 재검토는 별도 검토 후.

## 참고 링크

- https://antigravity.google/docs/cli/using (Settings, quick tips, keybindings)
- https://antigravity.google/docs/cli/reference (슬래시 커맨드, 기본 키바인딩, settings.json 전체 표)
