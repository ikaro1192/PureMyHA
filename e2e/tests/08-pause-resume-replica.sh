#!/usr/bin/env bash
# Test: Pause and Resume Replica
# Tests pausing and resuming replication on a replica via IPC.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 08: Pause / Resume Replica ==="

wait_for_health "Healthy" 60

# --- Pause replication on mysql-replica1 ---
echo "  Pausing replication on mysql-replica1..."
pause_result=$(ipc_pause_replica "mysql-replica1")
echo "  Pause response: $pause_result"

pause_success=$(echo "$pause_result" | jq -r '.data.success // empty')
assert_not_empty "Pause returns success message" "$pause_success"

# Wait for daemon to pick up paused state
sleep 3

# Verify paused flag in topology
topo=$(ipc_topology)
paused=$(echo "$topo" | jq -r '.data[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == true" "true" "$paused"

# --- Write data on source, verify it does NOT reach paused replica ---
echo "  Writing data on source..."
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_pause_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_pause_test.t1 (id INT PRIMARY KEY);"
mysql_exec mysql-source "INSERT INTO e2e_pause_test.t1 VALUES (1);"

# Give a moment for replication (should NOT arrive since paused)
sleep 3

# Check that data did NOT replicate to paused replica
paused_count=$(mysql_exec mysql-replica1 "SELECT COUNT(*) FROM e2e_pause_test.t1;" 2>/dev/null || echo "0")
paused_count=$(echo "$paused_count" | tr -d '[:space:]')
assert_eq "Data NOT replicated to paused replica" "0" "$paused_count"

# But it should reach the non-paused replica2
running_count=$(mysql_exec mysql-replica2 "SELECT COUNT(*) FROM e2e_pause_test.t1;" 2>/dev/null || echo "0")
running_count=$(echo "$running_count" | tr -d '[:space:]')
assert_eq "Data replicated to running replica2" "1" "$running_count"

# --- Resume replication on mysql-replica1 ---
echo "  Resuming replication on mysql-replica1..."
resume_result=$(ipc_resume_replica "mysql-replica1")
echo "  Resume response: $resume_result"

resume_success=$(echo "$resume_result" | jq -r '.data.success // empty')
assert_not_empty "Resume returns success message" "$resume_success"

# Wait for daemon to pick up resumed state and data to catch up
sleep 5

# Verify paused flag is now false
topo=$(ipc_topology)
paused=$(echo "$topo" | jq -r '.data[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == false" "false" "$paused"

# Verify data caught up on replica1
caught_up_count=$(mysql_exec mysql-replica1 "SELECT COUNT(*) FROM e2e_pause_test.t1;" 2>/dev/null || echo "0")
caught_up_count=$(echo "$caught_up_count" | tr -d '[:space:]')
assert_eq "Data caught up on resumed replica" "1" "$caught_up_count"

# Cleanup test data
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_pause_test;" || true

test_summary
