#!/usr/bin/env bash
# adapter-agy.sh — Antigravity CLI (agy) 어댑터
#
# 호출: agy --add-dir <worktree> --model <model> --dangerously-skip-permissions \
#        --print "<prompt>" < /dev/null
# 완료 감지: exit code + stdout (단순 print 모드)

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

health() {
  "$SKILL_LIB/health-check.sh" tool agy
}

version() {
  command -v agy >/dev/null 2>&1 && agy --version 2>&1 | head -1 || echo "agy not installed"
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  if ! "$SKILL_LIB/health-check.sh" tool agy >/dev/null 2>&1; then
    echo "ERROR: agy unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-agy-${role}.txt"
  local log_file="$io_dir/log-agy-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")
  local print_timeout="${timeout}s"

  # role에 따른 sandbox/실행 모드 결정
  # - plan / review / verify: read-only (안전)
  # - implement / repair: workspace-write (파일 변경 필요)
  #
  # 주의(2026-07-12 수정): agy --help 기준 --sandbox는 "터미널 제한"만 걸고
  # 파일 쓰기 도구는 막지 않는다. 파일 쓰기를 막는 건 --mode plan 뿐이다.
  # --dangerously-skip-permissions는 모든 도구 권한 요청(편집 포함)을 자동
  # 승인해버리므로, read-only 롤에서는 절대 함께 쓰면 안 된다.
  # (실측: --sandbox read-only + --dangerously-skip-permissions 조합으로
  #  hello-world 테스트 중 agy가 스킬 스크립트 5개를 실제로 수정한 사고 발생)
  local sandbox_mode agy_mode skip_permissions
  case "$role" in
    plan|review|verify)
      sandbox_mode="read-only"
      agy_mode="plan"
      skip_permissions=0
      ;;
    implement|repair)
      sandbox_mode="workspace-write"
      agy_mode="accept-edits"
      skip_permissions=1
      ;;
    *)
      sandbox_mode="read-only"
      agy_mode="plan"
      skip_permissions=0
      ;;
  esac

  local allow_browser="${KANT_AGY_ALLOW_BROWSER:-0}"
  local allow_terminal="${KANT_AGY_ALLOW_TERMINAL:-0}"

  local normalized_model="$model"
  case "$model" in
    gemini-3.6-flash)
      normalized_model="Gemini 3.6 Flash (Medium)"
      ;;
    gemini-3.6-flash-low)
      normalized_model="Gemini 3.6 Flash (Low)"
      ;;
    gemini-3.6-flash-high)
      normalized_model="Gemini 3.6 Flash (High)"
      ;;
    gemini-3.5-flash)
      normalized_model="Gemini 3.5 Flash (Medium)"
      ;;
    gemini-3.5-flash-low|gemini-3.5-flash-lite)
      normalized_model="Gemini 3.5 Flash (Low)"
      ;;
    gemini-3.5-flash-high|gemini-3.5-flash-premium)
      normalized_model="Gemini 3.5 Flash (High)"
      ;;
    gemini-3.1-flash-lite)
      normalized_model="Gemini 3.5 Flash (Low)"
      ;;
    gemini-3.1-pro|gemini-3.1-pro-preview)
      normalized_model="Gemini 3.1 Pro (High)"
      ;;
    gemini-3.1-pro-low)
      normalized_model="Gemini 3.1 Pro (Low)"
      ;;
    *)
      echo "[adapter-agy] WARN: short model name '$model' not in normalization table — passing as-is (agy may reject it)" >&2
      ;;
  esac

  # agy는 --print(=-p) 모드 + --add-dir + --model + sandbox 옵션
  # 주의(2026-07-17 실측, 2겹 함정):
  #  (1) agy는 --print/-p/--prompt를 "값을 받는 플래그"로 처리한다. 프롬프트를
  #      맨 뒤 positional 인자로 넘기면 agy가 인식하지 못하고 빈 프롬프트로
  #      실행되어 엉뚱한 응답(인사/이전 컨텍스트)을 반환한다.
  #  (2) agy는 인자 순서에 의존한다. `--sandbox`가 `-p`보다 앞에 오면 print
  #      모드로 진입하지 못하고 /dev/tty를 열려다 실패한다
  #      ("bubbletea: could not open TTY"). 따라서 `-p "<프롬프트>"`를 반드시
  #      `--sandbox`보다 앞(여기서는 맨 앞)에 둔다.
  local prompt_text
  prompt_text="$(cat "$prompt_file")"
  local cmd=(
    agy
    -p "$prompt_text"
    --print-timeout "$print_timeout"
    --add-dir "$worktree"
    --model "$normalized_model"
    --sandbox "$sandbox_mode"
    --mode "$agy_mode"
  )

  if [ "$skip_permissions" = "1" ]; then
    cmd+=( --dangerously-skip-permissions )
  fi

  # 추가 옵션: 터미널/브라우저 권한 (보안 기본값은 차단)
  if [ "$allow_browser" = "0" ] && agy --help 2>&1 | grep -q -- '--no-browser'; then
    cmd+=( --no-browser )
  fi

  # stdin을 /dev/null로 (대화형 방지)
  # set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}" < /dev/null)"; then
    rc=0
  else
    rc=$?
  fi

  # 응답 처리 — agy는 단순 stdout이라 verdict-tag 또는 JSON 추출
  local json_text
  json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"

  # JSON 추출 실패 시: <verdict> 태그 폴백까지 처리하는 process 서브커맨드로
  # 한 번 더 시도한다(기존 코드는 동일한 extract를 중복 호출하는 죽은 폴백이었음).
  # process가 verdict|json_path를 만들면 그대로 반환하고, 그래도 못 뽑으면 FAIL
  # 분류를 반환해 fallback_dispatcher가 다른 도구로 전환하게 한다.
  if [ -z "$json_text" ]; then
    local processed
    processed="$("$SKILL_LIB/verdict-extractor.sh" process "$response_file" "$role" 2>/dev/null || true)"
    if [ -n "$processed" ] && [[ "$processed" != INVALID_OUTPUT* ]]; then
      echo "$processed"
      return 0
    fi
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "agy" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  # validate는 set -Eeuo pipefail 아래에서 실패 시 어댑터를 죽일 수 있으므로
  # 가드로 감싼다. 빈 값 또는 INVALID_OUTPUT이면 structured FAIL을 반환한다.
  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text" 2>/dev/null || true)
  if [ -z "$verdict" ] || [ "$verdict" = "INVALID_OUTPUT" ]; then
    echo "FAIL:VALIDATE_FAILED"
    return 1
  fi

  local json_path="$io_dir/agy-${role}.json"
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
    echo "adapter-agy.sh — Antigravity CLI (agy) 어댑터"
    echo ""
    echo "사용법:"
    echo "  adapter-agy.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-agy.sh health"
    echo "  adapter-agy.sh version"
    exit 1
    ;;
esac
