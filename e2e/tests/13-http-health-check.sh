#!/usr/bin/env bash
# Test: HTTP Health Check Endpoint
# Verifies that the HTTP server exposes /health, /cluster/:name/status,
# and /cluster/:name/topology endpoints with correct status codes and JSON.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 13: HTTP Health Check ==="

wait_for_health "Healthy" 60

# GET /health returns 200 when cluster is Healthy
status=$(http_get "/health")
assert_eq "GET /health returns 200" "200" "$status"

body=$(http_get_body "/health")
health_status=$(echo "$body" | jq -r '.status')
assert_eq "/health body has status=ok" "ok" "$health_status"

# GET /cluster/e2e/status returns 200 with ClusterStatus JSON
status=$(http_get "/cluster/e2e/status")
assert_eq "GET /cluster/e2e/status returns 200" "200" "$status"

body=$(http_get_body "/cluster/e2e/status")
cluster_health=$(echo "$body" | jq -r '.health')
assert_eq "Cluster health is Healthy" "Healthy" "$cluster_health"

source_host=$(echo "$body" | jq -r '.sourceHost')
assert_eq "Source host is mysql-source" "mysql-source" "$source_host"

node_count=$(echo "$body" | jq -r '.nodeCount')
assert_eq "Node count is 3" "3" "$node_count"

# GET /cluster/e2e/topology returns 200 with ClusterTopologyView JSON
status=$(http_get "/cluster/e2e/topology")
assert_eq "GET /cluster/e2e/topology returns 200" "200" "$status"

body=$(http_get_body "/cluster/e2e/topology")
topo_node_count=$(echo "$body" | jq '.nodes | length')
assert_eq "Topology has 3 nodes" "3" "$topo_node_count"

source_count=$(echo "$body" | jq '[.nodes[] | select(.isSource==true)] | length')
assert_eq "Exactly 1 source in topology" "1" "$source_count"

# Non-existent cluster returns 404
status=$(http_get "/cluster/does-not-exist/status")
assert_eq "Unknown cluster /status returns 404" "404" "$status"

status=$(http_get "/cluster/does-not-exist/topology")
assert_eq "Unknown cluster /topology returns 404" "404" "$status"

# Unknown route returns 404
status=$(http_get "/nonexistent")
assert_eq "Unknown route returns 404" "404" "$status"

# POST returns 405
status=$($COMPOSE exec -T puremyhad curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:8080/health")
assert_eq "POST /health returns 405" "405" "$status"

# GET /health returns 200 even when source is dead (liveness probe — daemon is still running)
# Pause auto-failover so health stays degraded long enough to observe
cli_pause_failover >/dev/null 2>&1
$COMPOSE stop mysql-source
wait_for_health "DeadSource" 30

status=$(http_get "/health")
assert_eq "GET /health returns 200 even when cluster degraded" "200" "$status"

body=$(http_get_body "/health")
degraded_status=$(echo "$body" | jq -r '.status')
assert_eq "/health body has status=ok even when cluster degraded" "ok" "$degraded_status"

# Cluster status reflects the degraded state
cluster_status=$(http_get_body "/cluster/e2e/status")
cluster_health=$(echo "$cluster_status" | jq -r '.health')
assert_eq "Cluster status reflects DeadSource" "DeadSource" "$cluster_health"

# Restore for cleanup
$COMPOSE start mysql-source
cli_resume_failover >/dev/null 2>&1

test_summary
