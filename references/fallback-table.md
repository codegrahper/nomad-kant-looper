# fallback-table.md

> 각 도구/모델의 fallback 체인. routing 가이드 8·10·11절을 그대로 코드에 옮긴 매핑.

이 표는 **skill 폴더 내부 SSOT**입니다. 절대 외부 경로 참조 안 함. 갱신은 `/nomad-kant-looper update-guide` 또는 이 파일 직접 편집.

## 모델 등급 (2026-07-24, Gemini 3.6 Flash 전환)

```text
PRIMARY_EFFICIENT
- glm-5.2
- MiniMax-M3
- gemini-3.6-flash (medium)

ESCALATION
- Codex
- Claude

LEGACY_EMERGENCY
- glm-4.7
- MiniMax-M2.7

UNVERIFIED_EXPLICIT_ONLY
- Kimi-K3
```

`LEGACY_EMERGENCY`는 **삭제가 아니다**. `glm-4.7`/`MiniMax-M2.7`은 `model-selector.sh`에
계속 남아 있고 `--agent opencode --model ...` 명시 호출은 항상 지원한다. 다만 정상
자동 라우팅·기본 모델·fallback 경로에서는 제외되고, `KANT_ENABLE_LEGACY_FALLBACK=1`
(기본값 `0`)일 때만 primary pool이 모두 소진된 뒤 emergency 후보로 편입된다
(`scripts/lib/fallback-dispatcher.sh`의 `KANT_LEGACY_EMERGENCY_POOL` +
`_maybe_insert_legacy_emergency()`). 즉 `SUPPORTED ≠ PRIMARY ≠ AUTOMATIC FALLBACK`.

glm-4.7은 실측에서 산출물은 정상인데 verdict parsing이 실패(`INVALID_OUTPUT`)한 사례가
있어, emergency 편입 시에도 실패한 원본 모델 자신은 재삽입하지 않고 즉시 다음 모델로
넘어간다.

`UNVERIFIED_EXPLICIT_ONLY`(2026-08-03 신설, `Kimi-K3`)는 `LEGACY_EMERGENCY`와 다르다 —
legacy는 예전에 primary였다가 격하된 모델이고, 이쪽은 **신규 추가라 아직 실측 데이터가
없는** 모델이다. 그래서 `KANT_LEGACY_EMERGENCY_POOL`(위 `LEGACY_EMERGENCY` 참고)에도
넣지 않았고, `KANT_ENABLE_LEGACY_FALLBACK=1`로도 자동 편입되지 않는다. 오직
`--agent opencode --model Kimi-K3` 명시 호출만 지원하며, 실패 시 아래
`special_cases`의 전용 고정 체인으로만 넘어간다. 실측이 쌓이면 사용자 승인 하에
PRIMARY_EFFICIENT(T0~T3 티어 풀) 편입을 재검토한다.

## 코드 매핑 (script에서 사용)

**(2026-07-24 재설계)** 이전에는 도구별로 사람이 손으로 "fallback_1/2/3"을 나열했다.
지금은 대신 **T0~T3 난이도 티어 풀**을 정의하고, 실패한 (tool,model)이 속한 가장
낮은 티어부터 같은 티어의 다른 provider를 우선 시도한 뒤 상위 티어로 확장하는
방식으로 체인을 **자동 생성**한다 (`scripts/lib/fallback-dispatcher.sh`의
`KANT_TIER_POOLS` + `get_tier_fallback_chain()`). "실패하면 감당 못 할 만큼 비싼
모델로 바로 건너뛰지 않고, 비슷한 체급부터 시도한다"는 원칙이다. 티어 풀은
`references/multimodel-coding-agent-routing-guide.md` §2의 T0~T3 표와 동일하다
(모델 하나가 여러 티어에 걸칠 수 있다 — 예: `glm-5.2`는 T1~T3 모두).

```yaml
tier_pools:
  T0:  # 읽기·요약·정형 변환
    - codex:gpt-5.6-luna
    - agy:gemini-3.6-flash
    - opencode:MiniMax-M3
  T1:  # 한두 파일·완료 조건 명확
    - codex:gpt-5.6-terra
    - agy:gemini-3.6-flash
    - opencode:glm-5.2
    - opencode:MiniMax-M3
  T2:  # 여러 파일·일반 설계 판단
    - codex:gpt-5.6-terra
    - opencode:glm-5.2
    - grok:grok-4.5
  T3:  # 저장소 전체 영향·모호성 큼
    - codex:gpt-5.6-sol
    - opencode:glm-5.2
    - grok:grok-4.5
    - opencode:MiniMax-M3
    - agy:gemini-3.1-pro-preview

# 예: opencode:glm-5.2 실패 → 가장 낮은 소속 티어(T1)부터 시작
#   T1 동료(codex:gpt-5.6-terra, agy:gemini-3.6-flash, opencode:MiniMax-M3)
#   → T2 확장(grok:grok-4.5) → T3 확장(codex:gpt-5.6-sol, agy:gemini-3.1-pro-preview)
#   → claude:default (항상 마지막)
```

정상 primary 8종(codex 3개 + opencode glm-5.2/MiniMax-M3 + agy gemini-3.6-flash +
grok-4.5)은 전부 이 티어 시스템으로 처리된다. 아래 4개는 티어 풀에 없는 **특수
케이스**라 `KANT_FALLBACK_CHAINS_LINEAR` 고정 테이블이 별도로 처리한다:

```yaml
special_cases:
  claude:default: [claude:default]  # 자기 자신 self-loop, 더 갈 곳 없음
  opencode:glm-4.7: [codex:gpt-5.6-terra, agy:gemini-3.6-flash, grok:grok-4.5, claude:default]        # legacy 명시 호출 실패 시
  opencode:MiniMax-M2.7: [codex:gpt-5.6-terra, agy:gemini-3.6-flash, grok:grok-4.5, claude:default]   # legacy 명시 호출 실패 시
  opencode:Kimi-K3: [codex:gpt-5.6-terra, agy:gemini-3.6-flash, grok:grok-4.5, claude:default]        # 신규·미검증 모델 명시 호출 실패 시
  agy:gemini-3.5-flash: [agy:gemini-3.6-flash, opencode:glm-5.2, claude:default]  # 이전 기본값 명시 호출 호환
```

on_429/on_401/on_timeout 등 백오프 정책은 티어와 무관하게 그대로 유지 —
`get_backoff_seconds()` 참고 (아래 실패 모드 표).

## 실패 모드별 1차 / 최종 대응

| 실패 모드 | 1차 | 최종 |
|---|---|---|
| timeout | 더 가벼운 같은 공급자 모델 | claude |
| 401 (auth) | 즉시 다른 공급자 | claude |
| 403 (forbidden) | 즉시 다른 공급자 | claude |
| 429 (rate limit) | wait 30s + 다른 공급자 | claude |
| 500/502/503 | retry 1회 (backoff 10s) | 다른 공급자 → claude |
| 504 (gateway timeout) | retry 1회 | 다른 공급자 → claude |
| connection refused | retry 1회 | 다른 공급자 → claude |
| DNS 실패 | retry 1회 | 다른 공급자 → claude |
| 형식 오류 (INVALID_OUTPUT) | 같은 모델 retry 1회 | 다른 모델 → claude |
| 도구 자체 에러 | 다른 모델 | claude |

## 호출 모드별 기본 라우트

`fallback-dispatcher.sh`의 `get_default_tool_model()`이 정의하는 route별 primary와 일치한다.
**fallback 후보는 여기에 수동으로 나열하지 않는다** — 위 `tier_pools`(T0~T3)를 기반으로
`get_tier_fallback_chain()`이 실패 시 자동 생성한다.

```yaml
routes:
  tiny:               { primary: openai/gpt-5.6-luna }
  standard_repo:      { primary: openai/gpt-5.6-terra }
  hard_repo:          { primary: openai/gpt-5.6-sol }
  huge_context:       { primary: zai/glm-5.2 }
  visual_browser:     { primary: google/gemini-3.6-flash (medium), harness: antigravity }
  independent_review: { rule: provider_must_differ_from_implementer }
```

## 호출 도구별 매핑 (script에서 사용)

```yaml
tool_to_default_model:
  codex: openai/gpt-5.6-terra        # T1/T2 기본
  codex_review: openai/gpt-5.6-sol   # 검증 단계
  grok: xai/grok-4.5
  opencode: zai/glm-5.2
  opencode_quick: minimax/MiniMax-M3 # T1 작업 시 (glm-4.7은 emergency 전용으로 이동)
  agy: google/gemini-3.6-flash (medium)  # Antigravity default (2026-07-24부터, 이전 gemini-3.5-flash)
  claude: default                    # claude 구독 로그인, --model 미지정
```

## TASK 키워드 → 라우트 매핑 (참고용 휴리스틱)

클로드가 작업을 판단할 때 참고하는 휴리스틱 — 이 표를 파싱하는 코드는 없다
(판단은 클로드가 그 자리에서 한다):

```yaml
keyword_to_route:
  ui:
    keywords: ["UI", "component", "screen", "stitch", "modal", "drawer", "tailwind"]
    route: visual_browser
    tool: agy

  test:
    keywords: ["test", "unit test", "fixture", "mock", "snapshot"]
    route: tiny
    tool: codex
    model: gpt-5.6-luna

  refactor:
    keywords: ["refactor", "migrate", "rewrite", "restructure", "cleanup"]
    route: hard_repo
    tool: opencode
    model: glm-5.2

  terminal:
    keywords: ["terminal", "cli", "shell", "bash", "zsh", "rust", "C++", "system"]
    route: standard_repo
    tool: grok

  review:
    keywords: ["review", "verify", "audit", "check", "validate"]
    route: independent_review
    tool: codex
    model: gpt-5.6-sol

  long_context:
    keywords: ["1M", "huge", "large repo", "entire codebase"]
    route: huge_context
    tool: opencode
    model: glm-5.2

  default:
    route: standard_repo
    tool: codex
    model: gpt-5.6-terra
```

## 무진전 처리 (현재 방식)

무진전 자동중단(`no-progress-detector.sh` / `NO_PROGRESS_LIMIT`)은 **v0.8에서 제거됐다** —
caller가 전혀 없는 죽은 코드였다(`platform/README.md` 참고). 현재는 무한 루프를
`timeout-runner.sh`의 role별 타임아웃(plan 600s / implement·repair 1800s / review·verify 900s)과
fallback 체인 소진만으로 방지한다. 별도의 diff/test 반복 감지 메커니즘은 없다.

## 가이드 갱신 절차

1. `$HOME/Downloads/multimodel-coding-agent-routing-guide.md`(`KANT_EXTERNAL_GUIDE_PATH`로 오버라이드 가능)를 사용자가 직접 편집 (또는 외부 출처에서 새로 받음)
2. `/nomad-kant-looper update-guide` 호출
3. Meta Agent가 diff 표시 → 사용자 승인
4. 클로드가 `references/multimodel-coding-agent-routing-guide.md`에 복사
5. Meta Agent가 `references/fallback-table.md`도 새 가이드에 맞춰 업데이트 제안(사용자가 한 번 더 승인)
6. 다음 작업부터 새 매핑 자동 적용

`references/fallback-table.md`는 사람이 읽는 참고 문서일 뿐이다. 실제
폴백 체인은 `scripts/lib/fallback-dispatcher.sh`의 `KANT_TIER_POOLS`
(정상 primary 8종 자동 생성) + `KANT_FALLBACK_CHAINS_LINEAR` 고정 테이블
(특수 케이스 4종)이 정의한다. 이 표를 고쳐도 실제 동작은 바뀌지 않는다 —
동작을 바꾸려면 `fallback-dispatcher.sh`를 직접 수정해야 한다. Code is
authoritative, documentation is descriptive.

## Dashboard 가시성 (2026-07-24 추가)

fallback이 실제로 발생하면 시도한 모든 (tool,model)과 최종 성공한 조합이
`scripts/lib/state_writer.py`를 거쳐 해당 run의 `run-state.json`
(`agents[].attempts[]`)과 `events.jsonl`(`fallback_attempt_*` 이벤트)에
그대로 남는다 — Kant Dashboard의 Pipeline/Activity 뷰에서 "누가 실패했고
최종적으로 누가 처리했는지"를 볼 수 있다. 스키마는
`docs/dashboard/STATE-CONTRACT.md` §1(agents[].attempts[])·§2
(fallback_attempt_* 이벤트) 참고.

## 환경별 기본값 오버라이드

다음은 환경에 따라 다를 수 있어, 운영 중 변경 가능:

```yaml
# 운영 중 자주 조정하는 값
OPERATION_TIMEOUT_SECONDS:
  plan: 600
  implement: 1800
  review: 900
  verify: 900
  repair: 1800

RETRY_POLICY:
  on_timeout:
    max_retries: 1
    backoff_seconds: 5
  on_rate_limit:
    max_retries: 1
    backoff_seconds: 30
  on_format_error:
    max_retries: 1
    backoff_seconds: 0
  on_network_error:
    max_retries: 2
    backoff_seconds: 10
```
