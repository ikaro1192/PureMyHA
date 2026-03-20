#!/usr/bin/env bash
# Test: Topology Discovery
# Verifies that puremyhad correctly discovers all nodes and identifies source/replica roles.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 01: Topology Discovery ==="

wait_for_health "Healthy" 60

# Check status
health=$(get_health)
assert_eq "Cluster is Healthy" "Healthy" "$health"

node_count=$(get_node_count)
assert_eq "3 nodes discovered" "3" "$node_count"

source_host=$(get_source_host)
assert_eq "Source is mysql-source" "mysql-source" "$source_host"

# Check topology details
topo=$(ipc_topology)
topo_node_count=$(echo "$topo" | jq '.data[0].nodes | length')
assert_eq "Topology shows 3 nodes" "3" "$topo_node_count"

source_count=$(echo "$topo" | jq '[.data[0].nodes[] | select(.isSource==true)] | length')
assert_eq "Exactly 1 source" "1" "$source_count"

replica_count=$(echo "$topo" | jq '[.data[0].nodes[] | select(.isSource==false)] | length')
assert_eq "Exactly 2 replicas" "2" "$replica_count"

# Verify no connect errors on any node
error_count=$(echo "$topo" | jq '[.data[0].nodes[] | select(.connectError!=null)] | length')
assert_eq "No connection errors" "0" "$error_count"

# Verify no errant GTIDs
errant_count=$(echo "$topo" | jq '[.data[0].nodes[] | select(.errantGtids!="" and .errantGtids!=null)] | length')
assert_eq "No errant GTIDs" "0" "$errant_count"

test_summary
