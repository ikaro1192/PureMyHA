#!/usr/bin/env bash
# Test: IPC Unix domain socket permissions
# Verifies that /run/puremyhad.sock is created with mode 0600 so that
# only the daemon's UID can issue privileged IPC control requests.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 27: IPC Socket Permissions ==="

wait_for_health "Healthy" 60

# Socket file must exist inside the daemon container
exists=$($COMPOSE exec -T puremyhad sh -c '[ -S /run/puremyhad.sock ] && echo yes || echo no')
assert_eq "IPC socket file exists" "yes" "$exists"

# Mode must be 0600 (owner read/write only)
mode=$($COMPOSE exec -T puremyhad stat -c '%a' /run/puremyhad.sock | tr -d '\r')
assert_eq "IPC socket mode is 0600" "600" "$mode"

# Ownership expected to be root:root under the default e2e container
owner=$($COMPOSE exec -T puremyhad stat -c '%U:%G' /run/puremyhad.sock | tr -d '\r')
assert_eq "IPC socket owner is root:root" "root:root" "$owner"

test_summary
