#!/usr/bin/env bash
# Test: Failover Without Observed Healthy
# Verifies that failover_without_observed_healthy=true allows auto-failover when
# puremyhad starts with the source already down (e.g. same-AZ failure scenario).
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 24: Failover Without Observed Healthy ==="

COMPOSE_OVERRIDE="${E2E_DIR}/docker-compose.failover-without-observed-healthy.yml"

# Always restore the original puremyhad config on exit so subsequent tests run normally.
restore_puremyhad() {
  $COMPOSE start mysql-source 2>/dev/null || true
  $COMPOSE up -d --no-deps --force-recreate puremyhad 2>/dev/null || true
}
trap restore_puremyhad EXIT

wait_for_health "Healthy" 60

orig_source=$(get_source_host)
echo "  Original source: $orig_source"
assert_eq "Original source is mysql-source" "mysql-source" "$orig_source"

# 1. Stop the source before restarting puremyhad — simulates AZ failure where
#    both puremyhad and the source go down simultaneously.
echo "  Stopping mysql-source (simulating AZ failure)..."
$COMPOSE stop mysql-source

# 2. Restart puremyhad with failover_without_observed_healthy=true.
#    This simulates puremyhad being restarted by Pacemaker in a different AZ
#    while the source is still down — it starts fresh with ctObservedHealthy=false.
echo "  Restarting puremyhad with failover_without_observed_healthy=true..."
docker compose -f "${E2E_DIR}/docker-compose.yml" -f "$COMPOSE_OVERRIDE" \
  up -d --no-deps --force-recreate puremyhad

# 3. Wait for puremyhad to detect DeadSource and trigger auto-failover.
#    With failover_without_observed_healthy=true, it should promote a replica
#    without ever having seen the cluster as Healthy.
echo "  Waiting for auto-failover (without prior Healthy observation)..."
wait_for_health "Healthy" 90

# 4. Verify source changed
new_source=$(get_source_host)
echo "  New source after failover: $new_source"
assert_neq "Source changed from original" "$orig_source" "$new_source"
assert_eq "New source is mysql-replica1 (candidate_priority)" "mysql-replica1" "$new_source"

# 5. Restore original config
echo "  Restoring original puremyhad config..."
$COMPOSE up -d --no-deps --force-recreate puremyhad
reset_cluster

test_summary
