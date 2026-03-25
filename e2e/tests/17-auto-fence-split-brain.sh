#!/usr/bin/env bash
# Test: Auto-fence split-brain nodes
# When auto_fence is enabled and SplitBrainSuspected is detected, the daemon
# automatically sets super_read_only=ON on all source-role nodes except the
# one with the highest GTID count (the survivor). The operator can then clear
# super_read_only via `puremyha unfence --host <host>`.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 17: Auto-fence split-brain nodes ==="

wait_for_health "Healthy" 60

# --- Step 1: Simulate split-brain by stopping replication on mysql-replica1
# and promoting it to source without demoting the original source ---
echo "  Creating split-brain: promoting mysql-replica1 without demoting mysql-source..."
mysql_exec mysql-replica1 "STOP REPLICA;"
mysql_exec mysql-replica1 "RESET REPLICA ALL;"
mysql_exec mysql-replica1 "SET GLOBAL read_only = OFF;"
mysql_exec mysql-replica1 "SET GLOBAL super_read_only = OFF;"

# Write a little data on the original source so GTID counts differ
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_fence_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_fence_test.t1 (id INT PRIMARY KEY);"
mysql_exec mysql-source "INSERT INTO e2e_fence_test.t1 VALUES (1);"
mysql_exec mysql-source "INSERT INTO e2e_fence_test.t1 VALUES (2);"

echo "  Split-brain created: mysql-source and mysql-replica1 are both source-role"

# --- Step 2: Wait for daemon to detect SplitBrainSuspected ---
wait_for_health "SplitBrainSuspected" 30

# --- Step 3: Wait for auto-fence to kick in (auto_fence: true must be in config) ---
# The daemon fences the lower-GTID source (mysql-replica1 since it has fewer transactions)
echo "  Waiting for auto-fence to set super_read_only on split-brain node..."
sleep 5

# --- Step 4: Verify super_read_only is set on the fenced node ---
# mysql-replica1 (lower GTID) should be fenced
fenced_sr=$(mysql_exec mysql-replica1 "SELECT @@GLOBAL.super_read_only;" | tr -d '[:space:]')
echo "  mysql-replica1 super_read_only: $fenced_sr"
assert_eq "mysql-replica1 is fenced (super_read_only=1)" "1" "$fenced_sr"

# mysql-source (higher GTID, survivor) should NOT be fenced
survivor_sr=$(mysql_exec mysql-source "SELECT @@GLOBAL.super_read_only;" | tr -d '[:space:]')
echo "  mysql-source super_read_only: $survivor_sr"
assert_eq "mysql-source (survivor) is not fenced (super_read_only=0)" "0" "$survivor_sr"

# --- Step 5: Verify fenced state appears in topology output ---
echo "  Checking fenced field in topology output..."
topology=$(cli_topology)
fenced_in_topo=$(echo "$topology" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .fenced')
assert_eq "Topology shows mysql-replica1 as fenced" "true" "$fenced_in_topo"

survivor_fenced=$(echo "$topology" | jq -r '.[0].nodes[] | select(.host == "mysql-source") | .fenced')
assert_eq "Topology shows mysql-source as not fenced" "false" "$survivor_fenced"

# --- Step 6: Unfence mysql-replica1 via CLI ---
echo "  Unfencing mysql-replica1 via puremyha unfence..."
unfence_result=$(cli_unfence "mysql-replica1")
echo "  Unfence response: $unfence_result"
unfence_success=$(echo "$unfence_result" | jq -r '.success // empty')
assert_not_empty "Unfence returns success" "$unfence_success"

# --- Step 7: Verify super_read_only is cleared ---
sleep 2
unfenced_sr=$(mysql_exec mysql-replica1 "SELECT @@GLOBAL.super_read_only;" | tr -d '[:space:]')
echo "  mysql-replica1 super_read_only after unfence: $unfenced_sr"
assert_eq "mysql-replica1 super_read_only cleared after unfence" "0" "$unfenced_sr"

# --- Step 8: Verify fenced field is cleared in topology ---
topology2=$(cli_topology)
fenced_after=$(echo "$topology2" | jq -r '.[0].nodes[] | select(.host == "mysql-replica1") | .fenced')
assert_eq "Topology shows mysql-replica1 as not fenced after unfence" "false" "$fenced_after"

# --- Cleanup: Restore replication ---
echo "  Restoring replication on mysql-replica1..."
mysql_exec mysql-replica1 "SET GLOBAL read_only = ON;" || true
mysql_exec mysql-replica1 "SET GLOBAL super_read_only = ON;" || true
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_fence_test;" || true

test_summary
