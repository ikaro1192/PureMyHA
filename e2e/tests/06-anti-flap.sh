#!/usr/bin/env bash
# Test: Anti-Flap Recovery Block
# Triggers a failover, verifies the recovery block is set, and tests ack-recovery.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 06: Anti-Flap Recovery Block ==="

wait_for_health "Healthy" 60

# Verify no recovery block initially
recovery_blocked=$(get_recovery_blocked)
assert_eq "No recovery block initially" "null" "$recovery_blocked"

# Kill source to trigger failover
echo "  Stopping mysql-source to trigger failover..."
$COMPOSE stop mysql-source

# Wait for failover to complete (90s: failover + promotion + daemon re-probe)
wait_for_health "Healthy" 90

# Verify recovery block is set
recovery_blocked=$(get_recovery_blocked)
echo "  Recovery blocked until: $recovery_blocked"
assert_neq "Recovery block is set after failover" "null" "$recovery_blocked"

# Acknowledge recovery to clear the block
echo "  Sending ack-recovery..."
ack_result=$(cli_ack_recovery)
echo "  Ack response: $ack_result"
ack_success=$(echo "$ack_result" | jq -r '.success // empty')
assert_eq "Ack recovery succeeds" "Recovery block cleared" "$ack_success"

# Verify block is cleared
recovery_blocked_after=$(get_recovery_blocked)
assert_eq "Recovery block cleared" "null" "$recovery_blocked_after"

test_summary
