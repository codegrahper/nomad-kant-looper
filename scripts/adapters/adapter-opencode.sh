#!/usr/bin/env bash
# adapter-opencode.sh — OpenCode CLI 어댑터 (GLM 모델 백엔드)
#
# 호출: opencode run -m <model> --format json --auto --print-logs \
#        --log-level INFO --dir <worktree> --variant <variant> "<prompt>"
# 완료 감지: exit code + --format json 이벤트 스트림

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

# PATH에 ~/.opencode/bin 추가 (없는 경우)
if [ -d "${HOME}/.opencode/bin" ] && [[ ":${PATH}:" != *":${HOME}/.opencode/bin:"* ]]; then
  export PATH="${HOME}/.opencode/bin:${PATH}"
fi

get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

health() {
  "$SKILL_LIB/health-check.sh" tool opencode
}

version() {
  if command -v opencode >/dev/null 2>&1; then
    opencode --version 2>&1 | head -1
  elif [ -x "${HOME}/.opencode/bin/opencode" ]; then
    "${HOME}/.opencode/bin/opencode" --version 2>&1 | head -1
  else
    echo "opencode not installed"
  fi
}

# ---------------------------------------------------------------------------
# MiniMax model detection (bash 3.2 compatible)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  if ! "$SKILL_LIB/health-check.sh" tool opencode >/dev/null 2>&1; then
    echo "ERROR: opencode unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-opencode-${role}.json"
  local log_file="$io_dir/log-opencode-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  # opencode는 "provider/model" 형태를 요구한다 (예: zai-coding-plan/glm-5.2).
  # bare 이름("glm-5.2", "glm-4.7" 등)이 들어오면 ProviderModelNotFoundError 발생.
  # 이미 "/"를含む 이름은 정규화 없이 그대로 사용.
  local variant="${KANT_OPENCODE_VARIANT:-high}"

  local glm_provider="${KANT_OPENCODE_GLM_PROVIDER:-zai-coding-plan}"
  local minimax_provider="${KANT_OPENCODE_MINIMAX_PROVIDER:-opencode-go}"
  local kimi_provider="${KANT_OPENCODE_KIMI_PROVIDER:-opencode-go}"
  local normalized_model="$model"
  if ! printf '%s' "$model" | grep -q '/'; then
    case "$model" in
      glm-5.*|glm-4.*)
        normalized_model="${glm_provider}/${model}"
        ;;
      MiniMax-M3)
        normalized_model="${minimax_provider}/minimax-m3"
        ;;
      MiniMax-M2.7)
        normalized_model="${minimax_provider}/minimax-m2.7"
        ;;
      Kimi-K3)
        normalized_model="${kimi_provider}/kimi-k3"
        ;;
      *)
        # 알 수 없는 bare 이름은 로그만 남기고 그대로 시도 (다른 프로바이더일 수 있음)
        echo "[adapter-opencode] WARN: bare model name '$model' — passing as-is (opencode may fail with ProviderModelNotFoundError)" >&2
        ;;
    esac
  fi

  # role에 따른 권한 모드 결정
  # - plan / review / verify: --auto 없이 (read-only 동작)
  # - implement / repair: --auto (파일 변경 필요, but 경고 출력)
  local use_auto=""
  case "$role" in
    implement|repair)
      use_auto="--auto"
      echo "[adapter-opencode] WARNING: --auto enabled for role=$role (파일 변경 허용). 작업은 $worktree 안으로 제한됨." >&2
      ;;
  esac

  local cmd=(
    opencode run
    -m "$normalized_model"
    --format json
    --print-logs
    --log-level INFO
    --dir "$worktree"
    --variant "$variant"
  )

  # implement/repair 단계에서만 --auto 추가
  if [ -n "$use_auto" ]; then
    cmd+=( "$use_auto" )
  fi

  # prompt 마지막에 추가 (파라미터 끝에)
  cmd+=( "$(cat "$prompt_file")" )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}")"; then
    rc=0
  else
    rc=$?
  fi

  local json_text
  json_text="$(python3 - "$response_file" <<'PYEOF' 2>/dev/null || true
import json, re, sys

path = sys.argv[1]
text_parts = []
for line in open(path, errors='ignore'):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        if isinstance(e, dict) and e.get('type') == 'text':
            t = e.get('part', {}).get('text')
            if t:
                text_parts.append(t)
    except Exception:
        continue

# Concatenate all text parts (some models emit incremental events)
full_text = ''.join(text_parts)
if not full_text:
    sys.exit(1)

def try_brace_parse(text):
    depth, in_str, escape, start = 0, False, False, -1
    for i, ch in enumerate(text):
        if escape:
            escape = False
            continue
        if in_str:
            if ch == '\\\\':
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth < 0:
                start = -1
                depth = 0
                continue
            if depth == 0 and start >= 0:
                candidate = text[start:i+1]
                try:
                    d = json.loads(candidate)
                    if 'verdict' in d:
                        return candidate
                except json.JSONDecodeError:
                    pass
                start = -1
    return None

# Try ```json ... ``` block (greedy — captures full nested JSON)
m = re.search(r'```json\s*(\{.*\})\s*```', full_text, re.DOTALL)
if m:
    try:
        d = json.loads(m.group(1))
        if 'verdict' in d:
            print(m.group(1), end='')
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Extract text before <verdict> tag, then find valid verdict JSON
verdict_text = full_text
vidx = full_text.rfind('<verdict>')
if vidx >= 0:
    verdict_text = full_text[:vidx]

parsed = try_brace_parse(verdict_text)
if parsed:
    print(parsed, end='')
    sys.exit(0)

# Fallback: extract <verdict> tag (whitespace-tolerant)
m2 = re.search(r'<verdict>\s*(\w+)\s*</verdict>', full_text)
if m2:
    print(json.dumps({
        "verdict": m2.group(1),
        "summary": "",
        "findings": [],
        "changed_files": [],
        "tests_added_or_updated": [],
        "risks": [],
        "notes_for_reviewer": ""
    }), end='')
    sys.exit(0)

sys.exit(1)
PYEOF
)"

  # 폴백: 기존 verdict-extractor
  if [ -z "$json_text" ]; then
    json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"
  fi

  if [ -z "$json_text" ]; then
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "opencode" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  # changed_files를 모델의 자기 보고가 아니라 git diff 실측값으로 교체한다.
  # 모델이 파일을 생성했다고 주장해도 실제로 생성되지 않을 수 있고 (zai-coding-plan/glm-5.2 run 1),
  # <verdict> 태그 폴백 경로는 changed_files를 빈 배열로 hardcode한다.
  # git diff로 실제 변경 목록을 구해 verdict JSON을 패치한다.
  local actual_changed
  actual_changed="$(cd "$worktree" && {
    git diff --name-only --cached 2>/dev/null
    git diff --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | python3 -c "
import json, sys
files = [f.strip() for f in sys.stdin if f.strip() and not f.startswith('.kant-looper') and not f.startswith('.omo')]
print(json.dumps(files))
" 2>/dev/null || echo '[]')"

  local patch_script
  patch_script="$(mktemp).py"
  printf '%s' '
import json, sys
jpath, apath = sys.argv[1], sys.argv[2]
with open(jpath) as f:
    d = json.load(f)
with open(apath) as f:
    d["changed_files"] = json.load(f)
print(json.dumps(d, ensure_ascii=False))
' > "$patch_script"
  local json_tmp ac_tmp
  json_tmp="$(mktemp)"
  ac_tmp="$(mktemp)"
  printf '%s' "$json_text" > "$json_tmp"
  printf '%s' "$actual_changed" > "$ac_tmp"
  json_text="$(python3 "$patch_script" "$json_tmp" "$ac_tmp" 2>/dev/null || printf '%s' "$json_text")"
  rm -f "$json_tmp" "$ac_tmp" "$patch_script"

  local json_path="$io_dir/opencode-${role}.json"
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
    echo "adapter-opencode.sh — OpenCode CLI 어댑터 (GLM 백엔드)"
    echo ""
    echo "사용법:"
    echo "  adapter-opencode.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-opencode.sh health"
    echo "  adapter-opencode.sh version"
    exit 1
    ;;
esac
