#!/usr/bin/env bash
# Test: Hook Execution
# Triggers a failover and verifies that pre/post failover hooks are executed.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 07: Hook Execution ==="

wait_for_health "Healthy" 60

# Ensure no leftover hook markers
$COMPOSE exec -T puremyhad rm -f /tmp/hook_pre_failover.log /tmp/hook_post_failover.log 2>/dev/null || true

# Kill source to trigger failover (which fires hooks)
echo "  Stopping mysql-source to trigger failover with hooks..."
$COMPOSE stop mysql-source

# Wait for failover to complete
wait_for_health "Healthy" 60

# Give hooks a moment to write their files
sleep 2

# Check hook marker files inside puremyhad container
pre_hook=$($COMPOSE exec -T puremyhad cat /tmp/hook_pre_failover.log 2>/dev/null || echo "")
post_hook=$($COMPOSE exec -T puremyhad cat /tmp/hook_post_failover.log 2>/dev/null || echo "")

echo "  Pre-failover hook log: $pre_hook"
echo "  Post-failover hook log: $post_hook"

assert_not_empty "Pre-failover hook fired" "$pre_hook"
assert_not_empty "Post-failover hook fired" "$post_hook"

test_summary
