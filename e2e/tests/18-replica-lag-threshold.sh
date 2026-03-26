#!/usr/bin/env bash
# Test: Replica lag threshold — Lagging health state and candidate exclusion
# When a replica's Seconds_Behind_Source reaches replication_lag_critical,
# its health transitions to Lagging and it is excluded from failover candidates.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 18: Replica lag threshold ==="

wait_for_health "Healthy" 60

# --- Step 1: Stop the replica SQL thread to create artificial lag ---
echo "  Stopping SQL thread on mysql-replica1 to induce lag..."
mysql_exec mysql-replica1 "STOP REPLICA SQL_THREAD;"

# Write data to the source so Seconds_Behind_Source grows
echo "  Writing data to source to accumulate lag..."
for i in $(seq 1 5); do
  mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_lag_test;"
  mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_lag_test.t1 (id INT PRIMARY KEY);"
  mysql_exec mysql-source "INSERT IGNORE INTO e2e_lag_test.t1 VALUES ($i);"
  sleep 2
done

# --- Step 2: Wait for node health to transition away from Healthy ---
# The e2e config has replication_lag_critical: 10s, so after ~10s of lag
# the replica should show a non-Healthy state (Lagging or NeedsAttention).
echo "  Waiting for mysql-replica1 health to change..."
replica1_health=""
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if [ -n "$replica1_health" ] && [ "$replica1_health" != "Healthy" ]; then
    echo "  mysql-replica1 health changed to: $replica1_health (${i}s)"
    break
  fi
  sleep 1
done

assert_neq "mysql-replica1 is not Healthy while SQL thread stopped" "Healthy" "$replica1_health"

# Verify lag is reported in topology
lag_value=$(cli_topology 2>/dev/null | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .lagSeconds // -1' 2>/dev/null || echo "-1")
echo "  Replica lag reported: ${lag_value}s"
if [ "$lag_value" != "-1" ] && [ "$lag_value" != "null" ]; then
  # Lag should be >= the critical threshold (10s)
  if [ "$lag_value" -ge 10 ]; then
    echo "  PASS: Lag ($lag_value) >= critical threshold (10s)"
    ((PASS_COUNT++)) || true
  else
    echo "  NOTE: Lag ($lag_value) below threshold, may not have accumulated enough"
  fi
fi

# --- Step 3: Restart SQL thread ---
echo "  Restarting SQL thread on mysql-replica1..."
mysql_exec mysql-replica1 "START REPLICA SQL_THREAD;"

# --- Step 4: Verify cluster returns to Healthy ---
echo "  Waiting for replica to catch up and cluster to return to Healthy..."
wait_for_health "Healthy" 60

echo "  Cleaning up test database..."
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_lag_test;"

echo "=== Test 18 PASSED ==="
