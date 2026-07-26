#!/usr/bin/env bash
# adapter-codex.sh — OpenAI Codex CLI 어댑터
#
# 호출: codex exec --json -o <response> -s read-only -m <model> "<prompt>"
# 완료 감지: exit code + -o FILE last message + --json JSONL 마지막 이벤트

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

# 응답/로그 디렉터리 (worktree 안 또는 state dir)
get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

# ---------------------------------------------------------------------------
# health
# ---------------------------------------------------------------------------

health() {
  "$SKILL_LIB/health-check.sh" tool codex
}

version() {
  command -v codex >/dev/null 2>&1 && codex --version 2>&1 | head -1 || echo "codex not installed"
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------
# 인자: role, prompt_file, worktree, model
# 출력 (stdout): verdict | json_path
# 종료 코드: 0 = 정상, 그 외 = 실패

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  # health check
  if ! "$SKILL_LIB/health-check.sh" tool codex >/dev/null 2>&1; then
    echo "ERROR: codex unavailable" >&2
    return 201   # AUTH_FAILED 또는 사용 불가
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-codex-${role}.txt"
  local log_file="$io_dir/log-codex-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  # role에 따른 sandbox 모드 결정
  # - plan / review / verify: read-only (검증은 read-only여야 안전)
  # - implement / repair: workspace-write (구현은 파일 변경 필요)
  local sandbox_mode
  case "$role" in
    plan|review|verify)
      sandbox_mode="read-only"
      ;;
    implement|repair)
      sandbox_mode="workspace-write"
      ;;
    *)
      sandbox_mode="read-only"   # 안전 기본값
      ;;
  esac

  # prompt 읽기 (작은 경우 stdin으로 전달 가능하지만 안전을 위해 임시 파일에 저장)
  local prompt
  prompt="$(cat "$prompt_file")"

  # 명령 구성 — role별 sandbox + json + json-schema (있다면)
  # -a never: approval policy를 명시적으로 never로 고정. 사용자의
  #   ~/.codex/config.toml approval_policy=never에 암묵적으로 의존하지 않고
  #   환경에 상관없이 승인 프롬프트를 억제한다 (core 승인만 해당 — 플러그인
  #   게이트는 프롬프트 지시문으로 별도 처리).
  local cmd=(
    codex exec
    --json
    -a never
    -o "$response_file"
    -s "$sandbox_mode"
    -C "$worktree"
    -m "$model"
  )

  # --disable plugins: OMO 등 사용자 개인 플러그인(및 그 훅 시스템)을 이번
  # 호출에서만 끈다. lsp-daemon 같은 플러그인 훅이 "ASK THE USER" 안내문을
  # 띄우는 경로 자체를 차단 — 사용자의 ~/.codex/config.toml plugins 설정은
  # 건드리지 않는다 (검증: --disable plugin_hooks만으로는 훅이 계속 발화하고,
  # --disable plugins라야 훅 호출이 0건이 됨). 다른 환경에 플러그인이 없어도
  # 무해한 no-op이라 범용적으로 안전하다.
  if [ "${KANT_CODEX_DISABLE_PLUGINS:-1}" = "1" ]; then
    cmd+=( --disable plugins )
  fi

  # json-schema가 role별로 가능하면 추가 (옵션)
  local schema_file="$ADAPTER_DIR/../schemas/${role}-schema.json"
  if [ -f "$schema_file" ]; then
    cmd+=( --output-schema "$schema_file" )
  fi

  # reasoning effort (gpt-5.6 모델군에서 유효)
  if printf '%s' "$model" | grep -qE 'gpt-5\.'; then
    local effort="${KANT_CODEX_REASONING_EFFORT:-medium}"
    cmd+=( -c "model_reasoning_effort=$effort" )
  fi

  # prompt 추가
  cmd+=( "$prompt" )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}")"; then
    rc=0
  else
    rc=$?
  fi

  # 응답 처리
  local json_text
  json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  if [ -z "$json_text" ]; then
    # 응답 추출 실패 → 명시적 실패 표시 (stdout + non-zero exit)
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "codex" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/codex-${role}.json"
  printf '%s' "$json_text" > "$json_path"

  echo "$verdict|$json_path"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

case "${1:-}" in
  call)
    shift
    call "$@"
    exit $?
    ;;
  health)
    health
    exit $?
    ;;
  version)
    version
    exit 0
    ;;
  *)
    echo "adapter-codex.sh — OpenAI Codex CLI 어댑터"
    echo ""
    echo "사용법:"
    echo "  adapter-codex.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-codex.sh health"
    echo "  adapter-codex.sh version"
    exit 1
    ;;
esac