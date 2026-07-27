#!/usr/bin/env bash
# kant-loop.sh — nomad-kant-looper 메인 백엔드
#
# 서브커맨드:
#   preflight TASK.md                          환경 검사 (side-effect 없음)
#   run TASK.md [--quick|--parallel]           모드 디스패치 (기본 = --quick)
#        [--dry-run] [--no-auto-commit] [--detach]
#   status --latest | RUN_ID                   실행 상태
#   await RUN_ID [--timeout N] [--interval N]  완료 블로킹 대기
#   report RUN_ID                              사용자 보고용 markdown 생성
#   promote BRANCH --target TARGET             사용자 명시 실행 (ff-only merge)
#   cleanup [--apply]                          dry-run 기본
#   update-guide                               routing-guide.md 갱신
#
# 안전 약속 (절대 위반 안 됨):
#   - 자동 push 금지
#   - merge commit 금지 (ff-only만, 사용자 명시 호출)
#   - rebase / reset --hard / branch -D 금지
#   - main 직접 커밋 금지
#   - protected paths / forbidden patterns 즉시 차단
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 경로 상수
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
ADAPTERS_DIR="$SCRIPT_DIR/adapters"
REFERENCES_DIR="$SKILL_ROOT/references"

export KANT_SKILL_ROOT="$SKILL_ROOT"
export KANT_LIB_DIR="$LIB_DIR"
export KANT_ADAPTERS_DIR="$ADAPTERS_DIR"

# ---------------------------------------------------------------------------
# 기본 환경값
# ---------------------------------------------------------------------------

STATE_ROOT="${KANT_STATE_ROOT:-$HOME/.claude/state/nomad-kant-looper}"
AUTO_COMMIT="${KANT_AUTO_COMMIT:-1}"
BRANCH_PREFIX="${KANT_BRANCH_PREFIX:-agent/kant}"
NOTIFY="${KANT_NOTIFY:-1}"
NOTIFY_OSASCRIPT="${KANT_NOTIFY_OSASCRIPT:-1}"
PROTECTED_PATHS_DEFAULT='.git .env .env.local .env.*.local *.pem *.key *credential* *secret* *password* node_modules dist build __pycache__ .venv'
PROTECTED_PATHS="${PROTECTED_PATHS:-$PROTECTED_PATHS_DEFAULT}"
MAX_FILE_BYTES="${KANT_MAX_FILE_BYTES:-10485760}"

mkdir -p "$STATE_ROOT"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2
}

log_event() {
  local state_dir="$1" event="$2"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $event" >> "$state_dir/phase-events.log"
  kant_observe "$state_dir" || true
}

# 관찰성 계약(Phase 1): phase-events.log 를 소스로 run-state.json + events.jsonl 재생성.
# Dashboard 전용 machine-readable 뷰. 절대 Core 실행을 방해하지 않는다(실패 무시).
# KANT_OBSERVE_DISABLE 로 끌 수 있다(성능 측정/테스트용).
kant_observe() {
  local state_dir="$1"
  [ -n "${KANT_OBSERVE_DISABLE:-}" ] && return 0
  [ -d "$state_dir" ] || return 0
  python3 "$LIB_DIR/state_writer.py" "$state_dir" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# repo hash (state dir 분리용)
# ---------------------------------------------------------------------------

repo_hash() {
  local cwd
  cwd="$(pwd)"
  printf '%s' "$cwd" | shasum -a 256 | cut -c1-12
}

# ---------------------------------------------------------------------------
# notify (macOS)
# ---------------------------------------------------------------------------

notify_macos() {
  local title="$1" message="$2"
  if [ "$NOTIFY_OSASCRIPT" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"Funk\"" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# fail_run
# ---------------------------------------------------------------------------

fail_run() {
  local state_dir="$1" code="$2" message="$3"
  log "FAIL: $code - $message"

  if [ -n "$state_dir" ] && [ -d "$state_dir" ]; then
    printf '%s' "$code" > "$state_dir/failure-code.txt"
    printf '%s' "$message" > "$state_dir/failure-message.txt"
    echo "failed" > "$state_dir/result.txt"
    log_event "$state_dir" "FAIL $code: $message"
  fi

  notify_macos "nomad-kant-looper: failed" "$code - $message"
  return 1
}

# ---------------------------------------------------------------------------
# run_id 생성
# ---------------------------------------------------------------------------

gen_run_id() {
  local task_slug="${1:-task}"
  local ts
  ts="$(date -u +%Y%m%d-%H%M%S)"
  local rand
  rand="$(printf '%04x' $((RANDOM % 65536)))"
  printf '%s-%s-%s' "$task_slug" "$ts" "$rand"
}

# ---------------------------------------------------------------------------
# TASK.md 검증 + slug 추출
# ---------------------------------------------------------------------------

validate_task_md() {
  local task_md="$1"
  if [ ! -f "$task_md" ]; then
    log "ERROR: task file not found: $task_md"
    return 1
  fi
  if ! grep -qE '^##\s*목표|^##\s*Goal|^##\s*Objective' "$task_md"; then
    log "ERROR: task.md must have '## 목표' or '## Goal' section"
    return 1
  fi
  return 0
}

task_to_slug() {
  local task_md="$1"
  local title
  title="$(head -1 "$task_md" 2>/dev/null | sed -E 's/^#\s*//' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-32)"
  if [ -z "$title" ]; then
    title="task"
  fi
  echo "$title"
}

# ---------------------------------------------------------------------------
# Stage + safety check + commit
# ---------------------------------------------------------------------------

do_safety_check() {
  local worktree="$1"

  # 파이썬 런타임 캐시 정리 (git add -A 전에 수행)
  # $worktree 내부로 한정 — 경로 탈출 방지
  # *.pyc, *.pyo는 find -delete로 직접 삭제, __pycache__는 -exec rm -rf로 재귀 삭제
  find "$worktree" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
  find "$worktree" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true

  # 검사/커밋 전 반드시 스테이징한다. 이게 빠지면 두 가지가 조용히 깨진다:
  #   1) check_forbidden_patterns()가 git diff(--cached 포함)만 보므로,
  #      한 번도 add되지 않은 신규(untracked) 파일 안의 시크릿/키 패턴을 전혀 스캔하지 못한다.
  #   2) do_commit()이 "git diff --cached"로 staged_hash를 계산하고 git commit을 실행하는데,
  #      스테이징된 게 없으면 커밋할 게 없어 COMMIT_FAILED로 조용히 실패한다.
  # (실측: 신규 파일만 생성하는 작업에서 verdict=PASS인데도 커밋이 전부 실패했음)
  (cd "$worktree" && git add -A)

  "$LIB_DIR/safety-check.sh" all "$worktree"
}

# ---------------------------------------------------------------------------
# verdict의 changed_files가 실제 git diff와 일치하는지 교차검증
# ---------------------------------------------------------------------------
# 어댑터(특히 모델이 가벼운 경우)가 도구 호출을 한 번도 안 하고도
# "changed_files": [...] 를 채운 verdict=PASS를 그대로 내놓는 경우가 실측됨
# (opencode/glm-4.7, 파일 쓰기 도구 호출 로그 자체가 없었음). gate-runner는
# 테스트/빌드 설정이 없는 새 프로젝트에서는 no-op으로 통과해버리므로, 이
# 교차검증이 "실제로 무슨 일이 있었는지"를 확인하는 마지막 방어선이다.
#
# 인자: worktree, json_path (verdict JSON 파일 경로)
# 출력 (stdout): 실제로는 없는데 주장된 파일 목록. 없으면 빈 출력.
# 종료 코드: 0 = 일치, 1 = 불일치(주장한 파일이 실제 변경 목록에 없음)

verify_changed_files() {
  local worktree="$1" json_path="$2"

  if [ ! -f "$json_path" ]; then
    return 0
  fi

  local claimed
  claimed="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for f in (d.get("changed_files") or []):
        if isinstance(f, str) and f.strip() and f.strip() != "...":
            print(f.strip())
except Exception:
    pass
' "$json_path" 2>/dev/null)"

  if [ -z "$claimed" ]; then
    return 0
  fi

  local actual
  actual="$(
    cd "$worktree" && {
      git diff --name-only --cached 2>/dev/null
      git diff --name-only 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
  )"

  local missing=""
  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! printf '%s\n' "$actual" | grep -qxF "$file"; then
      missing="${missing}${file}\n"
    fi
  done <<< "$claimed"

  if [ -n "$missing" ]; then
    printf '%b' "$missing"
    return 1
  fi
  return 0
}

do_commit() {
  local worktree="$1" state_dir="$2" task_summary="$3"

  local staged_hash
  staged_hash="$(cd "$worktree" && git diff --cached --binary | shasum -a 256 | cut -d' ' -f1)"
  echo "$staged_hash" > "$state_dir/final-diff-hash.txt"

  local reviewed_tree
  reviewed_tree="$(cd "$worktree" && git write-tree)"
  echo "$reviewed_tree" > "$state_dir/reviewed-tree-sha.txt"

  local current_branch
  current_branch="$(cd "$worktree" && git rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    fail_run "$state_dir" "MAIN_COMMIT_BLOCKED" "Cannot commit directly to $current_branch"
    return 1
  fi

  cat > "$state_dir/commit-message.txt" <<EOF
chore(kant): $task_summary

Automated-Kant-Loop: $(basename "$state_dir")
Base-Branch: $current_branch
Reviewed-Diff-Hash: $staged_hash
Reviewed-Tree-SHA: $reviewed_tree
EOF

  # 빈 hooksPath + gpgSign=false commit (hooks를 안전한 위치에 만들어 우회)
  local empty_hooks
  empty_hooks="$(mktemp -d)"
  touch "$empty_hooks/.gitkeep"

  (cd "$worktree" && \
    git -c core.hooksPath="$empty_hooks" \
        -c commit.gpgSign=false \
        -c user.name="nomad-kant-looper" \
        -c user.email="nomad-kant-looper@local" \
        commit -F "$state_dir/commit-message.txt") > "$state_dir/commit.log" 2>&1

  local commit_rc=$?

  # 빈 hooks 임시 디렉터리 정리 (Python shutil로 안전하게)
  if [ -d "$empty_hooks" ]; then
    python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$empty_hooks" 2>/dev/null || true
  fi

  if [ "$commit_rc" != "0" ]; then
    fail_run "$state_dir" "COMMIT_FAILED" "git commit returned $commit_rc. See commit.log"
    return 1
  fi

  local commit_sha
  commit_sha="$(cd "$worktree" && git rev-parse HEAD)"
  local committed_tree
  committed_tree="$(cd "$worktree" && git rev-parse HEAD^{tree})"

  echo "$commit_sha" > "$state_dir/commit-sha.txt"
  echo "$committed_tree" > "$state_dir/committed-tree-sha.txt"

  if [ "$committed_tree" != "$reviewed_tree" ]; then
    fail_run "$state_dir" "TREE_MISMATCH" "committed-tree $committed_tree != reviewed-tree $reviewed_tree"
    return 1
  fi

  echo "completed" > "$state_dir/result.txt"
  log_event "$state_dir" "COMMIT $commit_sha"

  notify_macos "nomad-kant-looper: completed" "$current_branch @ $commit_sha"

  return 0
}

# ---------------------------------------------------------------------------
# Agent 기본 모델 매핑
# ---------------------------------------------------------------------------

get_default_model() {
  local tool="$1"
  case "$tool" in
    codex)    echo "gpt-5.6-sol" ;;
    opencode) echo "glm-5.2" ;;
    grok)     echo "grok-4.5" ;;
    agy)      echo "gemini-3.6-flash" ;;
    claude)   echo "default" ;;
    *)        echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent + Model 호환성 검증 (CLI 호출 전)
# ---------------------------------------------------------------------------

validate_agent_model_compatibility() {
  local tool="$1" model="$2"
  if [ -z "$tool" ] || [ -z "$model" ]; then
    return 0
  fi

  case "$tool" in
    codex)
      if ! echo "$model" | grep -qE '^gpt-'; then
        echo "ERROR: codex requires gpt-* model, got '$model'" >&2
        return 1
      fi
      ;;
    opencode)
      if ! echo "$model" | grep -qE '^glm-'; then
        case "$model" in
          MiniMax-M3|MiniMax-M2.7) ;;
          *)
            echo "ERROR: opencode requires glm-* or a supported MiniMax model, got '$model'" >&2
            return 1
            ;;
        esac
      fi
      ;;
    grok)
      if ! echo "$model" | grep -qE '^grok-'; then
        echo "ERROR: grok requires grok-* model, got '$model'" >&2
        return 1
      fi
      case "$model" in
        grok-4.3|grok-build-0.1)
          echo "ERROR: grok model '$model' was removed from nomad-kant-looper (2026-07-24) — use grok-4.5" >&2
          return 1
          ;;
      esac
      ;;
    agy)
      if ! echo "$model" | grep -qE '^gemini-'; then
        echo "ERROR: agy requires gemini-* model, got '$model'" >&2
        return 1
      fi
      ;;
    claude)
      if echo "$model" | grep -qE '^MiniMax-'; then
        echo "ERROR: claude does not support MiniMax models" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# stage sidecar 기록 (quick-chain 상태 머신용)
# ---------------------------------------------------------------------------
# run_quick_mode의 stdout 계약(verdict|json_path)은 adapter 결과 전달에 이미
# 쓰이고 있으므로, chain 내부 단계 결과 전달용으로 재활용하지 않는다. 대신
# state_dir에 stage별 사이드카 파일로 남긴다. json_path는 adapter가 role별
# 고정 경로(예: codex-review.json)에 쓰기 때문에 review가 두 번(초기/최종)
# 불리면 같은 경로가 재사용·덮어써진다 — 그래서 verdict 직후 즉시 stage_label
# 이름의 사본으로 복사해 이후 단계가 원본을 덮어써도 안전하게 만든다.
# 임시 파일 후 mv로 기록해 중간에 끊겨도 사이드카가 반쪽으로 남지 않게 한다.

write_stage_result() {
  local state_dir="$1" stage_label="$2" verdict="$3" json_src="$4"
  local json_dst=""

  if [ -n "$json_src" ] && [ -f "$json_src" ]; then
    json_dst="$state_dir/stage-${stage_label}.json"
    local tmp_json
    tmp_json="$(mktemp "$state_dir/.tmp-stage-json.XXXXXX")"
    cp "$json_src" "$tmp_json"
    mv "$tmp_json" "$json_dst"
  fi

  local tmp_verdict
  tmp_verdict="$(mktemp "$state_dir/.tmp-stage-verdict.XXXXXX")"
  printf '%s' "$verdict" > "$tmp_verdict"
  mv "$tmp_verdict" "$state_dir/stage-${stage_label}.verdict"

  local tmp_path
  tmp_path="$(mktemp "$state_dir/.tmp-stage-path.XXXXXX")"
  printf '%s' "$json_dst" > "$tmp_path"
  mv "$tmp_path" "$state_dir/stage-${stage_label}.json-path"
}

# ---------------------------------------------------------------------------
# 단일 호출 (--quick 모드)
# ---------------------------------------------------------------------------

run_quick_mode() {
  local task_md="$1" tool="${2:-}" model="${3:-}" state_dir="$4" worktree="$5"
  local role="${6:-implement}" commit_at_end="${7:-1}" defer_terminal_result="${8:-0}"
  local stage_label="${9:-$role}" context_file="${10:-}"

  # --agent만 지정되고 --model이 없을 때: agent 기본 모델 자동 선택
  if [ -n "$tool" ] && [ -z "$model" ]; then
    model="$(get_default_model "$tool")"
    log "auto model for --agent $tool: $model"
  fi

  if [ -z "$tool" ] && [ -z "$model" ]; then
    tool="codex"
    model="gpt-5.6-terra"
  elif [ -z "$tool" ]; then
    # --model만 지정된 경우
    tool="codex"
  fi

  if ! validate_agent_model_compatibility "$tool" "$model"; then
    fail_run "$state_dir" "INCOMPATIBLE_AGENT_MODEL" "tool=$tool model=$model"
    return 1
  fi

  log "quick mode: $role $tool:$model"
  log_event "$state_dir" "QUICK_CALL role=$role tool=$tool model=$model"

  local prompt_file="$state_dir/prompt-quick-$stage_label.md"
  cat > "$prompt_file" <<EOF
$(cat "$task_md")

---

## 작업 영역 경로 규칙
Current working directory is your worktree root: $worktree
Use only relative paths. Do not recreate the worktree directory.
Examples: calculator.py, DONE.md, codex/, opencode/, grok/, agy/
Forbidden: Desktop/, ~/Desktop/, Users/, C:\
Agents modify only their own workspace. Do not modify other agent folders.

---

역할:
$role 역할만 수행하세요.
$(if [ "$role" = "review" ]; then echo "현재 변경을 읽기 전용으로 검토하세요. 파일을 수정하지 마세요."; fi)
$(if [ -n "$context_file" ] && [ -f "$context_file" ]; then cat "$context_file"; fi)

---

## 보고 형식 (반드시 지킬 것)
너의 응답은 아래 JSON 객체로 응답한다. JSON 바깥에 다른 텍스트를 절대 붙이지 마라.

{
  "verdict": "PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT",
  "summary": "string",
  "findings": [],
  "changed_files": ["..."],
  "tests_added_or_updated": ["..."],
  "risks": ["..."],
  "notes_for_reviewer": "string"
}

위 JSON 객체 하나만 출력한다. JSON 앞뒤에 설명·코드펜스·태그 등 어떤 텍스트도 붙이지 마라.

## 중요: 재시도 루프 방지
- 도구를 실행(tool call)한 직후에도 반드시 위에 정의한 JSON 포맷으로 응답을 출력해야 한다.
- 도구 실행 후 응답을 출력하지 않고 끝나지 마라. 반드시 위 JSON 포맷의 응답을 작성해야 한다.
- retry loop(재시도 루프)가 발생하지 않도록, 한 번의 구현 후 즉시 위 포맷으로 응답을 출력한다.

## 중요: 비대화형(headless) 환경 — 확인 대기 금지
- 너는 비대화형(headless) 환경에서 실행 중이다. 사람이 응답할 수 없다.
- 권한/설치/승인 여부를 묻는 도구(예: ask_permission, lsp_install_decision류)를
  호출해야 하는 상황이 오면, 절대 응답을 기다리지 말고 즉시 보수적인 기본값
  (거부/declined 또는 스스로 판단해 진행)을 선택하고 작업을 계속하라.
- 사람의 확인을 기다리는 어떤 형태의 대기도 금지한다. 확인이 꼭 필요하다고
  판단되면 대기하지 말고 즉시 BLOCKED verdict로 그 이유를 보고하고 종료하라.
EOF

  local adapter="$ADAPTERS_DIR/adapter-${tool}.sh"
  if [ ! -x "$adapter" ]; then
    fail_run "$state_dir" "ADAPTER_MISSING" "adapter not found: $adapter"
    return 1
  fi

  # set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local output rc=0
  if output="$("$adapter" call "$role" "$prompt_file" "$worktree" "$model" 2>>"$state_dir/phase-events.log")"; then
    rc=0
  else
    rc=$?
  fi

  # 어댑터가 명시적 FAIL: 출력했거나, rc != 0이거나, 출력이 비었으면 fallback_dispatcher로 전환
  if [ -z "$output" ] || [ "$rc" != "0" ] || [[ "$output" == FAIL:* ]]; then
    local failure_mode="${output#FAIL:}"
    [ -z "$failure_mode" ] || [ "$failure_mode" = "$output" ] && failure_mode="INFRA_ERROR"

    log_event "$state_dir" "ADAPTER_FAIL role=$role tool=$tool model=$model mode=$failure_mode rc=$rc"

    # fallback_dispatcher로 다른 도구/모델로 전환 시도
    local fallback_result
    fallback_result=$("$LIB_DIR/fallback-dispatcher.sh" run "$tool" "$model" "$failure_mode" "$prompt_file" "$worktree" "$role" "$state_dir" 2>>"$state_dir/phase-events.log" || echo "")

    if [ -n "$fallback_result" ] && [[ "$fallback_result" != FAIL:* ]]; then
      log_event "$state_dir" "FALLBACK_USED result=$fallback_result"
      output="$fallback_result"
    else
      fail_run "$state_dir" "QUICK_CALL_FAILED" "$tool:$model mode=$failure_mode exit=$rc (fallback exhausted)"
      return 1
    fi
  fi

  local verdict="${output%%|*}"
  local json_path="${output##*|}"

  log_event "$state_dir" "QUICK_VERDICT verdict=$verdict"
  write_stage_result "$state_dir" "$stage_label" "$verdict" "$json_path"

  # 역할별 허용 verdict. review만 CHANGES_REQUESTED를 정상적인 리뷰 완료로
  # 취급한다 — 그 외 모든 역할, 그리고 review의 BLOCKED/INVALID_OUTPUT은
  # 여전히 실행 실패다. (fallback은 adapter/infra 장애 복구이고, 여기서
  # 다루는 CHANGES_REQUESTED는 코드 품질 판정이므로 서로 섞지 않는다.)
  case "$role:$verdict" in
    review:PASS|review:CHANGES_REQUESTED) ;;
    *:PASS) ;;
    *)
      fail_run "$state_dir" "QUICK_VERDICT_$verdict" "verdict=$verdict not PASS"
      return 1
      ;;
  esac

  if [ "$role" != "review" ]; then
    local missing_files
    if missing_files="$(verify_changed_files "$worktree" "$json_path")"; then
      :
    else
      log_event "$state_dir" "CHANGED_FILES_MISMATCH: $missing_files"
      fail_run "$state_dir" "CHANGED_FILES_MISMATCH" "verdict claimed changed_files not found in actual git diff: $missing_files"
      return 1
    fi

    if ! do_safety_check "$worktree" > "$state_dir/safety.log" 2>&1; then
      fail_run "$state_dir" "SAFETY_VIOLATION" "see safety.log"
      return 1
    fi

    if ! "$LIB_DIR/gate-runner.sh" run "$worktree" "$state_dir/gates-$role" "01" >> "$state_dir/phase-events.log" 2>&1; then
      fail_run "$state_dir" "GATE_FAILED" "see gates-$role/gate-01.log"
      return 1
    fi
  fi

  if [ "$AUTO_COMMIT" = "1" ] && [ "$commit_at_end" = "1" ]; then
    local task_title
    task_title="$(head -1 "$task_md" | sed 's/^#\s*//')"
    do_commit "$worktree" "$state_dir" "$task_title"
    return $?
  elif [ "$defer_terminal_result" != "1" ]; then
    echo "pass_no_commit" > "$state_dir/result.txt"
    log_event "$state_dir" "RUN_PASS_NO_COMMIT"
    notify_macos "nomad-kant-looper: pass_no_commit" "quick mode, $role $tool:$model"
  fi
  return 0
}

run_quick_chain() {
  local task_md="$1" state_dir="$2" worktree="$3" agent_chain="$4"

  # ---------------------------------------------------------------------
  # 정확히 세 개의 tool:model 파싱 (기존 CLI 형식 그대로 유지)
  # ---------------------------------------------------------------------
  local pairs=() rest="$agent_chain"
  while [ -n "$rest" ]; do
    local pair="${rest%%,*}"
    local tool="${pair%%:*}" model="${pair#*:}"
    [ "$tool" != "$model" ] || { fail_run "$state_dir" "INVALID_CHAIN" "expected tool:model, got $pair"; return 1; }
    pairs+=("$pair")
    if [ "$rest" = "$pair" ]; then rest=""; else rest="${rest#*,}"; fi
  done
  [ "${#pairs[@]}" = "3" ] || { fail_run "$state_dir" "INVALID_CHAIN" "quick chain requires implement, review, repair"; return 1; }

  local implement_pair="${pairs[0]}" review_pair="${pairs[1]}" repair_pair="${pairs[2]}"
  local implement_tool="${implement_pair%%:*}" implement_model="${implement_pair#*:}"
  local review_tool="${review_pair%%:*}" review_model="${review_pair#*:}"
  local repair_tool="${repair_pair%%:*}" repair_model="${repair_pair#*:}"

  # ---------------------------------------------------------------------
  # IMPLEMENT
  # ---------------------------------------------------------------------
  log_event "$state_dir" "CHAIN_STAGE_STARTED stage=implement"
  run_quick_mode "$task_md" "$implement_tool" "$implement_model" "$state_dir" "$worktree" implement 0 1 implement || return 1
  log_event "$state_dir" "CHAIN_STAGE_COMPLETED stage=implement verdict=PASS"

  # ---------------------------------------------------------------------
  # INITIAL REVIEW
  # ---------------------------------------------------------------------
  log_event "$state_dir" "CHAIN_STAGE_STARTED stage=review-initial"
  run_quick_mode "$task_md" "$review_tool" "$review_model" "$state_dir" "$worktree" review 0 1 review-initial || return 1

  local initial_review_verdict initial_review_json
  initial_review_verdict="$(cat "$state_dir/stage-review-initial.verdict" 2>/dev/null || echo "")"
  initial_review_json="$(cat "$state_dir/stage-review-initial.json-path" 2>/dev/null || echo "")"
  log_event "$state_dir" "CHAIN_REVIEW_DECISION verdict=$initial_review_verdict"

  case "$initial_review_verdict" in
    PASS)
      log_event "$state_dir" "CHAIN_REPAIR_SKIPPED reason=review_pass"
      ;;
    CHANGES_REQUESTED)
      if [ -z "$initial_review_json" ] || [ ! -s "$initial_review_json" ]; then
        fail_run "$state_dir" "STAGE_CONTEXT_MISSING" "initial review verdict=CHANGES_REQUESTED but no stage JSON captured"
        return 1
      fi
      log_event "$state_dir" "CHAIN_REPAIR_REQUIRED"

      # -------------------------------------------------------------
      # REPAIR — 이전 리뷰 JSON을 원본 그대로 프롬프트에 첨부
      # -------------------------------------------------------------
      local repair_context="$state_dir/context-repair.md"
      {
        printf -- '---\n## 이전 리뷰 결과\n아래 JSON은 직전 read-only reviewer의 판정이다.\n- findings의 각 항목을 확인한다.\n- 관련 없는 파일을 재작성하지 않는다.\n- 해결하지 못한 항목은 숨기지 말고 risks 또는 notes_for_reviewer에 남긴다.\n- 리뷰 결과 자체를 수정하거나 삭제하지 않는다.\n\n'
        cat "$initial_review_json"
        printf '\n'
      } > "$repair_context"

      run_quick_mode "$task_md" "$repair_tool" "$repair_model" "$state_dir" "$worktree" repair 0 1 repair "$repair_context" || return 1
      log_event "$state_dir" "CHAIN_REPAIR_COMPLETED"

      local repair_json
      repair_json="$(cat "$state_dir/stage-repair.json-path" 2>/dev/null || echo "")"

      # -------------------------------------------------------------
      # FINAL REVIEW — 같은 reviewer 재사용, 최초 리뷰 + repair 결과를 함께 전달
      # -------------------------------------------------------------
      log_event "$state_dir" "CHAIN_FINAL_REVIEW_STARTED"
      local final_review_context="$state_dir/context-review-final.md"
      {
        printf -- '---\n## 최초 리뷰 결과\n\n'
        cat "$initial_review_json"
        printf -- '\n\n## repair 수행 결과\n\n'
        if [ -n "$repair_json" ] && [ -f "$repair_json" ]; then cat "$repair_json"; fi
        printf -- '\n\n## 최종 리뷰 지시\n- 최초 findings가 실제 코드에서 해결됐는지 확인한다.\n- repair가 만든 새 회귀를 확인한다.\n- 해결되지 않은 finding이 하나라도 있으면 CHANGES_REQUESTED를 반환한다.\n- JSON만 믿지 말고 worktree의 실제 diff를 직접 읽어 확인한다.\n'
      } > "$final_review_context"

      run_quick_mode "$task_md" "$review_tool" "$review_model" "$state_dir" "$worktree" review 0 1 review-final "$final_review_context" || return 1

      local final_review_verdict
      final_review_verdict="$(cat "$state_dir/stage-review-final.verdict" 2>/dev/null || echo "")"

      if [ "$final_review_verdict" != "PASS" ]; then
        log_event "$state_dir" "CHAIN_FINAL_REVIEW_REJECTED verdict=$final_review_verdict"
        fail_run "$state_dir" "REVIEW_NOT_CLEARED" "final review verdict=$final_review_verdict after repair — commit blocked, worktree/결과 보존"
        return 1
      fi
      log_event "$state_dir" "CHAIN_FINAL_REVIEW_CLEARED"
      ;;
    *)
      # BLOCKED/INVALID_OUTPUT은 run_quick_mode의 verdict 게이트가 이미
      # fail_run으로 처리했어야 하므로 여기 도달하면 방어적으로만 처리한다.
      fail_run "$state_dir" "QUICK_VERDICT_${initial_review_verdict:-UNKNOWN}" "unexpected review verdict"
      return 1
      ;;
  esac

  if [ "$AUTO_COMMIT" = "1" ]; then
    local task_title
    task_title="$(head -1 "$task_md" | sed 's/^#\s*//')"
    do_commit "$worktree" "$state_dir" "$task_title"
  else
    echo "pass_no_commit" > "$state_dir/result.txt"
    log_event "$state_dir" "RUN_PASS_NO_COMMIT"
  fi
}

# ---------------------------------------------------------------------------
# 병렬 호출 (--parallel 모드)
# ---------------------------------------------------------------------------

run_parallel_mode() {
  local task_md="$1" state_dir="$2" worktree="$3"
  local agent_chain="${4:-}"

  if [ -z "$agent_chain" ]; then
    fail_run "$state_dir" "MISSING_CHAIN" "--parallel 모드는 agent_chain이 필요합니다"
    return 1
  fi
  log "parallel review mode: $agent_chain"
  log_event "$state_dir" "PARALLEL_REVIEW chain=$agent_chain"

  local parallel_dir="$state_dir/parallel"
  mkdir -p "$parallel_dir"

  IFS=',' read -ra pairs <<< "$agent_chain"

  local i=0 pids=()
  for pair in "${pairs[@]}"; do
    IFS=':' read -ra tm <<< "$pair"
    local tool="${tm[0]}"
    local model="${tm[1]}"
    local slice_id=$((i+1))

    local prompt_file="$parallel_dir/prompt-review-$slice_id.md"
    cat > "$prompt_file" <<EOF
$(cat "$task_md")

## 작업 영역 경로 규칙
Current working directory is your worktree root: $worktree
Use only relative paths. Do not recreate the worktree directory.
Examples: calculator.py, DONE.md, codex/, opencode/, grok/, agy/
Forbidden: Desktop/, ~/Desktop/, Users/, C:\
Agents modify only their own workspace. Do not modify other agent folders.

병렬 검토 역할: $tool / 모델: $model / 검토: $slice_id/${#pairs[@]}
현재 변경을 읽기 전용으로 검토하세요. 파일을 수정하지 마세요.

## 보고 형식 (반드시 지킬 것)
너의 응답은 아래 JSON 객체로 응답한다. JSON 바깥에 다른 텍스트를 절대 붙이지 마라.

{
  "verdict": "PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT",
  "summary": "string",
  "findings": [],
  "changed_files": ["..."],
  "tests_added_or_updated": ["..."],
  "risks": ["..."],
  "notes_for_reviewer": "string"
}

위 JSON 객체 하나만 출력한다. JSON 앞뒤에 설명·코드펜스·태그 등 어떤 텍스트도 붙이지 마라.

## 중요: 재시도 루프 방지
- 도구를 실행(tool call)한 직후에도 반드시 위에 정의한 JSON 포맷으로 응답을 출력해야 한다.
- 도구 실행 후 응답을 출력하지 않고 끝나지 마라. 반드시 위 JSON 포맷의 응답을 작성해야 한다.
- retry loop(재시도 루프)가 발생하지 않도록, 한 번의 구현 후 즉시 위 포맷으로 응답을 출력한다.

## 중요: 비대화형(headless) 환경 — 확인 대기 금지
- 너는 비대화형(headless) 환경에서 실행 중이다. 사람이 응답할 수 없다.
- 권한/설치/승인 여부를 묻는 도구(예: ask_permission, lsp_install_decision류)를
  호출해야 하는 상황이 오면, 절대 응답을 기다리지 말고 즉시 보수적인 기본값
  (거부/declined 또는 스스로 판단해 진행)을 선택하고 작업을 계속하라.
- 사람의 확인을 기다리는 어떤 형태의 대기도 금지한다. 확인이 꼭 필요하다고
  판단되면 대기하지 말고 즉시 BLOCKED verdict로 그 이유를 보고하고 종료하라.
EOF

    (
      local adapter="$ADAPTERS_DIR/adapter-${tool}.sh"
      if [ -x "$adapter" ]; then
        "$adapter" call "review" "$prompt_file" "$worktree" "$model" \
          > "$parallel_dir/result-review-$slice_id.txt" 2>&1
        echo $? > "$parallel_dir/exit-review-$slice_id.txt"
      else
        echo "ADAPTER_MISSING" > "$parallel_dir/result-review-$slice_id.txt"
        echo 1 > "$parallel_dir/exit-review-$slice_id.txt"
      fi
    ) &
    pids+=($!)
    i=$((i+1))
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local all_pass=1
  local summary=""
  i=0
  for pair in "${pairs[@]}"; do
    IFS=':' read -ra tm <<< "$pair"
    local tool="${tm[0]}"
    local model="${tm[1]}"
    local slice_id=$((i+1))
    local exit_code
    exit_code="$(cat "$parallel_dir/exit-review-$slice_id.txt" 2>/dev/null || echo "1")"
    local result
    result="$(cat "$parallel_dir/result-review-$slice_id.txt" 2>/dev/null || echo "no output")"
    summary="${summary}${tool}:${model} exit=${exit_code} verdict=${result%%|*}
"
    if [ "$exit_code" != "0" ] || [ "${result%%|*}" != "PASS" ]; then
      all_pass=0
    fi
    i=$((i+1))
  done

  if [ "$all_pass" != "1" ]; then
    fail_run "$state_dir" "PARALLEL_REVIEW_FAILED" "one or more reviewers failed:\n$summary\nUse --quick --chain for implementation."
    return 1
  fi

  local changed
  changed="$(git -C "$worktree" status --porcelain --untracked-files=all | grep -Ev '^\?\? (\.kant-looper/|\.omo/run-continuation/|\.codegraph$)' || true)"
  if [ -n "$changed" ]; then
    fail_run "$state_dir" "PARALLEL_WRITE_DETECTED" "parallel review changed the worktree; use --quick --chain for implementation"
    return 1
  fi

  echo "pass_no_commit" > "$state_dir/result.txt"
  notify_macos "nomad-kant-looper: parallel review passed" "${#pairs[@]} reviewers"
  return 0
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 서브커맨드: preflight
# ---------------------------------------------------------------------------

cmd_preflight() {
  local task_md="${1:-}"

  log "preflight starting..."
  "$LIB_DIR/health-check.sh" preflight "/tmp/kant-preflight.log"
  if [ -n "$task_md" ] && [ -f "$task_md" ]; then
    log "task.md: OK ($(wc -l < "$task_md" | tr -d ' ') lines)"
  fi
  log "preflight done"
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: run
# ---------------------------------------------------------------------------

cmd_run() {
  local task_md=""
  local mode="quick"
  local dry_run=0
  local no_commit=0
  local detach=0
  local tool=""
  local model=""
  local agent_chain=""
  local role="implement"
  local existing_worktree=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --quick) mode="quick" ;;
      --parallel) mode="parallel" ;;
      --full)
        echo "--full HPRAR 모드는 중단되었습니다. --quick 또는 --quick --chain을 사용하세요." >&2
        exit 2
        ;;
      --dry-run) dry_run=1 ;;
      --strict-verify)
        echo "--strict-verify는 중단된 --full 전용 옵션입니다." >&2
        exit 2
        ;;
      --no-auto-commit)
        no_commit=1
        # AUTO_COMMIT은 현재 프로세스용, KANT_AUTO_COMMIT은 --detach가 nohup으로
        # kant-loop.sh를 재실행할 때 스크립트 맨 위(45행)에서 다시 읽는 env var다.
        # 이것 없이는 detach된 자식이 AUTO_COMMIT을 기본값 1로 재초기화해
        # --no-auto-commit이 무시된 채 자동 커밋되는 버그가 있었다(2026-07-17 실측).
        export AUTO_COMMIT=0 KANT_AUTO_COMMIT=0
        ;;
      --detach) detach=1 ;;
      --agent) tool="$2"; shift ;;
      --model) model="$2"; shift ;;
      --chain) agent_chain="$2"; export KANT_AGENT_CHAIN="$2"; shift ;;
      --role) role="$2"; shift ;;
      --existing-worktree) existing_worktree="$2"; shift ;;
      -h|--help) cmd_run_help; exit 0 ;;
      -*) echo "unknown flag: $1" >&2; exit 1 ;;
      *)
        if [ -z "$task_md" ]; then
          task_md="$1"
        else
          echo "multiple task files specified" >&2; exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$task_md" ]; then
    echo "usage: kant-loop.sh run TASK.md [--quick|--parallel]" >&2
    exit 1
  fi

  if [ ! -f "$task_md" ]; then
    echo "task file not found: $task_md" >&2
    exit 1
  fi

  if [ "$mode" = "parallel" ] && [ -z "$agent_chain" ]; then
    echo "--parallel 모드는 --chain tool:model,tool:model,... 을 명시해야 합니다." >&2
    exit 1
  fi

  case "$role" in implement|review|repair) ;; *) echo "invalid role: $role" >&2; exit 1 ;; esac

  # --chain 포맷 검증: tool:model,tool:model,...
  if [ -n "$agent_chain" ]; then
    local chain_invalid=0
    local chain_count=0
    local chain_copy="$agent_chain"
    while [ -n "$chain_copy" ]; do
      local segment="${chain_copy%%,*}"
      if ! printf '%s' "$segment" | grep -Eq '^[^:]+:[^:]+$'; then
        echo "invalid chain segment: '$segment' (expected tool:model)" >&2
        chain_invalid=1
        break
      fi
      chain_count=$((chain_count + 1))
      if [ "$chain_copy" = "$segment" ]; then
        chain_copy=""
      else
        chain_copy="${chain_copy#*,}"
      fi
    done
    if [ "$chain_invalid" = "1" ]; then
      exit 1
    fi
    if [ "$mode" = "quick" ] && [ "$chain_count" != "3" ]; then
      echo "--quick --chain은 implement,review,repair 순서의 정확히 3개 tool:model이 필요합니다." >&2
      exit 1
    fi
    if [ "$mode" = "parallel" ] && [ "$chain_count" -gt "4" ]; then
      echo "--parallel은 최대 4개 reviewer만 지원합니다." >&2
      exit 1
    fi
    log "chain specified: $agent_chain"
  fi

  validate_task_md "$task_md"

  if [ "$dry_run" = "1" ]; then
    local effective_route
    if [ -n "$agent_chain" ]; then
      effective_route="chain:$agent_chain"
    else
      case "$mode" in
        quick)
          effective_route="${tool:-codex}:${model:-gpt-5.6-terra}"
          ;;
      esac
    fi
    local slug
    slug="$(task_to_slug "$task_md")"
    local rh
    rh="$(repo_hash)"
    local run_id
    run_id="$(gen_run_id "$slug")"
    echo "dry-run:"
    echo "  mode: $mode"
    echo "  task: $task_md"
    echo "  agent_chain: ${agent_chain:-}"
    echo "  effective_route: $effective_route"
    echo "  run_id: $run_id"
    echo "  state_dir: $STATE_ROOT/$rh/$run_id"
    echo "  branch: $BRANCH_PREFIX/$run_id"
    exit 0
  fi

  local slug
  slug="$(task_to_slug "$task_md")"
  local rh
  rh="$(repo_hash)"
  local run_id
  run_id="$(gen_run_id "$slug")"

  local state_dir="$STATE_ROOT/$rh/$run_id"
  mkdir -p "$state_dir"
  cp "$task_md" "$state_dir/task.md"
  echo "$run_id" > "$state_dir/run-id.txt"

  local branch="$BRANCH_PREFIX/$run_id"
  echo "$branch" > "$state_dir/branch.txt"

  log "run_id=$run_id"
  log "state_dir=$state_dir"
  log "mode=$mode"

  # worktree 생성
  local repo
  repo="$(pwd)"
  local worktree
  if [ -n "$existing_worktree" ]; then
    worktree="$(cd "$existing_worktree" && pwd -P)" || { fail_run "$state_dir" "WORKTREE_NOT_FOUND" "$existing_worktree"; exit 1; }
    branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD)"
    echo "$branch" > "$state_dir/branch.txt"
  else
    worktree="$(create_worktree "$repo" "$branch")"
  fi
  echo "$worktree" > "$state_dir/worktree.txt"

  # worktree 정합성 검증 — 외부 도구가 실제로 격리된 곳에서 실행됨을 실행 전에 보장.
  # 인자 전달 실수 등으로 $repo나 엉뚱한 경로가 worktree로 잘못 넘어가는 사고를 차단.
  local repo_realpath worktree_realpath
  repo_realpath="$(cd "$repo" && pwd -P)"
  worktree_realpath="$(cd "$worktree" && pwd -P)"

  if [ "$repo_realpath" = "$worktree_realpath" ]; then
    fail_run "$state_dir" "WORKTREE_IS_REPO" "worktree resolves to original checkout: $worktree_realpath"
    exit 1
  fi

  if ! git -C "$repo_realpath" worktree list --porcelain | grep -Fx "worktree $worktree_realpath" >/dev/null; then
    fail_run "$state_dir" "UNREGISTERED_WORKTREE" "cwd is not registered in git worktree list: $worktree_realpath"
    exit 1
  fi

  # 관찰성 계약 메타(Phase 1): run-state.json 조립에 필요한 값. RUN_CREATED 가 최초 스냅샷을 생성한다.
  printf '%s' "$mode" > "$state_dir/mode.txt"
  printf '%s' "$repo" > "$state_dir/repo.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$state_dir/started-at.txt"
  log_event "$state_dir" "RUN_CREATED"

  if [ "$detach" = "1" ]; then
    log "detach mode — running in background"
    nohup "$SCRIPT_DIR/kant-loop.sh" _run_mode "$mode" "$task_md" "$state_dir" "$worktree" "$tool" "$model" "$agent_chain" "$role" > "$state_dir/detached.log" 2>&1 &
    local detached_pid=$!
    echo "$detached_pid" > "$state_dir/detached.pid"
    echo "run_id: $run_id"
    echo "state_dir: $state_dir"
    echo "branch: $branch"
    echo "detached_pid: $detached_pid"
    echo "kant_hook_marker: kant-loop-detach-v1"
    echo ""
    echo "상태 확인:"
    echo "  $SCRIPT_DIR/kant-loop.sh status $run_id"
    exit 0
  fi

  case "$mode" in
    quick)
      if [ -n "$agent_chain" ]; then
        run_quick_chain "$task_md" "$state_dir" "$worktree" "$agent_chain"
      else
        run_quick_mode "$task_md" "$tool" "$model" "$state_dir" "$worktree" "$role" "$([ "$role" = review ] && echo 0 || echo 1)"
      fi
      ;;
    parallel)
      run_parallel_mode "$task_md" "$state_dir" "$worktree" "$agent_chain"
      ;;
  esac
  local rc=$?

  echo ""
  echo "=== 결과 ==="
  echo "run_id: $run_id"
  echo "result: $(cat "$state_dir/result.txt" 2>/dev/null || echo "unknown")"
  echo "branch: $branch"
  if [ -f "$state_dir/commit-sha.txt" ]; then
    echo "commit: $(cat "$state_dir/commit-sha.txt")"
  fi
  if [ -f "$state_dir/failure-code.txt" ]; then
    echo "failure: $(cat "$state_dir/failure-code.txt") - $(cat "$state_dir/failure-message.txt")"
  fi
  echo ""
  echo "보고서: $SCRIPT_DIR/kant-loop.sh report $run_id"
  exit $rc
}

cmd_run_help() {
  cat <<EOF
kant-loop.sh run TASK.md [--quick|--parallel] [options]

옵션:
  --quick                단일 호출 모드 (기본값), 또는 --chain의 순차 체인
  --parallel             읽기 전용 동시 검토 모드 (최대 4명)
  --dry-run              환경 검사만, 실제 실행 X
  --no-auto-commit       검증 PASS여도 commit 안 함 (사용자 결정 대기)
  --detach               백그라운드로 실행
  --agent <tool>         quick 모드에서 사용할 도구 (codex|grok|opencode|agy|claude)
  --model <model>        quick 모드에서 사용할 모델
  --role <role>          quick 역할 (implement|review|repair)
  --existing-worktree D  등록된 기존 worktree 재사용 (같은 worktree에서 후속 quick 호출을
                         이어갈 때 클로드가 직접 사용)
  --chain <chain>        tool:model,tool:model,...
                         (--quick은 implement,review,repair 3개 필수; --parallel은 필수)
EOF
}

create_worktree() {
  local repo="$1" branch="$2"
  local wt_dir="/tmp/kant-worktree-$$"

  # subshell의 stdout/stderr 모두 /dev/null로 보내서 함수 출력이 새 경로만 포함하도록
  if (cd "$repo" && git worktree add -B "$branch" "$wt_dir" >/dev/null 2>&1); then
    :
  elif (cd "$repo" && git worktree add "$wt_dir" >/dev/null 2>&1 && git checkout -B "$branch" >/dev/null 2>&1); then
    :
  else
    return 1
  fi

  echo "$wt_dir"
}

_run_mode() {
  local mode="$1" task_md="$2" state_dir="$3" worktree="$4" tool="$5" model="$6" agent_chain="$7" role="${8:-implement}"
  local rc=0
  case "$mode" in
    quick)
      if [ -n "$agent_chain" ]; then
        run_quick_chain "$task_md" "$state_dir" "$worktree" "$agent_chain" || rc=$?
      else
        run_quick_mode "$task_md" "$tool" "$model" "$state_dir" "$worktree" "$role" "$([ "$role" = review ] && echo 0 || echo 1)" || rc=$?
      fi
      ;;
    parallel)
      run_parallel_mode "$task_md" "$state_dir" "$worktree" "$agent_chain" || rc=$?
      ;;
    *)
      rc=2
      ;;
  esac
  if [ "$rc" != 0 ] && [ ! -f "$state_dir/result.txt" ]; then
    fail_run "$state_dir" "UNSUPPORTED_MODE" "detached worker ended without terminal result: mode=$mode" || true
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# 서브커맨드: status
# ---------------------------------------------------------------------------

cmd_status() {
  local json_output=0
  local -a status_args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--json" ]; then
      json_output=1
    else
      status_args+=("$1")
    fi
    shift
  done

  local target="${status_args[0]:-}"
  local rh
  rh="$(repo_hash)"

  if [ "$target" = "--latest" ] || [ -z "$target" ]; then
    local latest
    latest="$(ls -1t "$STATE_ROOT/$rh" 2>/dev/null | head -1 || true)"
    if [ -z "$latest" ]; then
      echo "no runs found"
      exit 1
    fi
    target="$latest"
  fi

  local state_dir="$STATE_ROOT/$rh/$target"
  if [ ! -d "$state_dir" ]; then
    echo "run not found: $target"
    exit 1
  fi

  if [ "$json_output" = "1" ]; then
    local result branch="" worktree="" commit="" failure_code="" failure_message=""
    local branch_present=0 worktree_present=0 commit_present=0 failure_message_present=0
    result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "running")"
    if [ -f "$state_dir/branch.txt" ]; then branch="$(cat "$state_dir/branch.txt")"; branch_present=1; fi
    if [ -f "$state_dir/worktree.txt" ]; then worktree="$(cat "$state_dir/worktree.txt")"; worktree_present=1; fi
    if [ -f "$state_dir/commit-sha.txt" ]; then commit="$(cat "$state_dir/commit-sha.txt")"; commit_present=1; fi
    if [ -f "$state_dir/failure-code.txt" ]; then failure_code="$(cat "$state_dir/failure-code.txt")"; fi
    if [ -f "$state_dir/failure-message.txt" ]; then failure_message="$(cat "$state_dir/failure-message.txt")"; failure_message_present=1; fi

    KANT_JSON_RUN_ID="$target" \
    KANT_JSON_RESULT="$result" \
    KANT_JSON_BRANCH="$branch" KANT_JSON_BRANCH_PRESENT="$branch_present" \
    KANT_JSON_WORKTREE="$worktree" KANT_JSON_WORKTREE_PRESENT="$worktree_present" \
    KANT_JSON_COMMIT="$commit" KANT_JSON_COMMIT_PRESENT="$commit_present" \
    KANT_JSON_FAILURE_CODE="$failure_code" \
    KANT_JSON_FAILURE_MESSAGE="$failure_message" KANT_JSON_FAILURE_MESSAGE_PRESENT="$failure_message_present" \
    python3 - "$state_dir/phase-events.log" <<'PY'
import json
import os
import sys
from pathlib import Path


def optional(name):
    return os.environ[name] if os.environ[f"{name}_PRESENT"] == "1" else None


events_path = Path(sys.argv[1])
events = events_path.read_text().splitlines()[-10:] if events_path.is_file() else []
failure = None
if Path(events_path.parent, "failure-code.txt").is_file():
    failure = {
        "code": os.environ["KANT_JSON_FAILURE_CODE"],
        "message": optional("KANT_JSON_FAILURE_MESSAGE"),
    }

json.dump(
    {
        "schema_version": 1,
        "run_id": os.environ["KANT_JSON_RUN_ID"],
        "result": os.environ["KANT_JSON_RESULT"],
        "branch": optional("KANT_JSON_BRANCH"),
        "worktree": optional("KANT_JSON_WORKTREE"),
        "commit": optional("KANT_JSON_COMMIT"),
        "commit_sha": optional("KANT_JSON_COMMIT"),
        "failure": failure,
        "recent_events": events,
    },
    sys.stdout,
    ensure_ascii=False,
    indent=2,
)
sys.stdout.write("\n")
PY
    exit 0
  fi

  echo "run_id: $target"
  echo "result: $(cat "$state_dir/result.txt" 2>/dev/null || echo "running")"
  echo "branch: $(cat "$state_dir/branch.txt" 2>/dev/null || echo "n/a")"
  echo "worktree: $(cat "$state_dir/worktree.txt" 2>/dev/null || echo "n/a")"
  if [ -f "$state_dir/commit-sha.txt" ]; then
    echo "commit: $(cat "$state_dir/commit-sha.txt")"
  fi
  if [ -f "$state_dir/failure-code.txt" ]; then
    echo "failure: $(cat "$state_dir/failure-code.txt") - $(cat "$state_dir/failure-message.txt")"
  fi

  echo ""
  echo "phase-events.log 마지막 10줄:"
  tail -10 "$state_dir/phase-events.log" 2>/dev/null || echo "  (no events)"
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: report
# ---------------------------------------------------------------------------

cmd_report() {
  local json_output=0
  local -a report_args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--json" ]; then
      json_output=1
    else
      report_args+=("$1")
    fi
    shift
  done

  local run_id="${report_args[0]:-}"
  local rh
  rh="$(repo_hash)"
  local state_dir="$STATE_ROOT/$rh/$run_id"

  if [ ! -d "$state_dir" ]; then
    echo "run not found: $run_id"
    exit 1
  fi

  if [ "$json_output" = "1" ]; then
    local result branch="" worktree="" commit_sha="" reviewed_tree="" committed_tree=""
    local failure_code="" failure_message="" promote_command
    local branch_present=0 worktree_present=0 commit_sha_present=0 reviewed_tree_present=0 committed_tree_present=0
    local failure_message_present=0
    result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "running")"
    if [ -f "$state_dir/branch.txt" ]; then branch="$(cat "$state_dir/branch.txt")"; branch_present=1; fi
    if [ -f "$state_dir/worktree.txt" ]; then worktree="$(cat "$state_dir/worktree.txt")"; worktree_present=1; fi
    if [ -f "$state_dir/commit-sha.txt" ]; then commit_sha="$(cat "$state_dir/commit-sha.txt")"; commit_sha_present=1; fi
    if [ -f "$state_dir/reviewed-tree-sha.txt" ]; then reviewed_tree="$(cat "$state_dir/reviewed-tree-sha.txt")"; reviewed_tree_present=1; fi
    if [ -f "$state_dir/committed-tree-sha.txt" ]; then committed_tree="$(cat "$state_dir/committed-tree-sha.txt")"; committed_tree_present=1; fi
    if [ -f "$state_dir/failure-code.txt" ]; then failure_code="$(cat "$state_dir/failure-code.txt")"; fi
    if [ -f "$state_dir/failure-message.txt" ]; then failure_message="$(cat "$state_dir/failure-message.txt")"; failure_message_present=1; fi
    if [ "$branch_present" = "1" ]; then
      promote_command="$SCRIPT_DIR/kant-loop.sh promote $branch --target main"
    else
      promote_command="$SCRIPT_DIR/kant-loop.sh promote <branch> --target main"
    fi

    KANT_JSON_RUN_ID="$run_id" \
    KANT_JSON_RESULT="$result" \
    KANT_JSON_BRANCH="$branch" KANT_JSON_BRANCH_PRESENT="$branch_present" \
    KANT_JSON_WORKTREE="$worktree" KANT_JSON_WORKTREE_PRESENT="$worktree_present" \
    KANT_JSON_COMMIT_SHA="$commit_sha" KANT_JSON_COMMIT_SHA_PRESENT="$commit_sha_present" \
    KANT_JSON_REVIEWED_TREE="$reviewed_tree" KANT_JSON_REVIEWED_TREE_PRESENT="$reviewed_tree_present" \
    KANT_JSON_COMMITTED_TREE="$committed_tree" KANT_JSON_COMMITTED_TREE_PRESENT="$committed_tree_present" \
    KANT_JSON_FAILURE_CODE="$failure_code" \
    KANT_JSON_FAILURE_MESSAGE="$failure_message" KANT_JSON_FAILURE_MESSAGE_PRESENT="$failure_message_present" \
    KANT_JSON_PROMOTE_COMMAND="$promote_command" \
    python3 - "$state_dir/safety.log" <<'PY'
import json
import os
import sys
from pathlib import Path


def optional(name):
    return os.environ[name] if os.environ[f"{name}_PRESENT"] == "1" else None


safety_path = Path(sys.argv[1])
safety_log = safety_path.read_text().splitlines()[:10] if safety_path.is_file() else []
failure = None
if Path(safety_path.parent, "failure-code.txt").is_file():
    failure = {
        "code": os.environ["KANT_JSON_FAILURE_CODE"],
        "message": optional("KANT_JSON_FAILURE_MESSAGE"),
    }

json.dump(
    {
        "schema_version": 1,
        "run_id": os.environ["KANT_JSON_RUN_ID"],
        "result": os.environ["KANT_JSON_RESULT"],
        "branch": optional("KANT_JSON_BRANCH"),
        "worktree": optional("KANT_JSON_WORKTREE"),
        "commit_sha": optional("KANT_JSON_COMMIT_SHA"),
        "commit": optional("KANT_JSON_COMMIT_SHA"),
        "reviewed_tree": optional("KANT_JSON_REVIEWED_TREE"),
        "committed_tree": optional("KANT_JSON_COMMITTED_TREE"),
        "failure": failure,
        "safety_log": safety_log,
        "promote_command": os.environ["KANT_JSON_PROMOTE_COMMAND"],
    },
    sys.stdout,
    ensure_ascii=False,
    indent=2,
)
sys.stdout.write("\n")
PY
    exit 0
  fi

  cat <<EOF
# nomad-kant-looper 보고서 — $run_id

- run_id: $run_id
- 결과: $(cat "$state_dir/result.txt" 2>/dev/null || echo "running")
- 브랜치: $(cat "$state_dir/branch.txt" 2>/dev/null || echo "n/a")
- worktree: $(cat "$state_dir/worktree.txt" 2>/dev/null || echo "n/a")

## commit 정보
- commit_sha: $(cat "$state_dir/commit-sha.txt" 2>/dev/null || echo "n/a")
- reviewed_tree: $(cat "$state_dir/reviewed-tree-sha.txt" 2>/dev/null || echo "n/a")
- committed_tree: $(cat "$state_dir/committed-tree-sha.txt" 2>/dev/null || echo "n/a")

## 안전 검사
$(cat "$state_dir/safety.log" 2>/dev/null | head -10 || echo "  no safety log")

## 실패 정보
$(if [ -f "$state_dir/failure-code.txt" ]; then
  echo "  code: $(cat "$state_dir/failure-code.txt")"
  echo "  message: $(cat "$state_dir/failure-message.txt")"
fi)

## main 병합 (사용자 명시 실행)
\`\`\`bash
$SCRIPT_DIR/kant-loop.sh promote $(cat "$state_dir/branch.txt" 2>/dev/null || echo "<branch>") --target main
\`\`\`
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: promote (사용자 명시 실행)
# ---------------------------------------------------------------------------

cmd_promote() {
  local branch="${1:-}"
  local target=""

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift ;;
      *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
  done

  if [ -z "$branch" ] || [ -z "$target" ]; then
    echo "usage: kant-loop.sh promote BRANCH --target TARGET" >&2
    exit 1
  fi

  local rh
  rh="$(repo_hash)"
  local state_dir
  state_dir="$(find "$STATE_ROOT/$rh" -name "branch.txt" -exec grep -l "$branch" {} \; 2>/dev/null | head -1 | xargs -I {} dirname {})"

  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    echo "ERROR: no state found for branch $branch"
    exit 1
  fi

  local result
  result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "unknown")"
  if [ "$result" != "completed" ]; then
    echo "ERROR: state result is '$result', not 'completed'. promote 불가."
    exit 1
  fi

  local commit_sha
  commit_sha="$(cat "$state_dir/commit-sha.txt")"
  local branch_head
  branch_head="$(git rev-parse "$branch" 2>/dev/null || echo "")"
  if [ "$commit_sha" != "$branch_head" ]; then
    echo "ERROR: commit-sha $commit_sha != branch HEAD $branch_head"
    exit 1
  fi

  local reviewed_tree
  reviewed_tree="$(cat "$state_dir/reviewed-tree-sha.txt")"
  local committed_tree
  committed_tree="$(cat "$state_dir/committed-tree-sha.txt")"
  if [ "$reviewed_tree" != "$committed_tree" ]; then
    echo "ERROR: reviewed-tree != committed-tree"
    exit 1
  fi

  log "promoting $branch → $target (ff-only)"
  git merge --ff-only "$branch"

  local rc=$?
  if [ "$rc" = "0" ]; then
    notify_macos "nomad-kant-looper: promoted" "$branch → $target"
    log "promote 성공"
  else
    log "promote 실패 (exit=$rc)"
  fi
  exit $rc
}

# ---------------------------------------------------------------------------
# 서브커맨드: cleanup (안전한 Python wrapper 사용)
# ---------------------------------------------------------------------------

cmd_cleanup() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      *) shift; continue ;;
    esac
    shift
  done

  local rh
  rh="$(repo_hash)"
  local keep_days=14

  log "cleanup (apply=$apply, keep=$keep_days days)"

  local dir
  for dir in "$STATE_ROOT/$rh"/*; do
    [ -d "$dir" ] || continue
    local name
    name="$(basename "$dir")"
    local mtime
    mtime="$(stat -f%m "$dir" 2>/dev/null || stat -c%Y "$dir" 2>/dev/null || echo 0)"
    local age_seconds=$(( $(date +%s) - mtime ))
    local age_days=$(( age_seconds / 86400 ))

    local result
    result="$(cat "$dir/result.txt" 2>/dev/null || echo "running")"

    if [ "$age_days" -lt "$keep_days" ]; then
      echo "KEEP (recent): $name (${age_days}d, $result)"
      continue
    fi

    case "$result" in
      completed)
        if [ "$apply" = "1" ]; then
          # Python으로 안전하게 정리
          python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$dir" 2>/dev/null || true
          echo "REMOVED: $name (completed, ${age_days}d)"
        else
          echo "WOULD REMOVE: $name (completed, ${age_days}d)"
        fi
        ;;
      failed|blocked)
        echo "MANUAL_REVIEW: $name ($result, ${age_days}d)"
        ;;
      *)
        echo "KEEP (running): $name ($result, ${age_days}d)"
        ;;
    esac
  done

  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: update-guide
# ---------------------------------------------------------------------------

cmd_update_guide() {
  local external_guide="${KANT_EXTERNAL_GUIDE_PATH:-$HOME/Downloads/multimodel-coding-agent-routing-guide.md}"
  local internal_guide="$REFERENCES_DIR/multimodel-coding-agent-routing-guide.md"

  if [ ! -f "$external_guide" ]; then
    echo "ERROR: 외부 가이드 없음: $external_guide"
    exit 1
  fi

  if [ ! -f "$internal_guide" ]; then
    echo "ERROR: 내부 가이드 없음: $internal_guide"
    exit 1
  fi

  echo "외부 vs 내부 가이드 diff:"
  if command -v diff >/dev/null 2>&1; then
    diff "$external_guide" "$internal_guide" | head -50
  fi

  echo ""
  echo "복사하시겠습니까? (외부 → 내부) [y/N]"
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    cp "$external_guide" "$internal_guide"
    echo "갱신 완료"
  else
    echo "취소됨"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# 서브커맨드: await (블로킹 완료 대기 — 하네스 자동 알림 연동)
# ---------------------------------------------------------------------------

cmd_await() {
  local target=""

  local timeout=3600
  local interval=5

  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout)
        [ $# -ge 2 ] || { echo "ERROR: --timeout requires value" >&2; exit 1; }
        timeout="$2"
        shift 2
        ;;
      --interval)
        [ $# -ge 2 ] || { echo "ERROR: --interval requires value" >&2; exit 1; }
        interval="$2"
        shift 2
        ;;
      -h|--help)
        cat <<EOF
usage: kant-loop.sh await RUN_ID [--timeout SECONDS] [--interval SECONDS]

블로킹 대기: run-id의 result.txt가 완료 값을 쓸 때까지 폴링.
완료 시 status 요약을 출력하고 종료.

옵션:
  --timeout N    최대 대기 초 (기본 3600)
  --interval N   폴링 간격 초 (기본 5)

종료 코드:
  0  성공 (result=completed|pass_no_commit|pass)
  1  실패 (result=failed 또는 run-id 미존재)
  2  타임아웃
EOF
        exit 0
        ;;
      *)
        if [ -z "$target" ]; then
          target="$1"
          shift
        else
          echo "ERROR: unknown argument: $1" >&2
          exit 1
        fi
        ;;
    esac
  done

  if [ -z "$target" ]; then
    echo "usage: kant-loop.sh await RUN_ID [--timeout SECONDS] [--interval SECONDS]" >&2
    exit 1
  fi

  case "$timeout" in
    ''|*[!0-9]*) echo "ERROR: --timeout must be a positive integer, got: $timeout" >&2; exit 1 ;;
  esac
  case "$interval" in
    ''|*[!0-9]*) echo "ERROR: --interval must be a positive integer, got: $interval" >&2; exit 1 ;;
  esac
  if [ "$timeout" -le 0 ]; then echo "ERROR: --timeout must be > 0" >&2; exit 1; fi
  if [ "$interval" -le 0 ]; then echo "ERROR: --interval must be > 0" >&2; exit 1; fi

  local rh
  rh="$(repo_hash)"
  local state_dir="$STATE_ROOT/$rh/$target"
  if [ ! -d "$state_dir" ]; then
    echo "ERROR: run not found: $target" >&2
    exit 1
  fi

  local elapsed=0
  local result=""
  while [ "$elapsed" -lt "$timeout" ]; do
    result="$(cat "$state_dir/result.txt" 2>/dev/null || echo "")"
    if [ -n "$result" ] && [ "$result" != "running" ] && [ "$result" != "unknown" ]; then
      ( cmd_status "$target" ) 2>&1
      case "$result" in
        completed|pass_no_commit|pass) exit 0 ;;
        failed|*)                      exit 1 ;;
      esac
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "TIMEOUT: run-id $target 아직 완료 안 됨 (elapsed=${elapsed}s, timeout=${timeout}s)" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# 메인 dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  preflight)
    shift
    cmd_preflight "$@"
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  await)
    shift
    cmd_await "$@"
    ;;
  report)
    shift
    cmd_report "$@"
    ;;
  promote)
    shift
    cmd_promote "$@"
    ;;
  cleanup)
    shift
    cmd_cleanup "$@"
    ;;
  update-guide)
    shift
    cmd_update_guide "$@"
    ;;
  _run_mode)
    shift
    _run_mode "$@"
    ;;
  -h|--help|help|"")
    cat <<EOF
kant-loop.sh — nomad-kant-looper 메인 백엔드

서브커맨드:
  preflight [TASK.md]                환경 검사 (사이드 이펙트 없음)
  run TASK.md [--quick|--parallel] [options]
                                     작업 실행 (기본 = --quick)
                                     --dry-run, --no-auto-commit, --detach
                                     --agent, --model, --chain, --existing-worktree
  status --latest | RUN_ID           실행 상태 조회
  await RUN_ID [--timeout N] [--interval N]
                                     완료까지 블로킹 대기 (하네스 백그라운드 알림 연동)
  report RUN_ID                      보고서 markdown 생성
  promote BRANCH --target TARGET     사용자 명시 ff-only merge
  cleanup [--apply]                  14일 지난 state 정리 (dry-run 기본)
  update-guide                       외부 가이드 → 내부 가이드 갱신

skill 위치: $SKILL_ROOT
state 위치: $STATE_ROOT
EOF
    exit 0
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    echo "도움말: $SCRIPT_DIR/kant-loop.sh --help" >&2
    exit 1
    ;;
esac
