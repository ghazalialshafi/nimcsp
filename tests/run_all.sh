#!/usr/bin/env bash
# tests/run_all.sh
#
# Builds and runs the full nimcsp test suite. This codifies the exact
# verification process used during development: every correctness/feature
# test is run multiple times (goroutine scheduling races are inherently
# timing-dependent -- a single passing run proves very little), and every
# binary is built with the flags that are actually required for this
# library to be correct (see README.md "Build requirements" -- most
# importantly --mm:arc, which is not optional).
#
# Usage:
#   tests/run_all.sh            # full suite, matching what CI runs
#   tests/run_all.sh --quick    # fewer repetitions, for a fast local check
#
# Exits 0 if every test passed every repetition, non-zero otherwise.

set -u
cd "$(dirname "$0")/.."

QUICK=0
if [[ "${1:-}" == "--quick" ]]; then
  QUICK=1
fi

BUILD_FLAGS="--threads:on --mm:arc --stacktrace:off -d:release -d:useMalloc "
BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT

# name:expected_exit_code:repeats:timeout_seconds
# Correctness/feature tests expect exit 0. test_deadlock deliberately
# deadlocks and must exit 2 (the documented fatal-error code) rather than
# hang. Stress tests additionally require a "PASS" marker in their output,
# checked separately below, since a clean exit code alone isn't a strong
# enough correctness signal for those (see CORRECTNESS_CHECK_TESTS).
REPS_QUICK=3
REPS_FULL=20
REPS_STRESS_QUICK=2
REPS_STRESS_FULL=15

if [[ $QUICK -eq 1 ]]; then REPS=$REPS_QUICK; REPS_STRESS=$REPS_STRESS_QUICK
else REPS=$REPS_FULL; REPS_STRESS=$REPS_STRESS_FULL
fi

CORRECTNESS_TESTS=(test_block test_pipe test_select test_net
                    test_once_rwmutex test_context test_context_value
                    test_not_deadlock_timer)
DEADLOCK_TESTS=(test_deadlock)
STRESS_TESTS=(stress_fanout stress_mutex stress_churn)
BENCH_TESTS=(bench_million bench_context_switch)

overall_fail=0

echo "== Building =="
all_tests=("${CORRECTNESS_TESTS[@]}" "${DEADLOCK_TESTS[@]}" "${STRESS_TESTS[@]}" "${BENCH_TESTS[@]}")
for t in "${all_tests[@]}"; do
  if [[ ! -f "tests/$t.nim" ]]; then
    echo "SKIP (not found): tests/$t.nim"
    continue
  fi
  if ! nim c $BUILD_FLAGS -o:"$BIN_DIR/$t" "tests/$t.nim" > "$BIN_DIR/$t.build.log" 2>&1; then
    echo "BUILD FAILED: $t"
    cat "$BIN_DIR/$t.build.log"
    overall_fail=1
  fi
done
if [[ $overall_fail -ne 0 ]]; then
  echo "== Aborting: build failures above =="
  exit 1
fi
echo "All binaries built cleanly."
echo

run_n_times() {
  local name="$1" expect_rc="$2" reps="$3" timeout_s="$4" need_pass_marker="$5"
  local bin="$BIN_DIR/$name"
  [[ -x "$bin" ]] || return 0
  local pass=0 fail=0
  for ((i = 1; i <= reps; i++)); do
    local log="$BIN_DIR/$name.run$i.log"
    timeout "$timeout_s" "$bin" > "$log" 2>&1
    local rc=$?
    local ok=1
    [[ $rc -ne $expect_rc ]] && ok=0
    if [[ "$need_pass_marker" == "1" ]]; then
      grep -qE '^PASS( |$)|PASS all|PASS churn' "$log" || ok=0
    fi
    if [[ $ok -eq 1 ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "  FAIL ($name run $i, rc=$rc, expected $expect_rc):"
      sed 's/^/    /' "$log"
    fi
  done
  printf "%-28s pass=%-4d fail=%-4d\n" "$name" "$pass" "$fail"
  [[ $fail -gt 0 ]] && overall_fail=1
}

echo "== Correctness / feature tests (expect exit 0) =="
for t in "${CORRECTNESS_TESTS[@]}"; do
  run_n_times "$t" 0 "$REPS" 10 0
done
echo

echo "== Deadlock detection (expect exit 2, not a hang) =="
for t in "${DEADLOCK_TESTS[@]}"; do
  run_n_times "$t" 2 "$REPS" 8 0
done
echo

echo "== Stress tests (expect exit 0 + PASS marker; data-integrity checked internally) =="
for t in "${STRESS_TESTS[@]}"; do
  run_n_times "$t" 0 "$REPS_STRESS" 30 1
done
echo

echo "== Benchmark smoke check (must complete + report the exact expected count) =="
if [[ -x "$BIN_DIR/bench_million" ]]; then
  log="$BIN_DIR/bench_million.log"
  timeout 60 "$BIN_DIR/bench_million" > "$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q "Created and destroyed 1000000 goroutines" "$log"; then
    echo "bench_million                pass=1    fail=0"
  else
    echo "bench_million                pass=0    fail=1"
    sed 's/^/    /' "$log"
    overall_fail=1
  fi
fi
if [[ -x "$BIN_DIR/bench_context_switch" ]]; then
  # This one actually exercises cspCoreYield/cspProcRestore on every single
  # operation (unbuffered channel ping-pong) -- see the file's own header
  # for why bench_million alone does not. Also serves as a regression
  # guard for the mxcsr/x87cw initialization bug this benchmark itself
  # uncovered (a fresh goroutine's first floating-point operation could
  # SIGFPE on zeroed FP-exception-mask state -- see csp_proc.nim).
  log="$BIN_DIR/bench_context_switch.log"
  timeout 60 "$BIN_DIR/bench_context_switch" > "$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q "Round trips: 500000" "$log"; then
    echo "bench_context_switch         pass=1    fail=0"
  else
    echo "bench_context_switch         pass=0    fail=1"
    sed 's/^/    /' "$log"
    overall_fail=1
  fi
fi
echo

if [[ $overall_fail -eq 0 ]]; then
  echo "== ALL TESTS PASSED =="
  exit 0
else
  echo "== FAILURES ABOVE =="
  exit 1
fi
