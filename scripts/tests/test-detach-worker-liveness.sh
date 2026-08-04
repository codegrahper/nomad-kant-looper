#!/usr/bin/env bash
# test-detach-worker-liveness.sh — detached worker 생존/종료 계약 검증
#
# 2026-08-04 회귀:
#   detach 로 띄운 자식이 시작도 못 하고 즉시 죽었는데
#     - 실패 상태가 기록되지 않아 run-state.json 이 preparing 으로 남고
#     - await 가 result.txt 만 보고 있어 죽은 PID 를 감지하지 못해
#     - 30분 timeout 까지 헛대기했다.
#
# 검증 대상:
#   1. await: detached PID 가 사라졌고 terminal result 가 없으면 즉시 실패로 마감
#   2. await: detached PID 가 살아있으면 기존처럼 폴링 (오탐 없음)
#   3. await: detached.pid 가 없는 run 은 기존 동작 유지 (회귀 방지)
#   4. _run_mode: 진입 즉시 worker-started 마커 + WORKER_STARTED 이벤트
#   5. _run_mode: TERM 시그널로 죽어도 terminal state 를 남긴다
#   6. detach: 자식에게 원본이 아니라 state_dir/task.md 스냅샷을 넘긴다
#   7. detach: handshake 통과 시에만 성공 반환
#   8. state_writer: worker_started 만 있어도 status 가 preparing 에 머물지 않는다

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KANT_LOOP="$SKILL_ROOT/scripts/kant-loop.sh"

declare -i PASS=0 FAIL=0

[ -f "$KANT_LOOP" ] || { echo "FAIL: $KANT_LOOP not found"; exit 1; }

TEST_ROOT="/tmp/kant-liveness-test-$$"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"
export KANT_STATE_ROOT="$TEST_ROOT/state"
mkdir -p "$KANT_STATE_ROOT"

cleanup() {
  # 남은 가짜 워커 정리
  if [ -n "${LONG_PID:-}" ]; then kill -9 "$LONG_PID" 2>/dev/null || true; fi
  if [ -n "${LIVE_PID:-}" ]; then kill -9 "$LIVE_PID" 2>/dev/null || true; fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

RH=$(printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)

ok()   { echo "  PASS${1:+ ($1)}"; ((PASS++)); }
bad()  { echo "  FAIL: $1"; ((FAIL++)); }

# ─────────────────────────────────────────
# 가짜 스킬 트리 — 실제 외부 도구를 부르지 않고 어댑터 구간을 재현한다.
FAKE_ROOT="$TEST_ROOT/skill"
mkdir -p "$FAKE_ROOT/scripts/adapters"
cp "$SKILL_ROOT/scripts/kant-loop.sh" "$FAKE_ROOT/scripts/kant-loop.sh"
cp -R "$SKILL_ROOT/scripts/lib" "$FAKE_ROOT/scripts/lib"
FAKE_LOOP="$FAKE_ROOT/scripts/kant-loop.sh"

# 짧게 도는 어댑터 — 시그널 전달 후 trap 이 도는지 보기 위한 것
cat > "$FAKE_ROOT/scripts/adapters/adapter-faketool.sh" <<'ADP'
#!/usr/bin/env bash
sleep 5
ADP
chmod +x "$FAKE_ROOT/scripts/adapters/adapter-faketool.sh"

# 오래 도는 어댑터 — detach 후 자식이 살아있는 동안 관찰하기 위한 것
cat > "$FAKE_ROOT/scripts/adapters/adapter-fakelong.sh" <<'ADP'
#!/usr/bin/env bash
sleep 120
ADP
chmod +x "$FAKE_ROOT/scripts/adapters/adapter-fakelong.sh"

# ─────────────────────────────────────────
echo "[test 1] await: detached PID 사망 + terminal result 없음 → 즉시 실패 (핵심 회귀)"

RID="run-dead-worker"
SD="$KANT_STATE_ROOT/$RH/$RID"
mkdir -p "$SD"
echo "agent/kant/$RID" > "$SD/branch.txt"
# 확실히 종료된 PID 확보: 즉시 끝나는 프로세스를 띄우고 reap 한다
(exit 0) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null
echo "$DEAD_PID" > "$SD/detached.pid"

start=$(date +%s)
output=$("$KANT_LOOP" await "$RID" --timeout 60 --interval 1 2>&1)
rc=$?
elapsed=$(( $(date +%s) - start ))

if [ "$rc" -eq 1 ] \
   && [ "$elapsed" -le 15 ] \
   && [ "$(cat "$SD/result.txt" 2>/dev/null)" = "failed" ] \
   && [ "$(cat "$SD/failure-code.txt" 2>/dev/null)" = "WORKER_VANISHED" ]; then
  ok "${elapsed}s, timeout(60s) 까지 기다리지 않음"
else
  bad "rc=$rc elapsed=${elapsed}s result=$(cat "$SD/result.txt" 2>/dev/null) code=$(cat "$SD/failure-code.txt" 2>/dev/null)"
  printf '%s\n' "$output" | head -5
fi

# ─────────────────────────────────────────
echo "[test 2] await: detached PID 생존 중 → 죽었다고 오판하지 않는다"

RID2="run-live-worker"
SD2="$KANT_STATE_ROOT/$RH/$RID2"
mkdir -p "$SD2"
echo "agent/kant/$RID2" > "$SD2/branch.txt"
sleep 30 & LIVE_PID=$!
echo "$LIVE_PID" > "$SD2/detached.pid"

output=$("$KANT_LOOP" await "$RID2" --timeout 3 --interval 1 2>&1)
rc=$?
kill -9 "$LIVE_PID" 2>/dev/null || true
LIVE_PID=""

# 살아있는 워커는 timeout(2) 으로 끝나야 한다 — WORKER_VANISHED 로 조기 실패하면 오탐
if [ "$rc" -eq 2 ] \
   && printf '%s' "$output" | grep -q "TIMEOUT" \
   && [ ! -f "$SD2/failure-code.txt" ]; then
  ok
else
  bad "rc=$rc code=$(cat "$SD2/failure-code.txt" 2>/dev/null)"
  printf '%s\n' "$output" | head -5
fi

# ─────────────────────────────────────────
echo "[test 3] await: detached.pid 없는 run → 기존 폴링 동작 유지 (회귀 방지)"

RID3="run-no-pid"
SD3="$KANT_STATE_ROOT/$RH/$RID3"
mkdir -p "$SD3"
echo "agent/kant/$RID3" > "$SD3/branch.txt"

output=$("$KANT_LOOP" await "$RID3" --timeout 2 --interval 1 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$output" | grep -q "TIMEOUT" && [ ! -f "$SD3/result.txt" ]; then
  ok
else
  bad "rc=$rc result=$(cat "$SD3/result.txt" 2>/dev/null)"
fi

# ─────────────────────────────────────────
echo "[test 4] _run_mode: 진입 즉시 worker-started 마커 + WORKER_STARTED 이벤트"

SD4="$TEST_ROOT/direct-run"
mkdir -p "$SD4"
printf '# task\n\n## Goal\nmarker check\n' > "$TEST_ROOT/task4.md"

"$KANT_LOOP" _run_mode unsupported "$TEST_ROOT/task4.md" "$SD4" "$TEST_ROOT" '' '' '' implement >/dev/null 2>&1
rc=$?

if [ "$rc" -ne 0 ] \
   && [ -f "$SD4/worker-started" ] \
   && grep -q "WORKER_STARTED" "$SD4/phase-events.log" 2>/dev/null; then
  ok
else
  bad "rc=$rc marker=$([ -f "$SD4/worker-started" ] && echo yes || echo no) events=$(cat "$SD4/phase-events.log" 2>/dev/null | tr '\n' ';')"
fi

# ─────────────────────────────────────────
echo "[test 5] _run_mode: TERM 시그널로 죽어도 terminal state 를 남긴다"

SD5="$TEST_ROOT/signal-run"
mkdir -p "$SD5"
printf '# task\n\n## Goal\nsignal check\n' > "$TEST_ROOT/task5.md"

"$FAKE_LOOP" _run_mode quick "$TEST_ROOT/task5.md" "$SD5" "$TEST_ROOT" faketool fake-model '' implement >/dev/null 2>&1 &
SIG_PID=$!

# 워커가 어댑터 구간에 진입할 때까지 기다린다
waited=0
while [ "$waited" -lt 15 ]; do
  [ -f "$SD5/worker-started" ] && break
  sleep 1
  waited=$((waited + 1))
done

kill -TERM "$SIG_PID" 2>/dev/null || true
wait "$SIG_PID" 2>/dev/null
sig_rc=$?

if [ -f "$SD5/result.txt" ] && [ "$(cat "$SD5/result.txt")" = "failed" ]; then
  ok "rc=$sig_rc code=$(cat "$SD5/failure-code.txt" 2>/dev/null)"
else
  bad "terminal state 없음 rc=$sig_rc result=$(cat "$SD5/result.txt" 2>/dev/null)"
fi

# ─────────────────────────────────────────
echo "[test 6+7] detach: handshake 통과 + 자식에게 state_dir/task.md 스냅샷 전달"

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
printf '# detach snapshot check\n\n## Goal\nsnapshot\n' > "$REPO/TASK-detach-check.md"

detach_out=$(cd "$REPO" && "$FAKE_LOOP" run "TASK-detach-check.md" --quick \
  --agent fakelong --model fake-model --detach 2>&1)
detach_rc=$?

RID6=$(printf '%s' "$detach_out" | grep '^run_id:' | awk '{print $2}')
REPO_RH=$(cd "$REPO" && printf '%s' "$(pwd)" | shasum -a 256 | cut -c1-12)
SD6="$KANT_STATE_ROOT/$REPO_RH/${RID6:-none}"
LONG_PID=$(cat "$SD6/detached.pid" 2>/dev/null || echo "")

# test 7: handshake 를 통과했으므로 exit 0 + 마커 존재
if [ "$detach_rc" -eq 0 ] && [ -n "$RID6" ] && [ -f "$SD6/worker-started" ]; then
  ok "handshake 통과, run_id=$RID6"
else
  bad "detach rc=$detach_rc run_id=${RID6:-none} marker=$([ -f "$SD6/worker-started" ] && echo yes || echo no)"
  printf '%s\n' "$detach_out" | head -8
fi

# test 6: 자식 명령줄이 원본이 아니라 state_dir/task.md 를 가리켜야 한다
child_args=$(ps -o command= -p "${LONG_PID:-0}" 2>/dev/null || echo "")
if printf '%s' "$child_args" | grep -q "$SD6/task.md"; then
  ok "자식 인자가 스냅샷 경로"
elif printf '%s' "$child_args" | grep -q "TASK-detach-check.md"; then
  bad "자식이 아직 원본 TASK 경로를 받고 있음: $child_args"
else
  bad "자식 인자 확인 불가 (pid=${LONG_PID:-none}) args='$child_args'"
fi

# 원본을 지워도 워커가 죽지 않는지 — 스냅샷을 읽고 있다는 실제 증거
rm -f "$REPO/TASK-detach-check.md"
sleep 1
if kill -0 "${LONG_PID:-0}" 2>/dev/null; then
  echo "  (원본 삭제 후에도 워커 생존 — 스냅샷 사용 확인)"
fi

kill -9 "${LONG_PID:-0}" 2>/dev/null || true
LONG_PID=""

# ─────────────────────────────────────────
echo "[test 8] state_writer: worker_started 만 있어도 preparing 에 머물지 않는다"

SD8="$TEST_ROOT/status-run"
mkdir -p "$SD8"
echo "$RID" > "$SD8/run-id.txt"
echo "quick" > "$SD8/mode.txt"
echo "$REPO" > "$SD8/repo.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$SD8/started-at.txt"
printf '[2026-08-04T00:00:00Z] RUN_CREATED\n[2026-08-04T00:00:01Z] WORKER_STARTED mode=quick tool=codex model=gpt-5.6-sol role=implement\n' \
  > "$SD8/phase-events.log"

python3 "$SKILL_ROOT/scripts/lib/state_writer.py" "$SD8" >/dev/null 2>&1
status_val=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$SD8/run-state.json" 2>/dev/null || echo "ERR")
has_ev=$(grep -c "worker_started" "$SD8/events.jsonl" 2>/dev/null || echo 0)

if [ "$status_val" = "running" ] && [ "$has_ev" -ge 1 ]; then
  ok "status=$status_val, worker_started 이벤트 노출"
else
  bad "status=$status_val worker_started_events=$has_ev"
fi

echo ""
echo "=== 결과 ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
