#!/usr/bin/env bash
# Test: Stop and Start Replication
# Tests that stop-replication executes STOP REPLICA and auto-pauses,
# and start-replication executes START REPLICA and auto-resumes.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 25: Stop / Start Replication ==="

wait_for_health "Healthy" 60

# --- Stop replication on mysql-replica1 ---
echo "  Stopping replication on mysql-replica1..."
stop_result=$(cli_stop_replication "mysql-replica1")
echo "  Stop response: $stop_result"

stop_success=$(echo "$stop_result" | jq -r '.success // empty')
assert_not_empty "Stop replication returns success message" "$stop_success"

# Wait for daemon to pick up paused state
sleep 3

# Verify paused flag in topology (auto-pause)
topo=$(cli_topology)
paused=$(echo "$topo" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == true (auto-pause)" "true" "$paused"

# --- Write data on source, verify it does NOT reach stopped replica ---
echo "  Writing data on source..."
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_stoprepl_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_stoprepl_test.t1 (id INT PRIMARY KEY);"
mysql_exec mysql-source "INSERT INTO e2e_stoprepl_test.t1 VALUES (1);"

# Give a moment for replication (should NOT arrive since STOP REPLICA was executed)
sleep 3

# Check that data did NOT replicate to stopped replica
stopped_count=$(mysql_exec mysql-replica1 "SELECT COUNT(*) FROM e2e_stoprepl_test.t1;" 2>/dev/null || echo "0")
stopped_count=$(echo "$stopped_count" | tr -d '[:space:]')
assert_eq "Data NOT replicated to stopped replica" "0" "$stopped_count"

# But it should reach the non-stopped replica2
running_count=$(mysql_exec mysql-replica2 "SELECT COUNT(*) FROM e2e_stoprepl_test.t1;" 2>/dev/null || echo "0")
running_count=$(echo "$running_count" | tr -d '[:space:]')
assert_eq "Data replicated to running replica2" "1" "$running_count"

# --- Start replication on mysql-replica1 ---
echo "  Starting replication on mysql-replica1..."
start_result=$(cli_start_replication "mysql-replica1")
echo "  Start response: $start_result"

start_success=$(echo "$start_result" | jq -r '.success // empty')
assert_not_empty "Start replication returns success message" "$start_success"

# Wait for daemon to pick up resumed state and data to catch up
sleep 5

# Verify paused flag is now false (auto-resume)
topo=$(cli_topology)
paused=$(echo "$topo" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == false (auto-resume)" "false" "$paused"

# Verify data caught up on replica1
caught_up_count=$(mysql_exec mysql-replica1 "SELECT COUNT(*) FROM e2e_stoprepl_test.t1;" 2>/dev/null || echo "0")
caught_up_count=$(echo "$caught_up_count" | tr -d '[:space:]')
assert_eq "Data caught up on started replica" "1" "$caught_up_count"

# Cleanup test data
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_stoprepl_test;" || true

test_summary
