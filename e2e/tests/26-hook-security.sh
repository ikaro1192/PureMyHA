#!/usr/bin/env bash
# Test: Hook Security — world-writable rejection
#
# Verifies that puremyhad refuses to execute a hook script whose mode has the
# world-writable bit set, even when the script is at an absolute path and
# owned by root. A world-writable hook running as root is a trivial local-root
# privilege escalation if an attacker can get file-write access, so the
# daemon must refuse to run it and instead abort the failover.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 26: Hook Security (world-writable rejection) ==="

HOOK_PATH="/opt/puremyha/hooks/pre_failover.sh"

# Restore mode at end to keep subsequent tests happy (the writable layer in
# the puremyhad container persists between tests until `compose down`).
restore_hook() {
  $COMPOSE exec -T puremyhad chmod 0755 "$HOOK_PATH" 2>/dev/null || true
}
trap restore_hook EXIT

wait_for_health "Healthy" 60

# Clear any leftover markers from a prior test
$COMPOSE exec -T puremyhad rm -f /tmp/hook_pre_failover.log /tmp/hook_post_failover.log 2>/dev/null || true

# Confirm the hook is baked in as a regular root-owned script before we mutate it
$COMPOSE exec -T puremyhad test -f "$HOOK_PATH"

# Make the hook world-writable inside the container
$COMPOSE exec -T puremyhad chmod 0666 "$HOOK_PATH"

echo "  Stopping mysql-source to trigger failover with world-writable pre_failover..."
$COMPOSE stop mysql-source

# Give the daemon enough time to detect the dead source and attempt failover.
# consecutive_failures_for_dead defaults to 3 × 1s probe interval + fast
# detector cycles; 15s is comfortably above the worst case.
sleep 15

pre_hook=$($COMPOSE exec -T puremyhad cat /tmp/hook_pre_failover.log 2>/dev/null || echo "")
post_hook=$($COMPOSE exec -T puremyhad cat /tmp/hook_post_failover.log 2>/dev/null || echo "")

# pre_failover must have been rejected before execution
if [ -z "$pre_hook" ]; then
  echo "  PASS: pre_failover marker absent (hook was rejected)"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: pre_failover still ran (marker: $pre_hook)"
  ((FAIL_COUNT++)) || true
fi

# A rejected pre-hook must also prevent the promotion path from firing post_failover
if [ -z "$post_hook" ]; then
  echo "  PASS: post_failover marker absent (failover was aborted)"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: post_failover ran despite pre-hook rejection (marker: $post_hook)"
  ((FAIL_COUNT++)) || true
fi

# Daemon logs should mention the rejection reason. The daemon writes its
# structured log to the file configured in puremyha.yaml (not container
# stdout), so we cat that file from inside the container.
daemon_log=$($COMPOSE exec -T puremyhad cat /var/log/puremyha.log 2>/dev/null || echo "")
assert_contains "Daemon log mentions world-writable rejection" "world-writable" "$daemon_log"

test_summary
