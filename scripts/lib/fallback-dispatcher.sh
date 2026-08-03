#!/usr/bin/env bash
# fallback-dispatcher.sh — 호출 실패 시 다른 도구/모델로 즉시 전환
#
# 이 스크립트가 nomad-kant-looper의 "사용자가 개입하는 순간 그것은 nomad-kant-looper가 아닙니다" 약속을 지킴.
# 어떤 도구/모델이 죽어도 작업은 claude까지 자동으로 이어짐.
#
# bash 3.2 호환.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_LOG="${KANT_FALLBACK_LOG:-${KANT_STATE_ROOT:-$HOME/.claude/state/nomad-kant-looper}/fallback.log}"

# ---------------------------------------------------------------------------
# Fallback 체인 정의 (references/fallback-table.md와 동기)
# ---------------------------------------------------------------------------
# 형식: "primary_tool|primary_model|fb_tool1|fb_model1|fb_tool2|fb_model2|..."
# 각 (tool, model) 쌍은 어댑터 호출 시 정확히 그 인자로 사용됨.
# 주의: 어댑터 이름(tool)은 실제 스크립트 이름과 일치해야 함 (예: adapter-opencode.sh).
#       모델은 같은 어댑터 내에서 다르게 시도 가능 (예: codex+gpt-5.6-luna).

# Fallback chain notes:
# - claude:default means "claude with its own default model" (no --model flag passed to Claude CLI)
# - MiniMax models are ONLY available through opencode agent, NOT through claude
# - Claude final fallback uses "default" sentinel, NOT MiniMax model IDs
#
# 모델 등급 정책 (2026-07-24, Gemini 3.6 Flash 전환 — references/fallback-table.md와 동기):
#   PRIMARY_EFFICIENT (정상 자동 라우팅): opencode:glm-5.2, opencode:MiniMax-M3, agy:gemini-3.6-flash
#   ESCALATION (고비용/고성능): codex 모델군, claude:default
#   LEGACY_EMERGENCY (자동 라우팅 제외, 명시 호출만 허용): opencode:glm-4.7, opencode:MiniMax-M2.7
#     KANT_ENABLE_LEGACY_FALLBACK=1일 때만 primary pool 소진 후 emergency로 편입됨 (기본값 0).
#     glm-4.7/MiniMax-M2.7 삭제 아님 — SUPPORTED ≠ PRIMARY ≠ AUTOMATIC FALLBACK.
#
# 특수 케이스 고정 테이블 (2026-07-24, T0~T3 티어 재설계 이후에도 유지 / 2026-08-03 Kimi-K3 추가)
# ---------------------------------------------------------------------------
# 아래 5개 항목은 "정상 primary 8종"(codex 3 + opencode glm-5.2/MiniMax-M3 +
# agy gemini-3.6-flash + grok-4.5)이 아니라 특수 케이스이므로, 티어 시스템이
# 아니라 이 고정 테이블이 그대로 처리한다:
#   - claude|default: 자기 자신 self-loop (claude가 최종 폴백이라 더 갈 곳 없음)
#   - opencode|glm-4.7, opencode|MiniMax-M2.7: legacy — 명시 호출이 실패했을 때의
#     전용 폴백. 정상 primary pool에서 자동으로 선택되지 않으므로 티어 테이블에
#     넣지 않는다.
#   - opencode|Kimi-K3: 신규(2026-08-03, opencode-go 프로바이더) — 아직 실측
#     검증 전이라 자동 라우팅(T0~T3 티어 풀)에는 넣지 않는다. 명시 호출
#     (`--agent opencode --model Kimi-K3`)만 지원하고, 실패 시에만 이 고정
#     체인으로 넘어간다.
#   - agy|gemini-3.5-flash: 이전 기본값 — 명시 호출 호환용 폴백만 유지.
# 정상 primary 8종의 체인은 get_tier_fallback_chain()이 T0~T3 풀에서 자동 생성한다
# (아래 KANT_TIER_POOLS 참고, references/multimodel-coding-agent-routing-guide.md
# §2 T0~T3 표와 동기).
declare -a KANT_FALLBACK_CHAINS_LINEAR=(
  "opencode|glm-4.7|codex|gpt-5.6-terra|agy|gemini-3.6-flash|grok|grok-4.5|claude|default"
  "opencode|MiniMax-M2.7|codex|gpt-5.6-terra|agy|gemini-3.6-flash|grok|grok-4.5|claude|default"
  "opencode|Kimi-K3|codex|gpt-5.6-terra|agy|gemini-3.6-flash|grok|grok-4.5|claude|default"
  "agy|gemini-3.5-flash|agy|gemini-3.6-flash|opencode|glm-5.2|claude|default"
  "claude|default|claude|default"
)

# ---------------------------------------------------------------------------
# T0~T3 난이도 티어 풀 (references/multimodel-coding-agent-routing-guide.md §2와 동기)
# ---------------------------------------------------------------------------
# 형식: "TIER|tool:model|tool:model|..." — 낮은 티어일수록 가볍고 저렴한 작업용.
# 같은 모델이 여러 티어에 걸쳐 있을 수 있다(예: glm-5.2는 T1~T3 모두 처리 가능).
# 폴백 시에는 실패한 (tool,model)이 속한 "가장 낮은" 티어를 시작점으로 삼아
# 같은 티어의 다른 provider부터 우선 시도하고, 소진되면 상위 티어로 확장한다 —
# "감당 못 할 만큼 비싼 모델로 바로 건너뛰지 않고, 비슷한 체급부터 시도한다"는
# 원칙. 마지막은 항상 claude:default.
declare -a KANT_TIER_POOLS=(
  "T0|codex:gpt-5.6-luna|agy:gemini-3.6-flash|opencode:MiniMax-M3"
  "T1|codex:gpt-5.6-terra|agy:gemini-3.6-flash|opencode:glm-5.2|opencode:MiniMax-M3"
  "T2|codex:gpt-5.6-terra|opencode:glm-5.2|grok:grok-4.5"
  "T3|codex:gpt-5.6-sol|opencode:glm-5.2|grok:grok-4.5|opencode:MiniMax-M3|agy:gemini-3.1-pro-preview"
)
KANT_TIER_ORDER=(T0 T1 T2 T3)

# 인자: tool model → 이 (tool,model)이 속한 가장 낮은 티어 (없으면 빈 문자열)
_tier_of() {
  local tool="$1" model="$2" line
  for line in "${KANT_TIER_POOLS[@]}"; do
    IFS='|' read -ra parts <<< "$line"
    local tier="${parts[0]}" i
    for ((i = 1; i < ${#parts[@]}; i++)); do
      if [ "${parts[$i]}" = "${tool}:${model}" ]; then
        echo "$tier"
        return 0
      fi
    done
  done
  echo ""
}

# 인자: tier → 그 티어 풀의 tool:model 목록 (줄 단위 출력)
_tier_pool_members() {
  local tier="$1" line
  for line in "${KANT_TIER_POOLS[@]}"; do
    IFS='|' read -ra parts <<< "$line"
    if [ "${parts[0]}" = "$tier" ]; then
      local i
      for ((i = 1; i < ${#parts[@]}; i++)); do
        echo "${parts[$i]}"
      done
      return 0
    fi
  done
}

# 인자: tool model → 티어 기반 자동 생성 체인 (콤마 구분 tool:model, 항상 claude:default로 끝남)
# 이 (tool,model)이 어느 티어에도 없으면 빈 문자열 반환 (호출측이 고정 테이블로 폴백).
get_tier_fallback_chain() {
  local tool="$1" model="$2" self="${tool}:${model}"
  local tier
  tier="$(_tier_of "$tool" "$model")"
  [ -n "$tier" ] || { echo ""; return 0; }

  local chain="" seen=",${self},"
  local t started=0
  for t in "${KANT_TIER_ORDER[@]}"; do
    if [ "$started" = "0" ]; then
      if [ "$t" = "$tier" ]; then started=1; else continue; fi
    fi
    local member
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      case "$seen" in
        *",${member},"*) continue ;;
      esac
      seen="${seen}${member},"
      if [ -z "$chain" ]; then chain="$member"; else chain="${chain},${member}"; fi
    done < <(_tier_pool_members "$t")
  done

  if [ -z "$chain" ]; then
    chain="claude:default"
  elif [ "$chain" != "claude:default" ] && [[ "$chain" != *",claude:default" ]]; then
    chain="${chain},claude:default"
  fi
  echo "$chain"
}

# primary pool이 모두 소진된 뒤 emergency 후보로만 편입되는 legacy 모델.
# KANT_ENABLE_LEGACY_FALLBACK=1일 때만 활성화되고, 실패한 원본 tool:model 자신은 제외한다
# (동일 모델 반복 재시도 금지 — glm-4.7의 INVALID_OUTPUT 실측 사례 참고).
declare -a KANT_LEGACY_EMERGENCY_POOL=(
  "opencode:glm-4.7"
  "opencode:MiniMax-M2.7"
)

# KANT_ENABLE_LEGACY_FALLBACK=1일 때 chain 끝(claude:default 직전, 없으면 맨 뒤)에
# legacy emergency 후보를 끼워 넣는다. 이미 chain에 있거나 실패한 원본과 같은 항목은 제외.
_maybe_insert_legacy_emergency() {
  local chain="$1" failed_tool="$2" failed_model="$3"
  local enable="${KANT_ENABLE_LEGACY_FALLBACK:-0}"

  if [ "$enable" != "1" ]; then
    echo "$chain"
    return 0
  fi

  local legacy_to_add="" entry
  for entry in "${KANT_LEGACY_EMERGENCY_POOL[@]}"; do
    if [ "$entry" = "${failed_tool}:${failed_model}" ]; then
      continue
    fi
    case ",$chain," in
      *",$entry,"*)
        continue
        ;;
    esac
    if [ -z "$legacy_to_add" ]; then
      legacy_to_add="$entry"
    else
      legacy_to_add="${legacy_to_add},${entry}"
    fi
  done

  if [ -z "$legacy_to_add" ]; then
    echo "$chain"
    return 0
  fi

  if [ -z "$chain" ]; then
    echo "$legacy_to_add,claude:default"
  elif [[ "$chain" == *",claude:default" ]]; then
    echo "${chain%,claude:default},${legacy_to_add},claude:default"
  elif [ "$chain" = "claude:default" ]; then
    echo "${legacy_to_add},claude:default"
  else
    echo "${chain},${legacy_to_add}"
  fi
}

# flat key-value로 변환: get_fallback_chain tool model → next tools/models (콤마 구분 "tool:model" 형식)
# 1) 특수 케이스(legacy 명시 호출, claude self-loop, 구버전 모델 호환)는 고정 테이블 우선.
# 2) 정상 primary 8종은 T0~T3 티어 풀에서 자동 생성한다.
get_fallback_chain() {
  local tool="$1" model="$2"

  local line chain=""
  for line in "${KANT_FALLBACK_CHAINS_LINEAR[@]}"; do
    IFS='|' read -ra parts <<< "$line"
    if [ "${parts[0]}" = "$tool" ] && [ "${parts[1]}" = "$model" ]; then
      local i=2
      while [ $i -lt ${#parts[@]} ]; do
        local next_tool="${parts[$i]}"
        local next_model="${parts[$((i+1))]}"
        if [ -z "$chain" ]; then
          chain="${next_tool}:${next_model}"
        else
          chain="${chain},${next_tool}:${next_model}"
        fi
        i=$((i+2))
      done
      _maybe_insert_legacy_emergency "$chain" "$tool" "$model"
      return 0
    fi
  done

  local tier_chain
  tier_chain="$(get_tier_fallback_chain "$tool" "$model")"
  if [ -n "$tier_chain" ]; then
    _maybe_insert_legacy_emergency "$tier_chain" "$tool" "$model"
    return 0
  fi

  echo ""
}

# 호환성을 위해 기본 fallback chain도 export
get_default_tool_model() {
  local task_kind="${1:-standard_repo}"
  case "$task_kind" in
    tiny) echo "codex:gpt-5.6-luna" ;;
    standard_repo) echo "codex:gpt-5.6-terra" ;;
    hard_repo) echo "codex:gpt-5.6-sol" ;;
    huge_context) echo "opencode:glm-5.2" ;;
    visual_browser) echo "agy:gemini-3.6-flash" ;;
    independent_review) echo "codex:gpt-5.6-sol" ;;
    *) echo "codex:gpt-5.6-terra" ;;
  esac
}

# ---------------------------------------------------------------------------
# 실패 모드별 1차 대응 시간
# ---------------------------------------------------------------------------

# 인자: failure_mode
# 출력: backoff 초
get_backoff_seconds() {
  local mode="$1"
  case "$mode" in
    TIMEOUT) echo 5 ;;
    RATE_LIMITED) echo 30 ;;
    AUTH_FAILED) echo 0 ;;        # 즉시 다른 공급자
    NETWORK_ERROR) echo 10 ;;
    INVALID_OUTPUT) echo 0 ;;    # 즉시 재시도
    INFRA_ERROR) echo 5 ;;
    *) echo 3 ;;
  esac
}

# run의 state_dir/phase-events.log에 kant-loop.sh의 log_event()와 동일한 포맷으로
# 이벤트를 남긴다. Dashboard(events.jsonl/run-state.json)가 실제 폴백 시도 전체를
# 볼 수 있게 하는 것이 목적 — 이 스크립트 자체는 kant_observe()를 직접 부르지 않고,
# kant-loop.sh가 do_fallback() 리턴 직후 남기는 log_event() 호출이 재생성을 트리거한다
# (state_writer.py는 phase-events.log 전체를 매번 다시 읽는 idempotent 설계라 순서 무관).
_log_state_event() {
  local state_dir="$1" body="$2"
  [ -n "$state_dir" ] && [ -d "$state_dir" ] || return 0
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $body" >> "$state_dir/phase-events.log"
}

# ---------------------------------------------------------------------------
# fallback 실행
# ---------------------------------------------------------------------------
# 인자:
#   $1 = failed_tool
#   $2 = failed_model
#   $3 = failure_mode (TIMEOUT|RATE_LIMITED|AUTH_FAILED|NETWORK_ERROR|INVALID_OUTPUT|INFRA_ERROR)
#   $4 = prompt_file
#   $5 = worktree_path
#   $6 = role (plan|implement|review|verify|etc)
#   $7 = state_dir (선택 — 있으면 각 시도를 phase-events.log에도 기록해 Dashboard에 노출)
# 출력 (stdout): 시도 성공한 tool:model (콤마 구분 fallback chain 안에 첫 번째 성공)
# 종료 코드: 0 = fallback에서 성공, 1 = 모두 실패 (claude 포함)

do_fallback() {
  local failed_tool="$1" failed_model="$2" failure_mode="$3" prompt_file="$4" worktree="$5" role="${6:-implement}"
  local state_dir="${7:-}"

  local chain
  chain="$(get_fallback_chain "$failed_tool" "$failed_model")"
  if [ -z "$chain" ]; then
    chain="claude:default"
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback: $failed_tool:$failed_model ($failure_mode) → chain=$chain" >> "$FALLBACK_LOG"

  # 콤마로 분리된 chain을 순회
  IFS=',' read -ra pairs <<< "$chain"
  local pair next_tool next_model attempt rc
  for attempt in 1 2; do
    for pair in "${pairs[@]}"; do
      IFS=':' read -ra tm <<< "$pair"
      next_tool="${tm[0]}"
      next_model="${tm[1]}"

      # claude는 마지막 폴백이므로 2회차에서는 1회만 더 시도
      if [ "$attempt" -ge 2 ] && [ "$next_tool" = "claude" ]; then
        continue
      fi

      # 1차 backoff
      local backoff
      backoff=$(get_backoff_seconds "$failure_mode")
      if [ "$backoff" -gt 0 ]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback backoff ${backoff}s before $next_tool:$next_model" >> "$FALLBACK_LOG"
        sleep "$backoff"
      fi

      # 호출 — 어댑터가 rc=0으로 응답해도 verdict=PASS일 때만 SUCCESS로 간주.
      # 단, role=review는 CHANGES_REQUESTED도 정상적인 리뷰 완료이므로 SUCCESS로
      # 간주한다 — 그렇지 않으면 CHANGES_REQUESTED를 낸 리뷰어를 실패 취급하고
      # PASS가 나올 때까지 다른 리뷰어를 계속 시도하는 "리뷰어 쇼핑"이 된다.
      # (BLOCKED/INVALID_OUTPUT 응답은 role에 관계없이 다음 fallback 시도)
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback attempt: $next_tool:$next_model role=$role" >> "$FALLBACK_LOG"
      _log_state_event "$state_dir" "FALLBACK_ATTEMPT role=$role tool=$next_tool model=$next_model status=trying attempt=$attempt from=$failed_tool:$failed_model"
      local fb_output fb_verdict
      if fb_output="$("$LIB_DIR/../adapters/adapter-$next_tool.sh" call "$role" "$prompt_file" "$worktree" "$next_model")"; then
        fb_verdict="${fb_output%%|*}"
        if [ "$fb_verdict" = "PASS" ] || { [ "$role" = "review" ] && [ "$fb_verdict" = "CHANGES_REQUESTED" ]; }; then
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback SUCCESS: $next_tool:$next_model" >> "$FALLBACK_LOG"
          _log_state_event "$state_dir" "FALLBACK_ATTEMPT role=$role tool=$next_tool model=$next_model status=success"
          echo "$fb_output"
          return 0
        else
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback NOT_PASS: $next_tool:$next_model verdict=$fb_verdict (다음 fallback 시도)" >> "$FALLBACK_LOG"
          _log_state_event "$state_dir" "FALLBACK_ATTEMPT role=$role tool=$next_tool model=$next_model status=failed mode=NOT_PASS:$fb_verdict"
          # 다음 fallback으로 진행
        fi
      else
        rc=$?
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback FAIL: $next_tool:$next_model (rc=$rc)" >> "$FALLBACK_LOG"
        _log_state_event "$state_dir" "FALLBACK_ATTEMPT role=$role tool=$next_tool model=$next_model status=failed mode=rc:$rc"
      fi
    done
  done

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] fallback EXHAUSTED: all tools/models failed" >> "$FALLBACK_LOG"
  _log_state_event "$state_dir" "FALLBACK_EXHAUSTED role=$role from=$failed_tool:$failed_model chain=$chain"
  return 1
}

# ---------------------------------------------------------------------------
# 실패 모드 분류
# ---------------------------------------------------------------------------

# 인자: tool_name, exit_code, stderr_or_stdout
# 출력: TIMEOUT|RATE_LIMITED|AUTH_FAILED|NETWORK_ERROR|INVALID_OUTPUT|INFRA_ERROR
classify_failure() {
  local tool="$1" exit_code="$2" output="${3:-}"

  if [ "$exit_code" = "124" ]; then
    echo "TIMEOUT"
    return 0
  fi

  # HTTP 패턴
  if printf '%s' "$output" | grep -qE 'HTTP/[0-9.]+ 401|HTTP/[0-9.]+ 403|unauthorized|authentication failed|invalid api key'; then
    echo "AUTH_FAILED"
    return 0
  fi
  if printf '%s' "$output" | grep -qE 'HTTP/[0-9.]+ 429|rate limit|quota exceeded|too many requests'; then
    echo "RATE_LIMITED"
    return 0
  fi
  if printf '%s' "$output" | grep -qE 'connection refused|dns|network is unreachable|no route to host|getaddrinfo'; then
    echo "NETWORK_ERROR"
    return 0
  fi

  # INVALID_OUTPUT (JSON 파싱 실패) — exit 65
  if [ "$exit_code" = "65" ]; then
    echo "INVALID_OUTPUT"
    return 0
  fi

  echo "INFRA_ERROR"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "chain" ]; then
  shift
  get_fallback_chain "$@"
  exit 0
fi

if [ "${1:-}" = "classify" ]; then
  shift
  classify_failure "$@"
  exit 0
fi

if [ "${1:-}" = "default" ]; then
  shift
  get_default_tool_model "$@"
  exit 0
fi

if [ "${1:-}" = "run" ]; then
  shift
  do_fallback "$@"
  exit $?
fi

cat <<EOF
fallback-dispatcher.sh — 호출 실패 시 다른 도구/모델로 즉시 전환

사용법:
  fallback-dispatcher.sh chain <tool> <model>     # fallback 체인 출력 (콤마 구분)
  fallback-dispatcher.sh classify <tool> <rc> <output>   # 실패 모드 분류
  fallback-dispatcher.sh default <task_kind>       # 기본 도구:모델
  fallback-dispatcher.sh run <tool> <model> <mode> <prompt> <worktree> <role> [state_dir]
EOF
exit 1
