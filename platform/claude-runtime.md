# `platform/claude-runtime.md` — Claude Code (Meta Agent Host)

이 파일은 **Claude Code 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.
런타임별 차이 중 Claude Code에 해당하는 설치 경로, 백그라운드 실행, 훅 관련
세부 내용을 여기에 모은다.

> **파일명에 대하여**: 원래 `platform/claude.md`로 만들었으나, macOS 등
> 대소문자 구분 없는 파일시스템에서 Claude Code가 이를 `CLAUDE.md`(프로젝트
> 자동 지침 파일)로 오인해 매 세션 자동 로드하는 문제가 발견되어
> `claude-runtime.md`로 리네임했다.

## 설치 경로

기본 설치 경로는 `$HOME/.claude/skills/nomad-kant-looper`이다.

이 경로는 이 저장소(nomad-kant-looper)의 **git worktree**로 구현되어 있다.
즉 Claude Code가 읽는 스킬 디렉터리와 저장소의 작업 브랜치가 같은 git 저장소를
공유한다.

## 백그라운드 실행 (`--detach`)과 완료 확인

**왜 `--detach`가 기본인가**: Claude Code의 Bash 도구는 동기 blocking 호출에
기본 120초, 최대 600초(600000ms)까지만 대기한다. 반면 kant-loop.sh 내부 role별
timeout은 plan/verify 600초, review 900초, implement/repair 1800초다(기본
role은 implement). 즉 `--detach` 없이 그냥 `run`을 부르면(foreground), 작업이
조금만 길어져도 kant-loop.sh 자체 timeout이 걸리기 전에 Bash 도구 쪽이 먼저
호출을 끊어버릴 수 있다 — 이 시점엔 하위 프로세스가 실제로 죽었는지, 계속
도는지, 완료됐는지 이 런타임에서 신뢰성 있게 확인할 방법이 없다. foreground가
금지는 아니지만 매번 도박이라, plan/verify처럼 확실히 짧게 끝나는 경우가
아니면 `--detach → await`를 기본으로 쓴다.

`--detach`는 사람에게 macOS 알림을 줄 뿐 Claude Code에게는 아무 신호도 오지
않는다. `--detach`로 던진 뒤 바로 이어서 `await <run_id>`를 **Bash 도구의
`run_in_background: true`**로 호출해야 완료 시 하네스가 Claude를 깨운다.
`--detach`만 실행하고 후속 `await` 없이 턴을 끝내면 안 된다(2026-07-17 실측:
이걸 빠뜨려서 사용자가 직접 macOS 알림을 보고 폴링해야 했음).

```bash
bash "$SKILL_DIR/scripts/kant-loop.sh" run "TASK.md" --quick --agent "$tool" --model "$model" --detach
# → run_id 즉시 반환
# 곧바로 이어서, Bash 도구 run_in_background: true로:
bash "$SKILL_DIR/scripts/kant-loop.sh" await "$run_id"
```

`.claude/settings.json`의 PostToolUse(Bash) 훅(`scripts/hooks/kant-loop-auto-await.sh`,
`asyncRewake: true`)은 실험적으로 남겨뒀지만 **신뢰할 수 없다고 판명됨**(2026-07-19
실측: 3회 중 1회 정상 작동, 1회는 kant-loop.sh 자체 버그로 조기 오탐, 1회는 완료·
커밋까지 됐는데도 원인 불명으로 완전히 침묵). 훅에 의존하지 말고 항상 위 수동
`await` 패턴을 그 자리에서 실행할 것.

## `allowed-tools` frontmatter

Claude Code의 `Bash(...)` glob 권한 문법은 `SKILL.md` 프론트매터에 그대로
유지된다(`platform/README.md`의 frontmatter 정책 참고) — 다른 런타임으로
옮기면 그 런타임이 해당 문법을 이해하지 못해 권한이 무의미해질 위험이 있어
호환성이 검증되기 전까지는 이동하지 않는다.

## Capability (Host Contract v1 기준)

> 기준: `platform/HOST-CONTRACT.md`. 아래 등급은 이번 세션에서 **실제로 관측된
> 증거**만 반영한다(관측되지 않은 항목은 `검증필요`).

| capability | 등급 | 근거/비고 |
|---|---|---|
| Skill 발견 (Skill Discovery) | native | `~/.claude/skills/nomad-kant-looper` worktree에서 로드됨이 관측됨 |
| 구조화된 선택 UI (graceful degradation) | native | 구조화된 선택 UI(AskUserQuestion류)로 도구/모델 선택이 관측됨 |
| `$SKILL_DIR` 해석 | native | `~/.claude/skills/nomad-kant-looper`로 정상 해석됨이 관측됨 |
| foreground 백엔드 호출 | native (비권장) | Bash 도구로 `kant-loop.sh run` 실행이 관측됨. 단 role timeout이 Bash 도구 상한(최대 600초)을 넘을 수 있어 기본 경로로 쓰지 않음 — 위 절 참고 |
| background 실행 (`--detach`) | native | `--detach`로 run_id 즉시 반환됨이 관측됨 |
| 완료 wake-up (background 완료 알림) | native | `await`를 Bash `run_in_background:true`로 호출 시 하네스가 깨움이 관측됨 |
| permission 모델 | native | `allowed-tools` glob 권한 문법(`Bash(...)`) 동작이 관측됨 |
