#!/usr/bin/env bash
# Test: Pause and Resume Replica
# Tests that pause-replica excludes a node from failover candidates
# WITHOUT stopping MySQL replication (data continues to replicate).
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 08: Pause / Resume Replica ==="

wait_for_health "Healthy" 60

# --- Reject pause-replica on source node ---
echo "  Verifying pause-replica rejects source node..."
source_pause=$(cli_pause_replica "mysql-source")
source_pause_err=$(echo "$source_pause" | jq -r '.failure // empty')
assert_not_empty "pause-replica on source returns error" "$source_pause_err"

# --- Reject resume-replica on source node ---
echo "  Verifying resume-replica rejects source node..."
source_resume=$(cli_resume_replica "mysql-source")
source_resume_err=$(echo "$source_resume" | jq -r '.failure // empty')
assert_not_empty "resume-replica on source returns error" "$source_resume_err"

# --- Pause replica (exclude from failover candidates) ---
echo "  Pausing replica mysql-replica1 (exclude from failover)..."
pause_result=$(cli_pause_replica "mysql-replica1")
echo "  Pause response: $pause_result"

pause_success=$(echo "$pause_result" | jq -r '.success // empty')
assert_not_empty "Pause returns success message" "$pause_success"

# Wait for daemon to pick up paused state
sleep 3

# Verify paused flag in topology
topo=$(cli_topology)
paused=$(echo "$topo" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == true" "true" "$paused"

# --- Write data on source, verify it STILL reaches paused replica ---
# pause-replica does NOT stop MySQL replication, only excludes from failover
echo "  Writing data on source..."
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_pause_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_pause_test.t1 (id INT PRIMARY KEY);"
mysql_exec mysql-source "INSERT INTO e2e_pause_test.t1 VALUES (1);"

# Give time for replication (should still arrive since pause-replica does NOT stop replication)
sleep 5

# Check that data DID replicate to paused replica (replication is still running)
paused_count=$(mysql_exec mysql-replica1 "SELECT COUNT(*) FROM e2e_pause_test.t1;" 2>/dev/null || echo "0")
paused_count=$(echo "$paused_count" | tr -d '[:space:]')
assert_eq "Data replicated to paused replica (replication still running)" "1" "$paused_count"

# And it should also reach the non-paused replica2
running_count=$(mysql_exec mysql-replica2 "SELECT COUNT(*) FROM e2e_pause_test.t1;" 2>/dev/null || echo "0")
running_count=$(echo "$running_count" | tr -d '[:space:]')
assert_eq "Data replicated to running replica2" "1" "$running_count"

# --- Resume replica (re-include in failover candidates) ---
echo "  Resuming replica mysql-replica1 (re-include in failover)..."
resume_result=$(cli_resume_replica "mysql-replica1")
echo "  Resume response: $resume_result"

resume_success=$(echo "$resume_result" | jq -r '.success // empty')
assert_not_empty "Resume returns success message" "$resume_success"

# Wait for daemon to pick up resumed state
sleep 3

# Verify paused flag is now false
topo=$(cli_topology)
paused=$(echo "$topo" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .paused')
assert_eq "mysql-replica1 paused == false" "false" "$paused"

# Cleanup test data
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_pause_test;" || true

test_summary
