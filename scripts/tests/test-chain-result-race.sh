#!/usr/bin/env bash
# test-chain-result-race.sh — --quick --chain 중간 단계 result.txt 조기 기록 회귀 방지
#
# 배경 (2026-07-19 실측 버그):
#   run_quick_mode가 commit_at_end=0일 때 무조건 공유 result.txt에
#   "pass_no_commit"을 썼다. run_quick_chain은 3단계(implement/review/repair)
#   모두 commit_at_end=0으로 호출하므로, 체인의 "중간" 단계가 PASS할 때마다
#   아직 체인이 끝나지 않았는데도 result.txt가 마치 최종 완료처럼 덮어써졌다.
#   cmd_await(및 하네스 훅)는 result.txt가 비어있지 않으면 종료로 간주하므로,
#   체인이 실제로는 review 단계에서 실패로 끝났는데도 이미 "완료"로 오판해
#   조기에 알림이 나갔다.
#
# 수정: run_quick_mode에 8번째 인자 defer_terminal_result(기본값 0)를 추가.
#   run_quick_chain은 각 단계 호출에 1을 넘겨 중간 단계가 result.txt를
#   건드리지 않게 한다. standalone 호출(기본값 0)과 fail_run 즉시 실패
#   경로는 기존 동작을 그대로 유지해야 한다.
#
# 후속 수정 (패치 A, review→repair→재검증 닫힌 루프 복원):
#   run_quick_chain이 initial review/repair/final review 조건부 상태 머신으로
#   바뀌면서, review 역할이 한 실행에서 두 번(초기+최종) 불릴 수 있게 됐다.
#   그래서 mockagent도 role별 호출 횟수를 세고 MOCK_VERDICT_<ROLE>_<N>으로
#   호출 회차별 verdict를 다르게 줄 수 있어야 한다. test 4는 "review가
#   CHANGES_REQUESTED면 repair를 부르면 안 된다"는 옛 버그를 정답으로 고정하고
#   있었으므로, 고쳐진 새 계약(review CHANGES_REQUESTED → repair는 반드시
#   호출돼야 함)에 맞게 다시 썼다.
#
# 이 테스트는 실제 codex/opencode를 부르지 않는다 — 즉시 응답하는 가짜
# adapter(mockagent)로 scripts/ 전체를 격리된 임시 디렉터리에 복사해서 돈다.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

declare -i PASS=0 FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# scripts/ 전체를 격리 복사하고, mockagent 가짜 adapter를 추가한다.
# ADAPTERS_DIR/LIB_DIR는 kant-loop.sh 자신의 BASH_SOURCE 기준 상대경로라,
# 복사본을 실행하면 자동으로 이 복사본의 adapters/lib을 쓴다.
# ---------------------------------------------------------------------------
cp -r "$SKILL_ROOT/scripts" "$TMP_ROOT/scripts"
KANT_LOOP="$TMP_ROOT/scripts/kant-loop.sh"
MOCK_ADAPTER="$TMP_ROOT/scripts/adapters/adapter-mockagent.sh"

cat > "$MOCK_ADAPTER" <<'MOCKEOF'
#!/usr/bin/env bash
# adapter-mockagent.sh — 테스트 전용 가짜 adapter. 즉시 응답한다.
set -Eeuo pipefail

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"
  local state_dir
  state_dir="$(cd "$(dirname "$prompt_file")" && pwd)"

  # review는 한 실행에서 두 번(초기/최종) 불릴 수 있으므로 role별 호출
  # 횟수를 센다. 회차별 verdict override: MOCK_VERDICT_<ROLE>_<N> >
  # MOCK_VERDICT_<ROLE>(모든 회차 공통) > PASS(기본값).
  local role_upper
  role_upper="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"

  local count_file="$state_dir/callcount-${role}"
  local count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"

  # 이 stage의 adapter가 호출된 "시점"에 공유 result.txt가 어떤 상태였는지
  # 스냅샷을 남긴다 — 회귀 검증의 핵심 관찰 지점.
  if [ -f "$state_dir/result.txt" ]; then
    cp "$state_dir/result.txt" "$state_dir/observed-result-at-${role}-${count}.txt"
  else
    printf '%s' "MISSING" > "$state_dir/observed-result-at-${role}-${count}.txt"
  fi

  local override_n override_generic verdict
  eval "override_n=\"\${MOCK_VERDICT_${role_upper}_${count}:-}\""
  eval "override_generic=\"\${MOCK_VERDICT_${role_upper}:-}\""
  verdict="${override_n:-${override_generic:-PASS}}"

  local json_path="$state_dir/mock-${role}-${count}.json"
  printf '{"verdict":"%s","summary":"mock","findings":[],"changed_files":[],"tests_added_or_updated":[],"risks":[],"notes_for_reviewer":""}' "$verdict" > "$json_path"

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

# ---------------------------------------------------------------------------
# 테스트용 git 저장소 (실제 파일 변경 없음 — mockagent가 changed_files:[]를
# 주장하므로 verify_changed_files/do_safety_check/gate-runner 모두 no-op 통과)
# ---------------------------------------------------------------------------
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
  git -C "$dir" commit --allow-empty -qm initial
}

make_task() {
  local path="$1"
  printf '# Task\n\n## 목표\nmock chain race test\n' > "$path"
}

# ─────────────────────────────────────────
echo "[test 1] 체인 중간 단계(implement, review-initial, repair, review-final)는 result.txt가 아직 비어있는 상태를 봐야 한다"

REPO1="$TMP_ROOT/repo1"
STATE1="$TMP_ROOT/state1"
make_repo "$REPO1"
make_task "$TMP_ROOT/task1.md"
mkdir -p "$STATE1"

# 초기 review는 CHANGES_REQUESTED로 repair를 강제로 발동시키고, 최종 review는
# PASS로 체인이 끝까지(commit 직전까지) 흐르게 한다 — implement/review-initial/
# repair/review-final 네 호출 모두를 관측 대상에 넣기 위함.
MOCK_VERDICT_REVIEW_1="CHANGES_REQUESTED" MOCK_VERDICT_REVIEW_2="PASS" \
KANT_AUTO_COMMIT=0 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/task1.md" "$STATE1" "$REPO1" '' '' \
  "mockagent:m1,mockagent:m2,mockagent:m3" '' >/dev/null 2>&1 || true

ok=1
for observed_key in implement-1 review-1 repair-1 review-2; do
  observed="$STATE1/observed-result-at-${observed_key}.txt"
  if [ ! -f "$observed" ]; then
    echo "  FAIL: $observed_key stage never invoked (observed 파일 없음)"
    ok=0
    continue
  fi
  content="$(cat "$observed")"
  if [ "$content" != "MISSING" ]; then
    echo "  FAIL: $observed_key 단계 시작 시점에 result.txt가 이미 '$content'로 채워져 있었음 (조기 기록 버그 재발)"
    ok=0
  fi
done
if [ "$ok" = "1" ]; then echo "  PASS"; ((PASS++)); else ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 2] 체인 3단계 모두 PASS하면, 최종 result.txt는 pass_no_commit이어야 한다 (한 번만 기록)"

final="$(cat "$STATE1/result.txt" 2>/dev/null || echo "MISSING")"
if [ "$final" = "pass_no_commit" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: result.txt='$final'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 3] standalone(체인 아님) review 단독 호출은 기존처럼 즉시 pass_no_commit을 써야 한다"

REPO2="$TMP_ROOT/repo2"
STATE2="$TMP_ROOT/state2"
make_repo "$REPO2"
make_task "$TMP_ROOT/task2.md"
mkdir -p "$STATE2"

KANT_AUTO_COMMIT=1 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/task2.md" "$STATE2" "$REPO2" \
  mockagent m1 '' review >/dev/null 2>&1 || true

standalone_result="$(cat "$STATE2/result.txt" 2>/dev/null || echo "MISSING")"
if [ "$standalone_result" = "pass_no_commit" ]; then echo "  PASS"; ((PASS++)); else echo "  FAIL: result.txt='$standalone_result'"; ((FAIL++)); fi

# ─────────────────────────────────────────
echo "[test 4] review가 끝까지 CHANGES_REQUESTED면 repair는 정확히 한 번만 불리고, 최종 실패는 REVIEW_NOT_CLEARED여야 한다"

REPO3="$TMP_ROOT/repo3"
STATE3="$TMP_ROOT/state3"
make_repo "$REPO3"
make_task "$TMP_ROOT/task3.md"
mkdir -p "$STATE3"

# override 없이 MOCK_VERDICT_REVIEW만 주면 초기/최종 review 호출 모두에
# 적용된다 — repair를 거치고도 여전히 CHANGES_REQUESTED인 상황을 재현한다.
MOCK_VERDICT_REVIEW="CHANGES_REQUESTED" KANT_AUTO_COMMIT=0 "$KANT_LOOP" _run_mode quick "$TMP_ROOT/task3.md" "$STATE3" "$REPO3" '' '' \
  "mockagent:m1,mockagent:m2,mockagent:m3" '' >/dev/null 2>&1 || true

fail_result="$(cat "$STATE3/result.txt" 2>/dev/null || echo "MISSING")"
failure_code="$(cat "$STATE3/failure-code.txt" 2>/dev/null || echo "NONE")"
repair_call_count="$(cat "$STATE3/callcount-repair" 2>/dev/null || echo 0)"

if [ "$fail_result" = "failed" ] && [ "$failure_code" = "REVIEW_NOT_CLEARED" ] && [ "$repair_call_count" -eq 1 ]; then
  echo "  PASS"
  ((PASS++))
else
  echo "  FAIL: result.txt='$fail_result' failure-code='$failure_code' repair_call_count=$repair_call_count (기대: failed / REVIEW_NOT_CLEARED / repair 정확히 1회)"
  ((FAIL++))
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
