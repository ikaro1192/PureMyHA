#!/usr/bin/env bash
# Test: dry-run for fix-errant-gtid, demote, and simulate-failover
# Verifies that dry-run commands preview operations without executing them.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 24: dry-run and simulate-failover ==="

wait_for_health "Healthy" 60

# ---------------------------------------------------------------------------
# 1. fix-errant-gtid --dry-run: preview with no actual errant GTIDs
# ---------------------------------------------------------------------------
echo "  Testing fix-errant-gtid --dry-run with no errant GTIDs..."
dry_result=$(cli_fix_errant_gtid_dry)
echo "  Dry-run fix-errant-gtid response: $dry_result"

dry_success=$(echo "$dry_result" | jq -r '.success // empty')
assert_contains "dry-run fix-errant-gtid returns no-op message" "no errant GTIDs" "$dry_success"

# ---------------------------------------------------------------------------
# 2. fix-errant-gtid --dry-run: preview with an injected errant GTID
# ---------------------------------------------------------------------------
echo "  Injecting errant GTID on mysql-replica1..."
mysql_exec mysql-replica1 "
  SET GLOBAL read_only = OFF;
  SET GTID_NEXT = 'cccccccc-cccc-cccc-cccc-cccccccccccc:1';
  BEGIN; COMMIT;
  SET GTID_NEXT = 'AUTOMATIC';
  SET GLOBAL read_only = ON;
"

echo "  Waiting for errant GTID detection..."
for i in $(seq 1 20); do
  errant_count=$(cli_errant_gtid | jq '. | length')
  if [ "$errant_count" -ge 1 ]; then
    echo "  Errant GTID detected (${i}s)"
    break
  fi
  sleep 1
done

errant_count=$(cli_errant_gtid | jq '. | length')
assert_eq "Errant GTID detected before dry-run" "1" "$errant_count"

echo "  Testing fix-errant-gtid --dry-run with errant GTIDs present..."
dry_result2=$(cli_fix_errant_gtid_dry)
echo "  Dry-run fix-errant-gtid (with GTIDs) response: $dry_result2"

dry_success2=$(echo "$dry_result2" | jq -r '.success // empty')
assert_contains "dry-run shows injection count" "would inject" "$dry_success2"

# Verify source GTID did NOT change (dry-run did not execute)
errant_count_after=$(cli_errant_gtid | jq '. | length')
assert_eq "Errant GTIDs unchanged after dry-run" "1" "$errant_count_after"

# Clean up: actually fix the errant GTIDs for subsequent tests
echo "  Fixing errant GTIDs..."
cli_fix_errant_gtid >/dev/null

for i in $(seq 1 20); do
  errant_after=$(cli_errant_gtid | jq '. | length')
  if [ "$errant_after" -eq 0 ]; then
    echo "  Errant GTIDs cleared (${i}s)"
    break
  fi
  sleep 1
done
assert_eq "Errant GTIDs cleared after fix" "0" "$(cli_errant_gtid | jq '. | length')"

# ---------------------------------------------------------------------------
# 3. demote --dry-run: preview SQL without executing
# ---------------------------------------------------------------------------
echo "  Testing demote --dry-run..."
orig_source=$(get_source_host)
dry_demote_result=$(cli_demote_dry "mysql-replica1" "mysql-source")
echo "  Dry-run demote response: $dry_demote_result"

dry_demote_success=$(echo "$dry_demote_result" | jq -r '.success // empty')
assert_contains "dry-run demote shows STOP REPLICA" "STOP REPLICA" "$dry_demote_success"
assert_contains "dry-run demote shows SET GLOBAL read_only" "SET GLOBAL read_only = ON" "$dry_demote_success"
assert_contains "dry-run demote shows CHANGE REPLICATION SOURCE TO" "CHANGE REPLICATION SOURCE TO" "$dry_demote_success"
assert_contains "dry-run demote shows START REPLICA" "START REPLICA" "$dry_demote_success"

# Verify replication is still running (dry-run did not execute)
current_source=$(get_source_host)
assert_eq "Source unchanged after dry-run demote" "$orig_source" "$current_source"

# ---------------------------------------------------------------------------
# 4. simulate-failover: healthy cluster should report preconditions FAIL
# ---------------------------------------------------------------------------
echo "  Testing simulate-failover on healthy cluster..."
wait_for_health "Healthy" 30

sim_result=$(cli_simulate_failover)
echo "  Simulate-failover (healthy) response: $sim_result"

sim_success=$(echo "$sim_result" | jq -r '.success // empty')
assert_contains "simulate-failover reports preconditions FAIL on healthy cluster" "FAIL" "$sim_success"
assert_contains "simulate-failover shows current health" "Healthy" "$sim_success"

# ---------------------------------------------------------------------------
# 5. simulate-failover: DeadSource state should pick a candidate
#    Pause auto-failover first so the DeadSource state is stable for testing.
# ---------------------------------------------------------------------------
echo "  Pausing auto-failover to hold DeadSource state..."
cli_pause_failover >/dev/null

echo "  Stopping mysql-source to trigger DeadSource..."
$COMPOSE stop mysql-source

echo "  Waiting for DeadSource health..."
wait_for_health "DeadSource" 60

sim_result2=$(cli_simulate_failover)
echo "  Simulate-failover (DeadSource) response: $sim_result2"

sim_success2=$(echo "$sim_result2" | jq -r '.success // empty')
# Structural preconditions pass even when paused; pause is shown as a note
assert_contains "simulate-failover shows candidate on DeadSource" "Would promote" "$sim_success2"
assert_contains "simulate-failover lists eligible candidates" "All eligible candidates" "$sim_success2"
assert_contains "simulate-failover notes pause state" "paused by operator" "$sim_success2"

# ---------------------------------------------------------------------------
# Cleanup: restore cluster to original state
# Start source BEFORE resuming failover so the daemon detects it as reachable
# before auto-failover is re-enabled — otherwise failover fires on the still-dead
# source immediately after resume, leaving the cluster in a different topology
# that confuses reset_cluster's GTID cleanup.
# ---------------------------------------------------------------------------
echo "  Restoring cluster..."
$COMPOSE start mysql-source
wait_for_mysql mysql-source 60 || true
wait_for_health "Healthy" 60 || true
cli_resume_failover >/dev/null || true
reset_cluster

test_summary
