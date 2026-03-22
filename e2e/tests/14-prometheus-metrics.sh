#!/usr/bin/env bash
# Test: Prometheus Metrics Endpoint
# Verifies that GET /metrics returns Prometheus text format with correct
# metric families, labels, and values under healthy and degraded conditions.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 14: Prometheus Metrics ==="

wait_for_health "Healthy" 60

# GET /metrics returns 200
status=$(http_get "/metrics")
assert_eq "GET /metrics returns 200" "200" "$status"

# Content-Type is Prometheus text/plain (use GET, not HEAD, since only GET is allowed)
ct=$($COMPOSE exec -T puremyhad curl -s -D - -o /dev/null "http://127.0.0.1:8080/metrics" \
  | grep -i "^content-type:" | tr -d '\r')
assert_contains "Content-Type is text/plain" "text/plain" "$ct"

body=$(http_get_body "/metrics")

# Each metric family HELP/TYPE header appears exactly once
help_count=$(echo "$body" | grep -c "^# HELP puremyha_cluster_healthy" || true)
assert_eq "HELP puremyha_cluster_healthy appears exactly once" "1" "$help_count"

type_count=$(echo "$body" | grep -c "^# TYPE puremyha_cluster_healthy gauge" || true)
assert_eq "TYPE puremyha_cluster_healthy appears exactly once" "1" "$type_count"

help_node_count=$(echo "$body" | grep -c "^# HELP puremyha_node_healthy" || true)
assert_eq "HELP puremyha_node_healthy appears exactly once" "1" "$help_node_count"

# Healthy cluster metrics
assert_contains "cluster_healthy=1 when Healthy" \
  'puremyha_cluster_healthy{cluster="e2e"} 1' "$body"

assert_contains "cluster_paused=0 by default" \
  'puremyha_cluster_paused{cluster="e2e"} 0' "$body"

# Source node is marked as source
assert_contains "mysql-source is_source=1" \
  'puremyha_node_is_source{cluster="e2e",host="mysql-source",port="3306"} 1' "$body"

# Replica nodes are marked as not source
assert_contains "mysql-replica1 is_source=0" \
  'puremyha_node_is_source{cluster="e2e",host="mysql-replica1",port="3306"} 0' "$body"

assert_contains "mysql-replica2 is_source=0" \
  'puremyha_node_is_source{cluster="e2e",host="mysql-replica2",port="3306"} 0' "$body"

# Replication lag metrics are present for all nodes
assert_contains "replication_lag_seconds present for mysql-source" \
  'puremyha_node_replication_lag_seconds{cluster="e2e",host="mysql-source"' "$body"

assert_contains "replication_lag_seconds present for mysql-replica1" \
  'puremyha_node_replication_lag_seconds{cluster="e2e",host="mysql-replica1"' "$body"

# Consecutive failures are 0 for healthy nodes
assert_contains "consecutive_failures=0 for mysql-source" \
  'puremyha_node_consecutive_failures{cluster="e2e",host="mysql-source",port="3306"} 0' "$body"

# Degraded state: stop source and verify cluster_healthy becomes 0
ipc_pause_failover >/dev/null 2>&1
$COMPOSE stop mysql-source
wait_for_health_not "Healthy" 30

body=$(http_get_body "/metrics")
assert_contains "cluster_healthy=0 when degraded" \
  'puremyha_cluster_healthy{cluster="e2e"} 0' "$body"

# Restore
$COMPOSE start mysql-source
ipc_resume_failover >/dev/null 2>&1

test_summary
