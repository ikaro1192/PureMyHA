#!/usr/bin/env bash
# Test: Auto-Failover
# Kills the source and verifies automatic failover to the preferred candidate.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 02: Auto-Failover ==="

wait_for_health "Healthy" 60

orig_source=$(get_source_host)
echo "  Original source: $orig_source"
assert_eq "Original source is mysql-source" "mysql-source" "$orig_source"

# Write data before failover to verify data integrity after promotion
echo "  Writing test data before failover..."
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_failover_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_failover_test.t1 (id INT PRIMARY KEY, val VARCHAR(50));"
mysql_exec mysql-source "INSERT INTO e2e_failover_test.t1 VALUES (1, 'before-failover');"
# Wait for replication to propagate
sleep 2

# Kill the source (hard stop -> TCP RST -> replicas detect IO=No -> DeadSource)
echo "  Stopping mysql-source..."
$COMPOSE stop mysql-source

# Wait for failover to complete (health should return to Healthy with new source)
# DeadSource detection + failover execution may take several seconds
echo "  Waiting for auto-failover..."
wait_for_health "Healthy" 90

# Verify source changed
new_source=$(get_source_host)
echo "  New source after failover: $new_source"
assert_neq "Source changed from original" "$orig_source" "$new_source"
assert_eq "New source is mysql-replica1 (candidate_priority)" "mysql-replica1" "$new_source"

# Verify recovery block is set (anti-flap)
recovery_blocked=$(get_recovery_blocked)
assert_neq "Recovery block is set" "null" "$recovery_blocked"

# Verify remaining nodes are healthy
node_count=$(get_node_count)
assert_eq "Still tracking 3 nodes" "3" "$node_count"

# --- Data integrity: verify pre-failover data exists on new source ---
echo "  Verifying data integrity after failover..."
data_count=$(mysql_exec "$new_source" "SELECT COUNT(*) FROM e2e_failover_test.t1 WHERE val='before-failover';" 2>/dev/null | tr -d '[:space:]')
assert_eq "Pre-failover data exists on new source" "1" "$data_count"

# Cleanup test data
mysql_exec "$new_source" "DROP DATABASE IF EXISTS e2e_failover_test;" || true

# --- Anti-flap: ack-recovery (merged from test 06) ---
# Acknowledge recovery to clear the block
echo "  Sending ack-recovery..."
ack_result=$(cli_ack_recovery)
ack_success=$(echo "$ack_result" | jq -r '.success // empty')
assert_eq "Ack recovery succeeds" "Recovery block cleared" "$ack_success"

# Verify block is cleared
recovery_blocked_after=$(get_recovery_blocked)
assert_eq "Recovery block cleared after ack" "null" "$recovery_blocked_after"

test_summary
