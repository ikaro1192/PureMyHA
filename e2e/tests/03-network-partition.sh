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

# docker pause sends SIGSTOP — TCP connections freeze (no RST/FIN).
# On macOS, the OS-level TCP retransmit timeout is very long (minutes),
# so PureMyHA may not detect the source as unreachable within a reasonable time.
# The key assertion here is: even after waiting, no auto-failover should have occurred.
# We wait long enough for several monitoring cycles to pass.
echo "  Waiting 15s to allow monitoring cycles..."
sleep 15

health=$(get_health)
echo "  Health after pause: $health"

# Whether or not the daemon detected the partition, it must NOT be DeadSource
# (docker pause keeps TCP alive, so replicas still show IO=Yes → no DeadSource)
assert_neq "Health is not DeadSource (no failover triggered)" "DeadSource" "$health"

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
