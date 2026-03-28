#!/usr/bin/env bash
# Test: Replica lag threshold — Lagging health state and candidate exclusion
# When a replica's Seconds_Behind_Source reaches replication_lag_critical,
# its health transitions to Lagging and it is excluded from failover candidates.
# Also verifies that on_lag_threshold_exceeded / on_lag_threshold_recovered hooks
# receive PUREMYHA_NODE set to the lagging replica's hostname.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 18: Replica lag threshold ==="

wait_for_health "Healthy" 60

# Ensure no leftover hook marker files from previous runs
$COMPOSE exec -T puremyhad rm -f /tmp/hook_lag_exceeded.log /tmp/hook_lag_recovered.log 2>/dev/null || true

# --- Step 1: Introduce SOURCE_DELAY on mysql-replica1 to simulate lag ---
# SOURCE_DELAY causes the SQL thread to deliberately delay applying transactions,
# making Seconds_Behind_Source grow above replication_lag_critical (10s in e2e config).
echo "  Setting SOURCE_DELAY=30 on mysql-replica1..."
mysql_exec mysql-replica1 "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO SOURCE_DELAY=30;
  START REPLICA;
"

# Write data to source so transactions accumulate in the relay log.
# With SOURCE_DELAY=30, Seconds_Behind_Source will be ~30s once the IO thread
# receives the transactions, exceeding the 10s critical threshold.
echo "  Writing data to source to accumulate lag..."
mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_lag_test;"
mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_lag_test.t1 (id INT PRIMARY KEY);"
for i in $(seq 1 5); do
  mysql_exec mysql-source "INSERT IGNORE INTO e2e_lag_test.t1 VALUES ($i);"
  sleep 1
done

# --- Step 2: Wait for mysql-replica1 health to transition to Lagging ---
echo "  Waiting for mysql-replica1 health to transition to Lagging..."
replica1_health=""
for i in $(seq 1 60); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if echo "$replica1_health" | grep -q "Lagging"; then
    echo "  mysql-replica1 health is Lagging (${i}s)"
    break
  fi
  sleep 1
done

assert_contains "mysql-replica1 transitions to Lagging" "Lagging" "$replica1_health"

# --- Step 2b: Verify on_lag_threshold_exceeded hook fired with PUREMYHA_NODE ---
echo "  Waiting for on_lag_threshold_exceeded hook to fire..."
hook_exceeded=""
for i in $(seq 1 15); do
  hook_exceeded=$($COMPOSE exec -T puremyhad cat /tmp/hook_lag_exceeded.log 2>/dev/null || echo "")
  [ -n "$hook_exceeded" ] && break
  sleep 1
done
echo "  lag_exceeded hook log: $hook_exceeded"
assert_not_empty "on_lag_threshold_exceeded hook fired" "$hook_exceeded"
assert_contains "PUREMYHA_NODE is mysql-replica1" "NODE=mysql-replica1" "$hook_exceeded"
assert_contains "PUREMYHA_LAG_SECONDS is present" "LAG=" "$hook_exceeded"

# --- Step 3: Remove SOURCE_DELAY so the replica can catch up ---
echo "  Removing SOURCE_DELAY on mysql-replica1..."
mysql_exec mysql-replica1 "
  STOP REPLICA;
  CHANGE REPLICATION SOURCE TO SOURCE_DELAY=0;
  START REPLICA;
"

# --- Step 4: Verify cluster returns to Healthy ---
echo "  Waiting for replica to catch up and cluster to return to Healthy..."
wait_for_health "Healthy" 60

# --- Step 4b: Verify on_lag_threshold_recovered hook fired with PUREMYHA_NODE ---
echo "  Waiting for on_lag_threshold_recovered hook to fire..."
hook_recovered=""
for i in $(seq 1 30); do
  hook_recovered=$($COMPOSE exec -T puremyhad cat /tmp/hook_lag_recovered.log 2>/dev/null || echo "")
  [ -n "$hook_recovered" ] && break
  sleep 1
done
echo "  lag_recovered hook log: $hook_recovered"
assert_not_empty "on_lag_threshold_recovered hook fired" "$hook_recovered"
assert_contains "PUREMYHA_NODE is mysql-replica1" "NODE=mysql-replica1" "$hook_recovered"

echo "  Cleaning up test database..."
mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_lag_test;"

test_summary
echo "=== Test 18 PASSED ==="
