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

# Kill the source (hard stop -> TCP RST -> replicas detect IO=No -> DeadSource)
echo "  Stopping mysql-source..."
$COMPOSE stop mysql-source

# Wait for failover to complete (health should return to Healthy with new source)
# DeadSource detection + failover execution may take several seconds
echo "  Waiting for auto-failover..."
wait_for_health "Healthy" 60

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

test_summary
