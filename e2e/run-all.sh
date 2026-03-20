#!/usr/bin/env bash
# E2E test runner for PureMyHA
# Usage: ./run-all.sh [test_number]
#   ./run-all.sh       # Run all tests
#   ./run-all.sh 02    # Run only test 02
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source lib/helpers.sh

cleanup() {
  echo ""
  echo "=== Tearing down E2E environment ==="
  $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building E2E environment ==="
$COMPOSE build

echo "=== Starting E2E environment ==="
$COMPOSE up -d

echo "=== Waiting for MySQL containers ==="
wait_for_mysql mysql-source 120
wait_for_mysql mysql-replica1 120
wait_for_mysql mysql-replica2 120

echo "=== Setting up replication ==="
setup_replication

echo "=== Waiting for puremyhad to discover topology ==="
wait_for_health "Healthy" 60

echo ""
echo "========================================="
echo "  E2E environment ready. Running tests."
echo "========================================="
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_TESTS=()
TEST_FILTER="${1:-}"

for test_script in tests/*.sh; do
  test_name="$(basename "$test_script")"

  # If a filter is specified, only run matching test
  if [ -n "$TEST_FILTER" ] && [[ "$test_name" != *"$TEST_FILTER"* ]]; then
    continue
  fi

  echo ""
  echo "--- Running: $test_name ---"

  # Reset cluster state between tests
  PASS_COUNT=0
  FAIL_COUNT=0
  reset_cluster

  if bash "$test_script"; then
    echo "--- $test_name: OK ---"
  else
    echo "--- $test_name: FAILED ---"
    FAILED_TESTS+=("$test_name")
  fi
done

echo ""
echo "========================================="
echo "  E2E Test Summary"
echo "========================================="
echo "Tests run: $(ls tests/*.sh | wc -l | tr -d ' ')"
echo "Failed: ${#FAILED_TESTS[@]}"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
else
  echo "All tests passed!"
fi
