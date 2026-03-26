#!/usr/bin/env bash
# Test: Manual Switchover
# Tests dry-run and real switchover via puremyha CLI.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 04: Manual Switchover ==="

wait_for_health "Healthy" 60

orig_source=$(get_source_host)
echo "  Original source: $orig_source"

# --- Dry-run switchover ---
echo "  Testing dry-run switchover to mysql-replica2..."
dry_result=$(cli_switchover "mysql-replica2" "true")
echo "  Dry-run response: $dry_result"

# Verify dry-run reports success
dry_success=$(echo "$dry_result" | jq -r '.success // empty')
assert_contains "Dry-run returns success message" "Dry run" "$dry_success"

# Source should be unchanged after dry-run
current_source=$(get_source_host)
assert_eq "Source unchanged after dry-run" "$orig_source" "$current_source"

# --- Real switchover ---
echo "  Executing switchover to mysql-replica2..."
switch_result=$(cli_switchover "mysql-replica2" "false")
echo "  Switchover response: $switch_result"

switch_success=$(echo "$switch_result" | jq -r '.success // empty')
assert_contains "Switchover returns success" "Switchover completed" "$switch_success"

# Wait for topology to settle
sleep 3

# Verify new source
new_source=$(get_source_host)
echo "  New source: $new_source"
assert_eq "Source changed to mysql-replica2" "mysql-replica2" "$new_source"

# Verify cluster is healthy after switchover
wait_for_health "Healthy" 30
health=$(get_health)
assert_eq "Cluster healthy after switchover" "Healthy" "$health"

test_summary
