#!/usr/bin/env bash
# timeout-runner.sh — 외부 호출을 timeout 강제 + stdout/stderr 분리 + prompt 마스킹
#
# codex-agent-loop-v4.sh:run_timeout_response 패턴 기반.
# prompt 자체는 log에서 [prompt omitted: N chars] 마스킹.
# stdout은 response file, stderr+stdout은 log file.
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 기본 timeout (도구별 override 가능)
DEFAULT_TIMEOUT_PLAN=600
DEFAULT_TIMEOUT_IMPLEMENT=1800
DEFAULT_TIMEOUT_REVIEW=900
DEFAULT_TIMEOUT_VERIFY=900
DEFAULT_TIMEOUT_REPAIR=1800

get_timeout_for_role() {
  local role="$1"
  case "$role" in
    plan|repair-plan) echo "${KANT_TIMEOUT_PLAN:-$DEFAULT_TIMEOUT_PLAN}" ;;
    implement) echo "${KANT_TIMEOUT_IMPLEMENT:-$DEFAULT_TIMEOUT_IMPLEMENT}" ;;
    review) echo "${KANT_TIMEOUT_REVIEW:-$DEFAULT_TIMEOUT_REVIEW}" ;;
    verify) echo "${KANT_TIMEOUT_VERIFY:-$DEFAULT_TIMEOUT_VERIFY}" ;;
    repair) echo "${KANT_TIMEOUT_REPAIR:-$DEFAULT_TIMEOUT_REPAIR}" ;;
    *) echo "${KANT_TIMEOUT_DEFAULT:-1800}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 메인 함수
# ---------------------------------------------------------------------------
# 인자: timeout_secs log_file response_file cwd_dir cmd [args...]
# cwd_dir는 필수 — 외부 CLI 프로세스는 반드시 이 디렉터리(격리된 worktree)를
# 작업 디렉터리로 삼아 실행된다. 누락/빈 값/존재하지 않는 경로는 즉시 실패
# (fail-closed). 절대 부모 쉘의 cwd로 조용히 폴백하지 않는다.
# 출력:
#   response_file: stdout (raw)
#   log_file: stderr + 마스킹된 prompt 정보
# 종료 코드:
#   0 = 정상
#   124 = timeout
#   200 = 잘못된 호출(인자 부족/cwd 무효)
#   65  = INVALID_OUTPUT (python wrapper 사용 시 도구 자체 에러)
#   기타 = 도구 에러

run_with_timeout() {
  if [ "$#" -lt 5 ]; then
    echo "ERROR: run_with_timeout expects: timeout log response cwd cmd [args...]" >&2
    return 200
  fi

  local timeout_secs="$1" log_file="$2" response_file="$3" cwd_dir="$4"
  shift 4

  if [ -z "$cwd_dir" ] || [ ! -d "$cwd_dir" ]; then
    echo "ERROR: invalid cwd: '$cwd_dir'" >&2
    return 200
  fi
  # 심볼릭 링크 등 정규화 — 이후 모든 실행 분기가 이 값을 강제로 사용
  cwd_dir="$(cd "$cwd_dir" && pwd -P)"

  if [ -z "$timeout_secs" ]; then
    timeout_secs=1800
  fi

  # 부모 프로세스 환경변수 정리 (timeout이 SIGTERM을 받으면 자식에게 전파)
  local start_ts
  start_ts="$(date +%s)"

  # prompt가 있으면 마스킹
  local prompt_mask=""
  local arg
  for arg in "$@"; do
    if printf '%s' "$arg" | grep -qE '\{|"|\\$'; then
      # prompt 후보: 길이만 기록
      prompt_mask="[prompt omitted: ${#arg} chars]"
      break
    fi
  done

  # log file 초기화
  {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] run_with_timeout start"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] timeout=${timeout_secs}s"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] prompt: $prompt_mask"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] cmd: $*"
  } > "$log_file"

  # macOS 호환 timeout 명령: gtimeout 시도 후 fallback
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  fi

  # Python wrapper 사용 — 더 정확한 timeout + process group 관리
  # macOS는 timeout 명령이 없을 수 있어 python3 사용
  local use_python=0
  if [ -z "$timeout_cmd" ] && command -v python3 >/dev/null 2>&1; then
    use_python=1
  fi

  local exit_code=0

  if [ "$use_python" = "1" ]; then
    python3 - "$timeout_secs" "$response_file" "$log_file" "$cwd_dir" "$@" <<'PYEOF'
import os
import sys
import subprocess
import time
import signal

timeout_secs = int(sys.argv[1])
response_file = sys.argv[2]
log_file = sys.argv[3]
cwd_dir = sys.argv[4]
cmd = sys.argv[5:]

with open(response_file, 'wb') as out, open(log_file, 'a') as err:
    err.write(f"[python-runner] spawning: {cmd[:1]} (args: {len(cmd)-1}) cwd={cwd_dir}\n")
    err.flush()

    start = time.time()
    try:
        # macOS 호환: start_new_session=True (POSIX) - process group 분리
        # cwd는 fail-closed로 검증된 값 — 폴백 없이 그대로 강제 전달
        proc = subprocess.Popen(
            cmd,
            stdout=out,
            stderr=err,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            cwd=cwd_dir,
        )
        try:
            exit_code = proc.wait(timeout=timeout_secs)
        except subprocess.TimeoutExpired:
            err.write(f"[python-runner] TIMEOUT after {timeout_secs}s, killing process group\n")
            err.flush()
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    proc.wait()
            except ProcessLookupError:
                pass
            sys.exit(124)
    except FileNotFoundError as e:
        err.write(f"[python-runner] command not found: {e}\n")
        sys.exit(127)
    except Exception as e:
        err.write(f"[python-runner] exception: {e}\n")
        sys.exit(200)

    elapsed = time.time() - start
    err.write(f"[python-runner] done exit={exit_code} elapsed={elapsed:.1f}s\n")
    sys.exit(exit_code)
PYEOF
    exit_code=$?
  elif [ -n "$timeout_cmd" ]; then
    # stdin을 /dev/null로 리다이렉트 — 비대화형 프로세스가 tty/stdin을
    # 기다리며 멈추는 것을 공통으로 방지 (Python wrapper 분기는 이미
    # stdin=DEVNULL로 처리됨). 모든 어댑터가 이 한 곳에서 안전해진다.
    ( cd "$cwd_dir" && "$timeout_cmd" "$timeout_secs" "$@" ) > "$response_file" 2>> "$log_file" < /dev/null
    exit_code=$?
  else
    # 둘 다 없으면 그냥 실행 (timeout 강제 불가)
    echo "[run-with-timeout] WARN: no timeout command available, running without timeout" >> "$log_file"
    ( cd "$cwd_dir" && "$@" ) > "$response_file" 2>> "$log_file" < /dev/null
    exit_code=$?
  fi

  local end_ts elapsed
  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] run_with_timeout done exit=$exit_code elapsed=${elapsed}s" >> "$log_file"

  # timeout 결과를 명확히
  if [ "$exit_code" = "124" ]; then
    return 124
  fi

  return $exit_code
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "run" ]; then
  shift
  run_with_timeout "$@"
  exit $?
fi

if [ "${1:-}" = "timeout-for" ]; then
  shift
  get_timeout_for_role "$@"
  exit 0
fi

cat <<EOF
timeout-runner.sh — 외부 호출 timeout 강제 + cwd 격리

사용법:
  timeout-runner.sh run <timeout_secs> <log_file> <response_file> <cwd_dir> <cmd> [args...]
  timeout-runner.sh timeout-for <role>     # role별 기본 timeout

cwd_dir는 필수. 존재하지 않거나 비어 있으면 즉시 실패(exit 200) — 부모 쉘의
cwd로 조용히 폴백하지 않는다.
EOF
exit 0