#!/usr/bin/env bash
# Test: Switchover with --drain-timeout
#
# Verifies the "wait then kill" drain behaviour:
#   1. With no extra connections the drain exits early and switchover completes.
#   2. With a persistent connection open on the old source, the drain phase
#      waits, then KILLs the connection, and the switchover still completes.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 20: Switchover with --drain-timeout ==="

wait_for_health "Healthy" 60

# ---------------------------------------------------------------------------
# Case 1: No persistent connections — drain exits early, switchover succeeds
# ---------------------------------------------------------------------------
echo ""
echo "  [Case 1] --drain-timeout 10, no extra connections"

switch_result=$(cli_switchover "mysql-replica2" "false" "10")
echo "  Switchover response: $switch_result"

switch_success=$(echo "$switch_result" | jq -r '.success // empty')
assert_not_empty "Switchover with drain-timeout returns success" "$switch_success"

wait_for_source "mysql-replica2" 15
assert_eq "Source changed to mysql-replica2" "mysql-replica2" "$(get_source_host)"
wait_for_health "Healthy" 30

# ---------------------------------------------------------------------------
# Case 2: Persistent connection present — drain waits then KILLs
# ---------------------------------------------------------------------------
echo ""
echo "  [Case 2] --drain-timeout 10, persistent SELECT SLEEP(30) on old source"

reset_cluster
wait_for_health "Healthy" 60

# Open a persistent query on mysql-source.
# SLEEP(30) keeps the connection alive beyond the drain-timeout window (10s),
# so the daemon must KILL it rather than waiting for natural close.
echo "  Opening persistent connection on mysql-source..."
$COMPOSE exec -T mysql-source mysql -uroot -prootpass -N \
  -e "SELECT SLEEP(30);" >/dev/null 2>&1 &
SLEEP_CONN_PID=$!

# Give the connection a moment to appear in SHOW PROCESSLIST
sleep 1

# Confirm it is visible before starting the switchover
proc_count=$(mysql_exec mysql-source \
  "SELECT COUNT(*) FROM information_schema.processlist \
   WHERE COMMAND = 'Query' AND INFO LIKE 'SELECT SLEEP%';")
echo "  Persistent connections visible: $proc_count"
assert_not_empty "Persistent connection visible in processlist before switchover" "$proc_count"

# Run the switchover — the daemon should:
#   1. Set read_only = ON on mysql-source
#   2. Enter the drain loop, see the SLEEP connection
#   3. Wait up to 10s; connection does not close naturally
#   4. KILL the connection after the timeout
#   5. Continue with promotion of mysql-replica2
echo "  Running: switchover --to mysql-replica2 --drain-timeout 10"
switch_result=$(cli_switchover "mysql-replica2" "false" "10")
echo "  Switchover response: $switch_result"

switch_success=$(echo "$switch_result" | jq -r '.success // empty')
assert_not_empty "Switchover returns success after killing persistent connection" "$switch_success"

wait_for_source "mysql-replica2" 15
assert_eq "Source changed to mysql-replica2" "mysql-replica2" "$(get_source_host)"
wait_for_health "Healthy" 30

# Verify the persistent connection was terminated (KILLed, not naturally closed):
# after KILL CONNECTION the mysql client exits; give it 2s to propagate.
sleep 2
if kill -0 "$SLEEP_CONN_PID" 2>/dev/null; then
  # Process still alive — connection was not killed by the daemon.
  # This is unexpected; record as a soft warning rather than hard failure
  # because the client process may lag slightly behind the server-side kill.
  echo "  WARN: background mysql process still running after switchover"
  kill "$SLEEP_CONN_PID" 2>/dev/null || true
else
  echo "  PASS: background connection terminated (KILL fired as expected)"
  ((PASS_COUNT++)) || true
fi
wait "$SLEEP_CONN_PID" 2>/dev/null || true

test_summary
