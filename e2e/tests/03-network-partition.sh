#!/usr/bin/env bash
# Test: Network Partition (UnreachableSource)
# Pauses the source container (simulating network partition) and verifies
# that puremyhad does NOT trigger auto-failover.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 03: Network Partition ==="

wait_for_health "Healthy" 60

orig_source=$(get_source_host)
echo "  Original source: $orig_source"

# Pause the source (SIGSTOP - TCP connections stay open but unresponsive)
echo "  Pausing mysql-source (simulating network partition)..."
docker pause e2e-source

# Wait for daemon to detect the issue
# With 1s monitor interval + 2s connect timeout, detection takes ~3-5s
sleep 8

# Health should be UnreachableSource or NeedsAttention, NOT DeadSource
# (Because replicas may still show IO=Yes briefly - the connection hasn't been RST)
health=$(get_health)
echo "  Health after pause: $health"

# The source should NOT have changed (no failover occurred)
current_source=$(get_source_host)
assert_eq "Source unchanged (no failover)" "$orig_source" "$current_source"

# Unpause to restore
echo "  Unpausing mysql-source..."
docker unpause e2e-source

# Wait for recovery
wait_for_health "Healthy" 60

final_source=$(get_source_host)
assert_eq "Source still original after recovery" "$orig_source" "$final_source"

test_summary
