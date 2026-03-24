#!/usr/bin/env bash
# Test: Pause/Resume Failover
# Verifies that pause-failover prevents auto-failover and resume-failover re-enables it.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 10: Pause/Resume Failover ==="

wait_for_health "Healthy" 60

# 1. Verify cluster is healthy with expected source
orig_source=$(get_source_host)
echo "  Original source: $orig_source"
assert_eq "Original source is mysql-source" "mysql-source" "$orig_source"

# 2. Pause failover
echo "  Sending pause-failover..."
pause_result=$(cli_pause_failover)
pause_success=$(echo "$pause_result" | jq -r '.success // empty')
assert_eq "Pause failover succeeds" "Failover paused" "$pause_success"

# 3. Verify paused=true in status
paused=$(get_paused)
assert_eq "Cluster is paused" "true" "$paused"

# 4. Kill the source
echo "  Stopping mysql-source..."
$COMPOSE stop mysql-source

# 5. Wait for DeadSource detection, then verify failover does NOT happen
wait_for_health "DeadSource" 60

echo "  Waiting 15s to confirm failover is blocked..."
sleep 15

health_after=$(get_health)
source_after=$(get_source_host)
assert_eq "Health still DeadSource (failover blocked)" "DeadSource" "$health_after"
assert_eq "Source unchanged (failover blocked)" "$orig_source" "$source_after"

# 6. Resume failover
echo "  Sending resume-failover..."
resume_result=$(cli_resume_failover)
resume_success=$(echo "$resume_result" | jq -r '.success // empty')
assert_eq "Resume failover succeeds" "Failover resumed" "$resume_success"

# 7. Wait for failover to complete
echo "  Waiting for auto-failover after resume..."
wait_for_health "Healthy" 60

# 8. Verify new source
new_source=$(get_source_host)
echo "  New source after failover: $new_source"
assert_neq "Source changed from original" "$orig_source" "$new_source"
assert_eq "New source is mysql-replica1" "mysql-replica1" "$new_source"

test_summary
