# 멀티모델 코딩 에이전트·도구 호출 라우팅 가이드

- 기준일: 2026-07-24
- 대상: nomad-kant-looper가 실제로 호출하는 5개 도구(codex, opencode, grok, agy, claude)와
  그 안에서 SKILL.md Step 2로 실제 선택 가능한 모델만 다룬다. 시장 전체 모델
  서베이가 아니다.
- 이 문서는 참고 자료다 — 어떤 스크립트도 이 표를 파싱해서 강제하지 않는다.
  클로드가 매 작업마다 이 표를 참고해서 직접 판단한다(SKILL.md Step 2 "자동 선택").
- 용어: AGY(Antigravity)는 모델명이 아니라 Google의 에이전트 실행 하네스다.
  "Codex 5.6"은 단일 모델이 아니라 `gpt-5.6-sol/terra/luna` 모델군이다.

---

## 1. 실제 사용 가능한 모델

### Codex (OpenAI)

| 모델 | 특징 | 적합한 작업 |
|---|---|---|
| `gpt-5.6-sol` | 최상위 — 복잡한 코딩, 컴퓨터 사용, 연구, 보안 | 핵심 아키텍처, 어려운 디버깅, 고위험 변경 |
| `gpt-5.6-terra` | 균형형 — 일상 성능 대비 저비용 | 일반 기능 구현, 저장소 유지보수 |
| `gpt-5.6-luna` | 효율형 — 빠르고 저렴 | 추출, 변환, 테스트 생성, 정형 수정 |

### OpenCode (Z.AI GLM / MiniMax)

| 모델 | 특징 | 적합한 작업 | 등급 |
|---|---|---|---|
| `glm-5.2` | 1M 컨텍스트, 장기 프로젝트 맥락 유지 | 대형 저장소, 장시간 리팩터링 | PRIMARY_EFFICIENT |
| `MiniMax-M3` | 1M 컨텍스트, 장기 에이전트 작업 | 대형 저장소·장기 작업 (glm-5.2 대안) | PRIMARY_EFFICIENT |
| `glm-4.7` | 실용형, 200K 컨텍스트, 비용·품질 균형 | 일상 개발 (명시 호출만) | LEGACY_EMERGENCY |
| `MiniMax-M2.7` | 일반 코딩, 비용 균형 | 일상 개발 (명시 호출만) | LEGACY_EMERGENCY |
| `Kimi-K3` | Moonshot AI, opencode-go 프로바이더 | 실측 검증 전 (명시 호출만) | UNVERIFIED_EXPLICIT_ONLY |

`glm-4.7`/`MiniMax-M2.7`은 2026-07-24부터 정상 자동 라우팅·fallback에서
제외됐다 (삭제 아님 — `--agent opencode --model glm-4.7` 등 명시 호출은 계속
지원, `KANT_ENABLE_LEGACY_FALLBACK=1`일 때만 emergency로 편입). 자세한 내용은
`references/fallback-table.md` 참고.

`Kimi-K3`는 2026-08-03에 opencode-go 프로바이더 모델로 추가됐다. glm-4.7 등
legacy 모델과 달리 예전에 primary였다가 격하된 게 아니라 **신규 모델이라
아직 실측 데이터가 없는** 경우다 — 그래서 legacy emergency pool에도 넣지
않고, T0~T3 자동 라우팅 티어 풀에도 넣지 않았다. `--agent opencode --model
Kimi-K3`로 명시 호출만 가능하고, 실패 시 `references/fallback-table.md`의
전용 고정 체인(codex → agy → grok → claude)으로 넘어간다. 실측이 쌓이면
사용자 승인 하에 PRIMARY_EFFICIENT 티어 편입을 재검토한다.

주의(2026-07-18 실측): 같은 조합(opencode + 같은 태스크)에서 glm-4.7이 verdict
JSON을 누락하는 사례가 보고됐으나, 독립 재현 시 2/2 정상 통과해 재현이
엇갈렸다. 위 legacy 격리는 이 실패 사례와도 무관하지 않다 — 정상 경로에서
빼두면 재현 안 되는 실패의 영향 범위도 함께 줄어든다.

### Grok (xAI)

| 모델 | 특징 | 적합한 작업 |
|---|---|---|
| `grok-4.5` | 터미널, Rust/C/C++, 풀스택, 빠른 도구 루프 | 시스템/터미널 코딩 |

`grok-4.3`, `grok-build-0.1`은 2026-07-24부로 호출 모델에서 삭제됐다
(명시 호출도 거부됨 — `scripts/kant-loop.sh`의 `validate_agent_model_compatibility`
가 즉시 거부). 필요하면 `grok-4.5` 하나로 대체한다.

### Antigravity (Google Gemini)

| 모델 | 특징 | 적합한 작업 |
|---|---|---|
| `gemini-3.6-flash` | 멀티모달, 브라우저/UI, 빠른 반복 (기본값, Medium) | UI/화면 기반 구현 |
| `gemini-3.5-flash` | 이전 기본값 | 명시 호출 지원 |
| `gemini-3.1-pro-preview` | 복잡한 설계, 정밀한 reasoning | 복잡한 멀티모달 설계·분석 |

agy는 Stitch MCP(Google UI 디자인 생성 도구)에 연결돼 있지만, 프롬프트에
명시하지 않으면 쓰지 않는다 — 자세한 내용은 `references/agy-cli-notes.md` §6.
agy CLI 버전별 모델 ID 형식 변화(1.1.3 → 1.1.5, `--effort` 플래그 등)도
같은 문서 §5-1에 기록돼 있다.

agy는 2026-07-25부터 Playwright MCP에도 연결돼 브라우저 조작·시각 검증이
가능하지만, 이것도 Stitch와 같은 원칙이 적용된다 — 프롬프트에서 검증을
필수 절차로 명시해야 실제로 쓴다. 자세한 내용은 같은 문서 §8 참고.

### Claude

자체 기본 모델을 쓴다. MiniMax 모델 ID는 선택하지 않는다(OpenCode 전용).

---

## 2. 작업 난도별 매핑 (SKILL.md의 T0~T4 정의와 동일)

| 등급 | 설명 | 모델 예 |
|---|---|---|
| T0 | 읽기·요약·정형 변환 | `gpt-5.6-luna`, `gemini-3.6-flash`, `MiniMax-M3` |
| T1 | 한두 파일·완료 조건 명확 | `gpt-5.6-terra`, `gemini-3.6-flash`, `glm-5.2`, `MiniMax-M3` |
| T2 | 여러 파일·일반 설계 판단 | `gpt-5.6-terra`, `glm-5.2`, `grok-4.5` |
| T3 | 저장소 전체 영향·모호성 큼 | `gpt-5.6-sol`, `glm-5.2`, `grok-4.5`, `MiniMax-M3`, `gemini-3.1-pro-preview` |
| T4 | 장기·다중 시스템·고위험 | 클로드가 계획·구현자 선정·독립 리뷰를 매번 직접 조합한다. 자동 상향 체인은 없다 |

독립 리뷰가 필요하면 구현에 쓴 것과 다른 공급자의 모델을 고른다 — 같은 모델의
오류가 리뷰에서도 그대로 반복되는 걸 막기 위해서다.

---

## 3. 실제 어댑터 호출 계약

kant-loop.sh는 MCP 프로토콜이나 구조화된 JSON 요청 스키마를 쓰지 않는다.
실제 흐름은 다음과 같다:

```
kant-loop.sh run TASK.md --quick --agent <tool> --model <model>
  → scripts/adapters/adapter-<tool>.sh call <role> <prompt_file> <worktree> <model>
  → CLI를 프롬프트 파일 내용으로 직접 호출 (timeout-runner.sh가 timeout 강제)
  → 응답을 <worktree>/.kant-looper/response-<tool>-<role>.{txt,json}에 저장
  → verdict-extractor.sh가 JSON 또는 <verdict> 태그를 추출·검증
  → PASS / CHANGES_REQUESTED / BLOCKED / INVALID_OUTPUT
  → 도구 실패·INVALID_OUTPUT 시 fallback-dispatcher.sh가 체인의 다음 도구/모델로 전환
```

성공 판정은 자연어 "완료했습니다"가 아니라 위 verdict와 실제 git diff 존재
여부로 한다(`verify_changed_files`, `do_safety_check`, `gate-runner.sh`).
verdict 스키마 상세는 `references/archive/hprar/verdict-schema.md` 참고.

---

## 4. 보안

`references/safety-promises.md` 참고. 여기서 반복하지 않는다.

---

## 5. 공식 출처

### Z.AI
- GLM-5.2: https://docs.z.ai/guides/llm/glm-5.2
- 모델 전환·1M 설정: https://docs.z.ai/devpack/latest-model
- GLM-4.7: https://docs.z.ai/guides/llm/glm-4.7
- 릴리스 노트: https://docs.z.ai/release-notes/new-released

### OpenAI
- Codex 모델: https://learn.chatgpt.com/docs/models
- GPT-5.6 발표·평가: https://openai.com/index/gpt-5-6/
- Codex CLI GitHub: https://github.com/openai/codex

### xAI
- Grok 4.5: https://docs.x.ai/developers/grok-4-5

### Google
- Antigravity: https://antigravity.google/
- Antigravity 문서: https://antigravity.google/docs
- Gemini 모델: https://ai.google.dev/gemini-api/docs/models
- Gemini 종료 일정: https://ai.google.dev/gemini-api/docs/deprecations

### MiniMax
- 모델 목록: https://platform.minimax.io/docs/guides/models-intro
- M3 발표: https://www.minimax.io/blog/minimax-m3
- M2.7: https://www.minimax.io/models/text/m27

### Moonshot AI (Kimi)
- 공식 출처 미확정 — 확인되면 추가한다. opencode-go 프로바이더를 통해서만
  호출한다(`references/fallback-table.md` 참고).

---

## 6. 유지보수

모델이 바뀌거나(신규 출시·단종·ID 변경) 라우팅·verdict 관련 이슈가 실제로
발견되면 그때 이 문서와 SKILL.md Step 2를 함께 갱신한다. 정해진 점검 주기는
두지 않는다 — 지켜지지 않는 일정을 문서에 남겨두는 것 자체가 노이즈다.
