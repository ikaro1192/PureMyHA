#!/usr/bin/env bash
# Test: Probe Timeout (frozen source → auto-failover)
# Pauses the source container (SIGSTOP — kernel TCP alive, MySQL process frozen)
# and verifies that probe timeouts eventually trigger auto-failover.
#
# docker pause keeps the kernel TCP stack alive, so new TCP connections succeed
# at the OS level but MySQL never responds to queries.  Without a probe timeout
# the monitoring thread would hang forever; with the fix it fires after
# connect_timeout × (2 × connect_retries + 1) = 6s per probe (E2E defaults).
# After consecutive_failures_for_dead (3) timeouts the source is marked Dead
# and auto-failover triggers once replicas also detect IO=No.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 21: Probe Timeout (frozen source -> auto-failover) ==="

wait_for_health "Healthy" 60

orig_source=$(get_source_host)
echo "  Original source: $orig_source"
assert_eq "Original source is mysql-source" "mysql-source" "$orig_source"

# Shorten replica_net_timeout so the IO thread detects the frozen source
# within ~10s instead of the default 60s, keeping the overall test time short.
echo "  Setting replica_net_timeout=10 on replicas..."
mysql_exec mysql-replica1 "SET GLOBAL replica_net_timeout = 10;"
mysql_exec mysql-replica2 "SET GLOBAL replica_net_timeout = 10;"

# Pause the source (SIGSTOP).  TCP connections succeed at kernel level but
# the MySQL process is frozen, so every probe times out.
echo "  Pausing mysql-source (simulating frozen process)..."
docker pause e2e-source

# Expected timeline after pause:
#   probe 1 timeout:  6s  → failCount=1 (suppressed below threshold=3)
#   probe 2 timeout: +7s  → failCount=2 (still suppressed)
#   replica IO detects no heartbeat: ~10s (replica_net_timeout=10)
#   probe 3 timeout: +7s  → failCount=3 → NeedsAttention fires
#   detectClusterHealth: source=NeedsAttention + replicas IO=No → DeadSource
#   auto-failover executes (wait_for_relay_log_apply_timeout=10s) → ~10s
#   total: ~40s; wait up to 90s for safety
#
# Wait directly for the source to switch to mysql-replica1.
# Using wait_for_source rather than a two-phase health check avoids a race
# where the DeadSource→Healthy transition completes within one polling interval
# (e.g., when docker pause causes immediate TCP RST on Docker Desktop) and the
# "not Healthy" window is missed entirely.
echo "  Waiting for failover to complete (new source = mysql-replica1)..."
wait_for_source "mysql-replica1" 90

new_source=$(get_source_host)
echo "  New source after failover: $new_source"
assert_eq "New source is mysql-replica1 (candidate_priority)" "mysql-replica1" "$new_source"

# Restore replica_net_timeout to MySQL default before reset_cluster runs
echo "  Restoring replica_net_timeout=60 on replicas..."
mysql_exec mysql-replica1 "SET GLOBAL replica_net_timeout = 60;" || true
mysql_exec mysql-replica2 "SET GLOBAL replica_net_timeout = 60;" || true

# Unpause so that reset_cluster can bring the cluster back to its original state
echo "  Unpausing mysql-source..."
docker unpause e2e-source

test_summary
