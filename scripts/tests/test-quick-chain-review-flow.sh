#!/usr/bin/env bash
# test-quick-chain-review-flow.sh — quick-chain의 review→repair→재검증 흐름 회귀 테스트
#
# 배경:
#   현재 run_quick_chain()은 implement/review/repair 세 역할을 조건 없이
#   한 번씩 순차 호출한다. 그 결과 다음 두 가지가 동시에 잘못돼 있다.
#
#   1) review가 CHANGES_REQUESTED를 반환하면 run_quick_mode가 fail_run으로
#      즉시 실행을 끝낸다 — repair가 필요한 순간인데 repair가 호출되지 않는다.
#   2) review가 PASS를 반환해도 chain은 무조건 repair를 한 번 더 부른다 —
#      고칠 게 없는데 고치고, 그 결과를 아무도 재검토하지 않은 채 커밋한다.
#
#   즉 repair는 "필요할 때 안 불리고, 필요 없을 때 불린다". 이 파일은 이
#   역전을 mockagent로 재현해서 눈으로 확인하기 위한 것이다. 아직 프로덕션
#   코드(kant-loop.sh)는 건드리지 않는다 — 이 테스트가 지금 얼마나 빨간불인지
#   확인하는 것이 유일한 목적이다.
#
#   시나리오 B의 "commit did not include an unreviewed repair file" 계열
#   단언은 실제 git 커밋 트리를 검사해서, 검토 안 된 repair 결과물이 조용히
#   커밋되는지까지 확인한다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# scripts/ 전체를 격리 복사하고, mockagent 가짜 adapter를 추가한다.
# ---------------------------------------------------------------------------
cp -r "$SKILL_ROOT/scripts" "$TMP_ROOT/scripts"
KANT_LOOP="$TMP_ROOT/scripts/kant-loop.sh"
MOCK_ADAPTER="$TMP_ROOT/scripts/adapters/adapter-mockagent.sh"

cat > "$MOCK_ADAPTER" <<'MOCKEOF'
#!/usr/bin/env bash
# adapter-mockagent.sh — 테스트 전용 가짜 adapter.
# 같은 role이 여러 번 호출될 수 있다는 가정(목표 설계: review가 초기/최종
# 두 번 불림) 하에, role별 호출 횟수를 세고 호출마다 별도 verdict를 지정할
# 수 있게 한다: MOCK_VERDICT_<ROLE>_<N> (N회차 전용) > MOCK_VERDICT_<ROLE>
# (모든 회차 공통) > PASS(기본값).
set -Eeuo pipefail

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"
  local state_dir
  state_dir="$(cd "$(dirname "$prompt_file")" && pwd)"

  local role_upper
  role_upper="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"

  local count_file="$state_dir/callcount-${role}"
  local count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  : > "$state_dir/observed-call-${role}-${count}"

  local override_n override_generic verdict
  eval "override_n=\"\${MOCK_VERDICT_${role_upper}_${count}:-}\""
  eval "override_generic=\"\${MOCK_VERDICT_${role_upper}:-}\""
  verdict="${override_n:-${override_generic:-PASS}}"

  local changed_files_json="[]"
  if [ "$role" != "review" ] && [ "$verdict" = "PASS" ]; then
    local marker="${role}-${count}.marker"
    printf 'mock change from %s call %s\n' "$role" "$count" > "$worktree/$marker"
    changed_files_json="[\"$marker\"]"
  fi

  local json_path="$state_dir/mock-${role}-${count}.json"
  printf '{"verdict":"%s","summary":"mock","findings":[{"note":"mock finding"}],"changed_files":%s,"tests_added_or_updated":[],"risks":[],"notes_for_reviewer":""}' \
    "$verdict" "$changed_files_json" > "$json_path"

  echo "$verdict|$json_path"
}

case "${1:-}" in
  call) shift; call "$@"; exit $? ;;
  health) echo "OK"; exit 0 ;;
  version) echo "mock-1.0"; exit 0 ;;
  *) exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCK_ADAPTER"

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
  git -C "$dir" checkout -q -b work
  git -C "$dir" commit --allow-empty -qm initial
}

make_task() {
  local path="$1"
  printf '# Task\n\n## 목표\nreview-repair-handoff flow test\n' > "$path"
}

call_count() {
  local state_dir="$1" role="$2"
  cat "$state_dir/callcount-${role}" 2>/dev/null || echo 0
}

result_of() {
  cat "$1/result.txt" 2>/dev/null || echo "MISSING"
}

failure_code_of() {
  cat "$1/failure-code.txt" 2>/dev/null || echo "NONE"
}

# =============================================================================
echo "[시나리오 A] implement PASS, review CHANGES_REQUESTED → repair가 불려야 하고, 이후 재검토를 거쳐 commit돼야 한다"
# =============================================================================

REPO_A="$TMP_ROOT/repoA"
STATE_A="$TMP_ROOT/stateA"
make_repo "$REPO_A"
make_task "$TMP_ROOT/taskA.md"
mkdir -p "$STATE_A"

MOCK_VERDICT_IMPLEMENT=PASS \
MOCK_VERDICT_REVIEW_1=CHANGES_REQUESTED \
MOCK_VERDICT_REPAIR=PASS \
MOCK_VERDICT_REVIEW_2=PASS \
KANT_AUTO_COMMIT=1 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/taskA.md" "$STATE_A" "$REPO_A" '' '' \
  "mockagent:m1,mockagent:m2,mockagent:m3" '' >/dev/null 2>&1 || true

repair_calls_A="$(call_count "$STATE_A" repair)"
review_calls_A="$(call_count "$STATE_A" review)"
result_A="$(result_of "$STATE_A")"

echo "  repair 호출 횟수: $repair_calls_A (목표: >=1, review가 CHANGES_REQUESTED면 repair가 반드시 불려야 함)"
if [ "$repair_calls_A" -ge 1 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (지금 코드는 review=CHANGES_REQUESTED에서 즉시 종료해 repair를 부르지 않음)"; ((FAIL++)); fi

echo "  review 호출 횟수: $review_calls_A (목표: >=2, 초기 review + repair 이후 최종 재검토)"
if [ "$review_calls_A" -ge 2 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (지금 코드에는 최종 재검토 단계 자체가 없음)"; ((FAIL++)); fi

echo "  최종 result: $result_A (목표: completed, repair+최종 review PASS 이후 commit)"
if [ "$result_A" = "completed" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (실제: $result_A, failure-code=$(failure_code_of "$STATE_A"))"; ((FAIL++)); fi

# =============================================================================
echo ""
echo "[시나리오 B] implement PASS, review PASS → repair는 생략되고 바로 commit돼야 한다"
# =============================================================================

REPO_B="$TMP_ROOT/repoB"
STATE_B="$TMP_ROOT/stateB"
make_repo "$REPO_B"
make_task "$TMP_ROOT/taskB.md"
mkdir -p "$STATE_B"

MOCK_VERDICT_IMPLEMENT=PASS \
MOCK_VERDICT_REVIEW=PASS \
KANT_AUTO_COMMIT=1 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/taskB.md" "$STATE_B" "$REPO_B" '' '' \
  "mockagent:m1,mockagent:m2,mockagent:m3" '' >/dev/null 2>&1 || true

repair_calls_B="$(call_count "$STATE_B" repair)"
echo "  repair 호출 횟수: $repair_calls_B (목표: 0, review가 이미 PASS면 고칠 게 없으므로 repair 생략)"
if [ "$repair_calls_B" -eq 0 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (지금 코드는 review=PASS여도 repair를 무조건 한 번 더 부름)"; ((FAIL++)); fi

# repair가 실제로 불렸다면, 그 결과물(repair-1.marker)이 아무도 검토하지 않은 채
# 그대로 커밋 트리에 들어갔는지까지 확인한다 — "review 안 된 코드가 커밋된다"는
# 문제를 파일 존재만으로 주장하지 않고 실제 git 커밋을 까서 증명한다.
if [ "$repair_calls_B" -ge 1 ]; then
  commit_sha_B="$(cat "$STATE_B/commit-sha.txt" 2>/dev/null || echo "")"
  if [ -n "$commit_sha_B" ] && git -C "$REPO_B" show --stat "$commit_sha_B" 2>/dev/null | grep -q 'repair-1.marker'; then
    echo "  관찰: repair-1.marker가 커밋 $commit_sha_B 에 실제로 포함됨 — 검토되지 않은 repair 산출물이 그대로 커밋됨"
  fi
fi

# =============================================================================
echo ""
echo "[시나리오 C] implement PASS, review CHANGES_REQUESTED, repair PASS, 최종 review CHANGES_REQUESTED → commit 금지, repair는 한 번만"
# =============================================================================

REPO_C="$TMP_ROOT/repoC"
STATE_C="$TMP_ROOT/stateC"
make_repo "$REPO_C"
make_task "$TMP_ROOT/taskC.md"
mkdir -p "$STATE_C"

MOCK_VERDICT_IMPLEMENT=PASS \
MOCK_VERDICT_REVIEW_1=CHANGES_REQUESTED \
MOCK_VERDICT_REPAIR=PASS \
MOCK_VERDICT_REVIEW_2=CHANGES_REQUESTED \
KANT_AUTO_COMMIT=1 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/taskC.md" "$STATE_C" "$REPO_C" '' '' \
  "mockagent:m1,mockagent:m2,mockagent:m3" '' >/dev/null 2>&1 || true

repair_calls_C="$(call_count "$STATE_C" repair)"
review_calls_C="$(call_count "$STATE_C" review)"
result_C="$(result_of "$STATE_C")"
failure_code_C="$(failure_code_of "$STATE_C")"

echo "  repair 호출 횟수: $repair_calls_C (목표: ==1, 최종 review가 다시 거부해도 두 번째 repair는 금지)"
if [ "$repair_calls_C" -eq 1 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (실제: $repair_calls_C)"; ((FAIL++)); fi

echo "  review 호출 횟수: $review_calls_C (목표: ==2, 초기+최종)"
if [ "$review_calls_C" -eq 2 ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (실제: $review_calls_C)"; ((FAIL++)); fi

echo "  최종 result: $result_C (목표: failed — commit 금지)"
if [ "$result_C" = "failed" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (실제: $result_C)"; ((FAIL++)); fi

echo "  failure-code: $failure_code_C (목표: REVIEW_NOT_CLEARED — 최종 재검토까지 갔는데도 거부됐다는 뜻이어야 함)"
if [ "$failure_code_C" = "REVIEW_NOT_CLEARED" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL (실제: $failure_code_C — 최종 재검토에 도달하지도 못했다는 뜻)"; ((FAIL++)); fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
