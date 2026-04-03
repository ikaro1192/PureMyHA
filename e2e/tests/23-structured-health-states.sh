#!/usr/bin/env bash
# Test: Structured NodeHealth states via topology endpoint
# Verifies that the new structured health constructors (ReplicaIOStopped,
# ReplicaSQLStopped, ErrantGtidDetected) are correctly exposed through
# the CLI topology and HTTP topology endpoints.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 23: Structured health states ==="

wait_for_health "Healthy" 60

# Pause auto-failover to prevent failover during health state manipulation
cli_pause_failover >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Step 1: ReplicaIOStopped — stop replica IO thread on mysql-replica1
# ---------------------------------------------------------------------------
echo "  Stopping IO thread on mysql-replica1..."
mysql_exec mysql-replica1 "STOP REPLICA IO_THREAD;"

echo "  Waiting for mysql-replica1 health to show ReplicaIOStopped..."
replica1_health=""
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if echo "$replica1_health" | grep -q "ReplicaIOStopped"; then
    echo "  mysql-replica1 health is ReplicaIOStopped (${i}s)"
    break
  fi
  sleep 1
done
assert_contains "mysql-replica1 shows ReplicaIOStopped" "ReplicaIOStopped" "$replica1_health"

# Verify via HTTP topology endpoint as well
http_topo=$(http_get_body "/cluster/e2e/topology")
http_replica1_health=$(echo "$http_topo" | jq -r '.nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
assert_contains "HTTP topology shows ReplicaIOStopped" "ReplicaIOStopped" "$http_replica1_health"

# Restore IO thread
echo "  Restarting IO thread on mysql-replica1..."
mysql_exec mysql-replica1 "START REPLICA IO_THREAD;"

# Wait for recovery
echo "  Waiting for mysql-replica1 to recover..."
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if [ "$replica1_health" = "Healthy" ]; then
    echo "  mysql-replica1 recovered to Healthy (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "mysql-replica1 recovers to Healthy after IO restart" "Healthy" "$replica1_health"

# ---------------------------------------------------------------------------
# Step 2: ReplicaSQLStopped — stop replica SQL thread on mysql-replica2
# ---------------------------------------------------------------------------
echo "  Stopping SQL thread on mysql-replica2..."
mysql_exec mysql-replica2 "STOP REPLICA SQL_THREAD;"

echo "  Waiting for mysql-replica2 health to show ReplicaSQLStopped..."
replica2_health=""
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica2_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica2") | .health' 2>/dev/null || echo "")
  if echo "$replica2_health" | grep -q "ReplicaSQLStopped"; then
    echo "  mysql-replica2 health is ReplicaSQLStopped (${i}s)"
    break
  fi
  sleep 1
done
assert_contains "mysql-replica2 shows ReplicaSQLStopped" "ReplicaSQLStopped" "$replica2_health"

# Restore SQL thread
echo "  Restarting SQL thread on mysql-replica2..."
mysql_exec mysql-replica2 "START REPLICA SQL_THREAD;"

echo "  Waiting for mysql-replica2 to recover..."
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica2_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica2") | .health' 2>/dev/null || echo "")
  if [ "$replica2_health" = "Healthy" ]; then
    echo "  mysql-replica2 recovered to Healthy (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "mysql-replica2 recovers to Healthy after SQL restart" "Healthy" "$replica2_health"

# ---------------------------------------------------------------------------
# Step 3: ErrantGtidDetected — inject errant GTID on mysql-replica1
# ---------------------------------------------------------------------------
echo "  Injecting errant GTID on mysql-replica1..."
mysql_exec mysql-replica1 "
  SET GLOBAL read_only = OFF;
  SET GTID_NEXT = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb:1';
  BEGIN; COMMIT;
  SET GTID_NEXT = 'AUTOMATIC';
  SET GLOBAL read_only = ON;
"

echo "  Waiting for mysql-replica1 health to show ErrantGtidDetected..."
replica1_health=""
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if echo "$replica1_health" | grep -q "ErrantGtidDetected"; then
    echo "  mysql-replica1 health is ErrantGtidDetected (${i}s)"
    break
  fi
  sleep 1
done
assert_contains "mysql-replica1 shows ErrantGtidDetected" "ErrantGtidDetected" "$replica1_health"

# Fix errant GTIDs so cleanup succeeds
echo "  Fixing errant GTIDs..."
fix_result=$(cli_fix_errant_gtid)
echo "  Fix response: $fix_result"
fix_success=$(echo "$fix_result" | jq -r '.success // empty')
assert_contains "fix-errant-gtid returns success" "fixed" "$fix_success"

echo "  Waiting for errant GTIDs to clear..."
for i in $(seq 1 20); do
  errant_after=$(cli_errant_gtid | jq '. | length')
  if [ "$errant_after" -eq 0 ]; then
    echo "  Errant GTIDs cleared (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "Errant GTIDs cleared after fix" "0" "$(cli_errant_gtid | jq '. | length')"

echo "  Waiting for mysql-replica1 to recover to Healthy..."
replica1_health=""
for i in $(seq 1 30); do
  topo_json=$(cli_topology 2>/dev/null || echo "[]")
  replica1_health=$(echo "$topo_json" | jq -r '.[0].nodes[] | select(.host=="mysql-replica1") | .health' 2>/dev/null || echo "")
  if [ "$replica1_health" = "Healthy" ]; then
    echo "  mysql-replica1 recovered to Healthy (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "mysql-replica1 recovers after errant GTID fix" "Healthy" "$replica1_health"

# Resume failover for cleanup
cli_resume_failover >/dev/null 2>&1

# Verify overall cluster health
wait_for_health "Healthy" 30

test_summary
echo "=== Test 23 PASSED ==="
