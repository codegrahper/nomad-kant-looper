#!/usr/bin/env bash
# model-selector.sh — 모델 선택 인터페이스
#
# 사용법:
#   model-selector.sh list-agents          # 사용 가능한 agent 목록
#   model-selector.sh list-models <agent>  # agent가 지원하는 모델 목록
#   model-selector.sh validate <tool> <model>  # 모델 유효성 검증
#   model-selector.sh select <agent> <model>   # 선택 확정

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# 사용 가능한 agent 목록
# ---------------------------------------------------------------------------

list_agents() {
  cat <<EOF
codex
opencode
grok
agy
claude
EOF
}

# ---------------------------------------------------------------------------
# agent별 지원 모델 목록
# ---------------------------------------------------------------------------
# 주의: 이 목록은 routing-guide.md와 실제 어댑터调研 결과 기반.
# 실제 모델 가용성은 health-check로 별도 검증 필요.

list_models() {
  local agent="$1"
  case "$agent" in
    codex)
      cat <<EOF
gpt-5.6-sol
gpt-5.6-terra
gpt-5.6-luna
EOF
      ;;
    opencode)
      cat <<EOF
glm-5.2
glm-4.7
MiniMax-M3
MiniMax-M2.7
Kimi-K3
EOF
      ;;
    grok)
      cat <<EOF
grok-4.5
EOF
      ;;
    agy)
      cat <<EOF
gemini-3.6-flash
gemini-3.5-flash
gemini-3.1-pro-preview
EOF
      ;;
    claude)
      cat <<EOF
default
EOF
      ;;
    *)
      echo "ERROR: unknown agent: $agent" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 모델 유효성 검증
# ---------------------------------------------------------------------------

validate() {
  local tool="$1" model="$2"

  if [ -z "$tool" ] || [ -z "$model" ]; then
    echo "ERROR: tool and model required" >&2
    return 1
  fi

  local supported_models
  supported_models="$(list_models "$tool")"

  if ! echo "$supported_models" | grep -qx "$model"; then
    echo "ERROR: model '$model' not supported for agent '$tool'" >&2
    echo "支持的模型:" >&2
    echo "$supported_models" >&2
    return 1
  fi

  echo "OK"
}

# ---------------------------------------------------------------------------
# 선택 확정
# ---------------------------------------------------------------------------

confirm() {
  local tool="$1" model="$2"

  # 유효성 검증
  if ! validate "$tool" "$model" >/dev/null 2>&1; then
    return 1
  fi

  echo "${tool}:${model}"
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
model-selector.sh — 모델 선택 인터페이스

사용법:
  model-selector.sh list-agents           # 사용 가능한 agent 목록
  model-selector.sh list-models <agent>   # agent가 지원하는 모델 목록
  model-selector.sh validate <tool> <model>  # 모델 유효성 검증
  model-selector.sh select <tool> <model>    # 선택 확정

예시:
  # agent 목록
  model-selector.sh list-agents

  # opencode가 지원하는 모델
  model-selector.sh list-models opencode

  # 모델 검증
  model-selector.sh validate opencode glm-5.2

  # 선택 확정
  model-selector.sh select codex gpt-5.6-sol
EOF
}

case "${1:-}" in
  list-agents)
    list_agents
    ;;
  list-models)
    shift
    list_models "$@"
    ;;
  validate)
    shift
    validate "$@"
    ;;
  select)
    shift
    confirm "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
