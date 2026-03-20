#!/usr/bin/env bash
# Test: Replica Retention When Source Dead
# Verifies that dynamically-discovered replicas are not lost from ctNodes when
# periodic topology refresh runs while the source is unreachable.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 11: Replica Retention on Source Dead ==="

COMPOSE_OVERRIDE="${E2E_DIR}/docker-compose.source-only.yml"

# 1. Restart puremyhad with source-only config (only mysql-source in nodes list)
echo "  Restarting puremyhad with source-only config..."
docker compose -f "${E2E_DIR}/docker-compose.yml" -f "$COMPOSE_OVERRIDE" \
  up -d --no-deps --force-recreate puremyhad

# 2. Wait for daemon to discover all 3 nodes via SHOW REPLICAS on the source
echo "  Waiting for 3-node topology to be discovered..."
for i in $(seq 1 60); do
  count=$(get_node_count)
  if [ "$count" = "3" ]; then
    echo "  All 3 nodes discovered (${i}s)"
    break
  fi
  sleep 1
done
count=$(get_node_count)
assert_eq "3 nodes discovered via auto-discovery" "3" "$count"

wait_for_health "Healthy" 30

# 3. Stop the source
echo "  Stopping mysql-source..."
$COMPOSE stop mysql-source

# 4. Wait for DeadSource detection
wait_for_health "DeadSource" 30

# 5. Wait long enough for periodic discover (5s interval) to run multiple times
echo "  Waiting 20s for periodic topology refresh to run..."
sleep 20

# 6. Verify replicas are still tracked
count_after=$(get_node_count)
assert_eq "Replicas retained after source death + topology refresh" "3" "$count_after"

# 7. Restore original config
echo "  Restoring original puremyhad config..."
$COMPOSE up -d --no-deps --force-recreate puremyhad
reset_cluster

test_summary
