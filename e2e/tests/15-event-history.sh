#!/usr/bin/env bash
# Test: Event History
# Verifies the in-memory event history buffer records events for key operations
# and that the CLI returns them correctly with filtering and limiting.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 14: Event History ==="

wait_for_health "Healthy" 60

# ---------------------------------------------------------------------------
# 1. Buffer has events after initial startup (health transitions during
#    topology discovery are recorded when nodes first come online).
# ---------------------------------------------------------------------------
echo "  [1] Checking events are recorded after startup..."
resp=$(ipc_event_history)
event_count=$(echo "$resp" | jq '.data | length')
assert_neq "Event buffer is not empty after startup" "0" "$event_count"

# ---------------------------------------------------------------------------
# 2. Each event has the required fields.
# ---------------------------------------------------------------------------
echo "  [2] Checking event structure..."
first_ts=$(echo "$resp" | jq -r '.data[0].timestamp // empty')
first_cluster=$(echo "$resp" | jq -r '.data[0].cluster // empty')
first_type=$(echo "$resp" | jq -r '.data[0].type // empty')
first_details=$(echo "$resp" | jq -r '.data[0].details // empty')
assert_not_empty "Event has timestamp"    "$first_ts"
assert_not_empty "Event has cluster name" "$first_cluster"
assert_not_empty "Event has type"         "$first_type"
assert_not_empty "Event has details"      "$first_details"

# ---------------------------------------------------------------------------
# 3. limit parameter restricts the count.
# ---------------------------------------------------------------------------
echo "  [3] Checking limit parameter..."
resp_1=$(ipc_event_history_limit 1)
count_1=$(echo "$resp_1" | jq '.data | length')
assert_eq "limit=1 returns exactly 1 event" "1" "$count_1"

# ---------------------------------------------------------------------------
# 4. SIGHUP generates a ConfigReloaded event.
# ---------------------------------------------------------------------------
echo "  [4] Sending SIGHUP to trigger config reload..."
$COMPOSE exec -T puremyhad sh -c 'kill -HUP $(pidof puremyhad)'
sleep 2

resp=$(ipc_event_history)
config_reloaded=$(echo "$resp" | jq '[.data[] | select(.type == "ConfigReloaded")] | length')
assert_neq "ConfigReloaded event recorded after SIGHUP" "0" "$config_reloaded"

# ---------------------------------------------------------------------------
# 5. Switchover generates a SwitchoverCompleted event that names the new source.
# ---------------------------------------------------------------------------
echo "  [5] Running switchover to generate SwitchoverCompleted event..."
ipc_switchover "mysql-replica1" "false" >/dev/null
wait_for_source "mysql-replica1" 30

resp=$(ipc_event_history)
switchover_count=$(echo "$resp" | jq '[.data[] | select(.type == "SwitchoverCompleted")] | length')
assert_neq "SwitchoverCompleted event recorded after switchover" "0" "$switchover_count"

promoted_node=$(echo "$resp" | jq -r '[.data[] | select(.type == "SwitchoverCompleted")][0].node // empty')
assert_eq "SwitchoverCompleted event references promoted node" "mysql-replica1" "$promoted_node"

# ---------------------------------------------------------------------------
# 6. Cluster filter returns only events for the matching cluster name;
#    a nonexistent cluster returns an empty list.
# ---------------------------------------------------------------------------
echo "  [6] Checking cluster filter..."
resp_e2e=$(ipc_event_history_cluster "e2e")
e2e_count=$(echo "$resp_e2e" | jq '.data | length')
assert_neq "Cluster filter for 'e2e' returns events" "0" "$e2e_count"

resp_none=$(ipc_event_history_cluster "nonexistent-cluster")
none_count=$(echo "$resp_none" | jq '.data | length')
assert_eq "Cluster filter for nonexistent cluster returns 0 events" "0" "$none_count"

# ---------------------------------------------------------------------------
# 7. Auto-failover generates FailoverStarted and FailoverCompleted events.
#    The current source is mysql-replica1 (promoted in step 5).
#    Stopping it leaves mysql-replica2 as the only remaining replica.
# ---------------------------------------------------------------------------
echo "  [7] Stopping mysql-replica1 (current source) to trigger auto-failover..."
$COMPOSE stop mysql-replica1
wait_for_health "Healthy" 60

resp=$(ipc_event_history)
failover_started=$(echo "$resp"   | jq '[.data[] | select(.type == "FailoverStarted")]   | length')
failover_completed=$(echo "$resp" | jq '[.data[] | select(.type == "FailoverCompleted")] | length')
assert_neq "FailoverStarted event recorded after auto-failover"   "0" "$failover_started"
assert_neq "FailoverCompleted event recorded after auto-failover" "0" "$failover_completed"

# The node field in FailoverCompleted names the newly promoted host.
new_source=$(get_source_host)
promoted_in_event=$(echo "$resp" | jq -r '[.data[] | select(.type == "FailoverCompleted")][0].node // empty')
assert_eq "FailoverCompleted event references the new source host" "$new_source" "$promoted_in_event"

test_summary
