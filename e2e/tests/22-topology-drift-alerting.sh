#!/usr/bin/env bash
# Test: Topology Drift Alerting
# Verifies that puremyha_cluster_topology_drift gauge transitions to 1 when a
# configured node disappears from the live topology, and that the on_topology_drift
# hook fires on the False→True transition. Also confirms the metric returns to 0
# after the node comes back.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 22: Topology Drift Alerting ==="

wait_for_health "Healthy" 60

# Ensure no leftover hook marker from previous runs
$COMPOSE exec -T puremyhad rm -f /tmp/hook_topology_drift.log 2>/dev/null || true

# --- Step 1: Verify steady-state metric is 0 ---
# Wait for drift to clear: a previous test may have triggered drift detection
# (e.g. test 21 pauses the source), and the flag is only cleared on the next
# topology refresh cycle (discovery_interval=5s).
echo "  Waiting for topology_drift=0 at steady state (up to 15s)..."
drift_clear=""
for i in $(seq 1 15); do
  body=$(http_get_body "/metrics" 2>/dev/null || echo "")
  if echo "$body" | grep -q 'puremyha_cluster_topology_drift{cluster="e2e"} 0'; then
    drift_clear="yes"
    echo "  topology_drift=0 confirmed at steady state (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "topology_drift=0 at steady state" "yes" "$drift_clear"

# --- Step 2: Stop mysql-replica2 to induce a missing_node drift ---
echo "  Stopping mysql-replica2 to induce topology drift..."
cli_pause_failover >/dev/null 2>&1
$COMPOSE stop mysql-replica2

# Wait for discovery refresh (discovery_interval=5s) and metric to flip to 1
echo "  Waiting for topology_drift=1 (up to 30s)..."
drift_detected=""
for i in $(seq 1 30); do
  body=$(http_get_body "/metrics" 2>/dev/null || echo "")
  if echo "$body" | grep -q 'puremyha_cluster_topology_drift{cluster="e2e"} 1'; then
    drift_detected="yes"
    echo "  topology_drift=1 detected (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "topology_drift transitions to 1" "yes" "$drift_detected"

# --- Step 3: Verify on_topology_drift hook fired ---
echo "  Waiting for on_topology_drift hook to fire (up to 15s)..."
hook_log=""
for i in $(seq 1 15); do
  hook_log=$($COMPOSE exec -T puremyhad cat /tmp/hook_topology_drift.log 2>/dev/null || echo "")
  [ -n "$hook_log" ] && break
  sleep 1
done
echo "  topology_drift hook log: $hook_log"
assert_not_empty "on_topology_drift hook fired" "$hook_log"
assert_contains "hook log contains DRIFT_TYPE" "missing_node" "$hook_log"
assert_contains "hook log contains cluster name" "e2e" "$hook_log"

# --- Step 4: Restart mysql-replica2 and confirm metric returns to 0 ---
echo "  Restarting mysql-replica2 to resolve drift..."
$COMPOSE start mysql-replica2
cli_resume_failover >/dev/null 2>&1

# Wait for replica to reconnect and topology refresh to pick it up
echo "  Waiting for topology_drift to return to 0 (up to 60s)..."
drift_cleared=""
for i in $(seq 1 60); do
  body=$(http_get_body "/metrics" 2>/dev/null || echo "")
  if echo "$body" | grep -q 'puremyha_cluster_topology_drift{cluster="e2e"} 0'; then
    drift_cleared="yes"
    echo "  topology_drift=0 confirmed (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "topology_drift returns to 0 after recovery" "yes" "$drift_cleared"

test_summary
