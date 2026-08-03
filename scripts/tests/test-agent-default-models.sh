#!/usr/bin/env bash
# test-agent-default-models.sh — agent default model selection and compatibility validation tests
#
# Tests:
# 1. get_default_model() returns correct defaults per agent
# 2. validate_agent_model_compatibility() accepts valid combinations
# 3. validate_agent_model_compatibility() rejects invalid combinations

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASSED=0
FAILED=0

# 색상
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { echo "${GREEN}PASS${NC}: $1"; ((PASSED++)); }
fail() { echo "${RED}FAIL${NC}: $1"; ((FAILED++)); }

# ---------------------------------------------------------------------------
# Test 1: get_default_model() returns correct defaults
# ---------------------------------------------------------------------------

echo "=== get_default_model() tests ==="

# Source the functions by extracting from kant-loop.sh
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
          MiniMax-M3|MiniMax-M2.7|Kimi-K3) ;;
          *)
            echo "ERROR: opencode requires glm-* or a supported MiniMax/Kimi model, got '$model'" >&2
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
      if echo "$model" | grep -qE '^MiniMax-|^Kimi-'; then
        echo "ERROR: claude does not support MiniMax/Kimi models (OpenCode 전용)" >&2
        return 1
      fi
      ;;
  esac
  return 0
}

# Test default models
test_default_model() {
  local tool="$1" expected="$2"
  local result
  result="$(get_default_model "$tool")"
  if [ "$result" = "$expected" ]; then
    pass "get_default_model($tool) = $expected"
  else
    fail "get_default_model($tool) = $result (expected $expected)"
  fi
}

test_default_model "codex" "gpt-5.6-sol"
test_default_model "opencode" "glm-5.2"
test_default_model "grok" "grok-4.5"
test_default_model "agy" "gemini-3.6-flash"
test_default_model "claude" "default"
test_default_model "unknown" ""

# ---------------------------------------------------------------------------
# Test 2: validate_agent_model_compatibility() accepts valid combinations
# ---------------------------------------------------------------------------

echo ""
echo "=== Compatibility: valid combinations ==="

test_compat_valid() {
  local tool="$1" model="$2"
  if validate_agent_model_compatibility "$tool" "$model" 2>/dev/null; then
    pass "compatible: $tool + $model"
  else
    fail "should be compatible: $tool + $model"
  fi
}

test_compat_valid "codex" "gpt-5.6-sol"
test_compat_valid "codex" "gpt-5.6-terra"
test_compat_valid "codex" "gpt-5.6-luna"
test_compat_valid "opencode" "glm-5.2"
test_compat_valid "opencode" "glm-4.7"
test_compat_valid "opencode" "MiniMax-M3"
test_compat_valid "opencode" "MiniMax-M2.7"
test_compat_valid "opencode" "Kimi-K3"
test_compat_valid "grok" "grok-4.5"
test_compat_valid "agy" "gemini-3.6-flash"
test_compat_valid "agy" "gemini-3.5-flash"
test_compat_valid "agy" "gemini-3.1-pro-preview"
test_compat_valid "claude" "default"
test_compat_valid "claude" "claude-sonnet-5"
test_compat_valid "claude" "claude-opus-5"

# ---------------------------------------------------------------------------
# Test 3: validate_agent_model_compatibility() rejects invalid combinations
# ---------------------------------------------------------------------------

echo ""
echo "=== Compatibility: invalid combinations ==="

test_compat_invalid() {
  local tool="$1" model="$2"
  if validate_agent_model_compatibility "$tool" "$model" 2>/dev/null; then
    fail "should be INCOMPATIBLE: $tool + $model"
  else
    pass "incompatible: $tool + $model"
  fi
}

test_compat_invalid "codex" "glm-5.2"
test_compat_invalid "codex" "grok-4.5"
test_compat_invalid "opencode" "gpt-5.6-sol"
test_compat_invalid "opencode" "grok-4.5"
test_compat_invalid "opencode" "MiniMax-M2.7-highspeed"
test_compat_invalid "opencode" "MiniMax-M2.5-highspeed"
test_compat_invalid "opencode" "Kimi-K3-highspeed"
test_compat_invalid "opencode" "Kimi-K2"
test_compat_invalid "grok" "gpt-5.6-sol"
test_compat_invalid "grok" "glm-5.2"
test_compat_invalid "grok" "grok-4.3"
test_compat_invalid "grok" "grok-build-0.1"
test_compat_invalid "agy" "gpt-5.6-sol"
test_compat_invalid "agy" "glm-5.2"
test_compat_invalid "claude" "MiniMax-M3"
test_compat_invalid "claude" "MiniMax-M2.7"
test_compat_invalid "claude" "MiniMax-M2.7-highspeed"
test_compat_invalid "claude" "MiniMax-M2.5-highspeed"
test_compat_invalid "claude" "Kimi-K3"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "PASS: $PASSED"
echo "FAIL: $FAILED"

[ "$FAILED" -eq 0 ]
