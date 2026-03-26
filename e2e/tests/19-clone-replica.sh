#!/usr/bin/env bash
# Test: MySQL CLONE plugin support for replica re-seeding
# Verifies that `puremyha clone` correctly:
#   1. Clones a replica from an explicit donor
#   2. Auto-selects the best donor when --donor is omitted
#   3. Rejects cloning onto the primary node (safety guard)
#   4. Rejects cloning when the CLONE plugin is not active on recipient
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 19: MySQL CLONE plugin support ==="

wait_for_health "Healthy" 60

# --- Setup: Install CLONE plugin on donor (mysql-replica2) and recipient (mysql-replica1) ---
echo "  Installing CLONE plugin on donor and recipient nodes..."
mysql_exec mysql-replica2 "INSTALL PLUGIN clone SONAME 'mysql_clone.so';" 2>/dev/null || true
mysql_exec mysql-replica1 "INSTALL PLUGIN clone SONAME 'mysql_clone.so';" 2>/dev/null || true

# Verify CLONE plugin is ACTIVE on both nodes
replica2_clone=$(mysql_exec mysql-replica2 "SELECT PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME='clone';" 2>/dev/null || echo "")
replica1_clone=$(mysql_exec mysql-replica1 "SELECT PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME='clone';" 2>/dev/null || echo "")

if [ -z "$replica2_clone" ] || [ -z "$replica1_clone" ]; then
  echo "  NOTE: CLONE plugin unavailable in this environment — skipping CLONE execution tests"
  CLONE_AVAILABLE=false
else
  echo "  CLONE plugin status: donor=$replica2_clone, recipient=$replica1_clone"
  CLONE_AVAILABLE=true
fi

# --- Scenario 1: Safety guard — cloning onto primary should fail ---
echo "  Scenario 1: Safety guard — refuse to clone onto primary node..."
source_host=$(cli_exec status | jq -r '.[0].sourceHost' 2>/dev/null || echo "mysql-source")
output=$(cli_exec clone --recipient "$source_host" 2>&1 || true)
assert_contains "clone onto primary is rejected" "Cannot clone onto primary node" "$output"

# --- Scenario 2: CLONE plugin prerequisite check ---
echo "  Scenario 2: CLONE plugin not active on recipient should fail..."
# Temporarily uninstall CLONE plugin on replica1 to simulate missing plugin
mysql_exec mysql-replica1 "UNINSTALL PLUGIN clone;" 2>/dev/null || true
output=$(cli_exec clone --recipient mysql-replica1 --donor mysql-replica2 2>&1 || true)
assert_contains "missing CLONE plugin on recipient is rejected" "CLONE plugin is not active" "$output"

# Reinstall for subsequent tests
mysql_exec mysql-replica1 "INSTALL PLUGIN clone SONAME 'mysql_clone.so';" 2>/dev/null || true

# --- Scenario 3 & 4: Actual CLONE execution (only if plugin is available) ---
if [ "$CLONE_AVAILABLE" = "true" ]; then
  # Scenario 3: Explicit donor clone
  echo "  Scenario 3: Clone mysql-replica1 from explicit donor mysql-replica2..."
  # Write some data to source so replica2 has data to clone
  mysql_exec mysql-source "CREATE DATABASE IF NOT EXISTS e2e_clone_test;"
  mysql_exec mysql-source "CREATE TABLE IF NOT EXISTS e2e_clone_test.t1 (id INT PRIMARY KEY);"
  mysql_exec mysql-source "INSERT INTO e2e_clone_test.t1 VALUES (1),(2),(3);"
  # Wait for replica2 to catch up
  wait_for_replication mysql-replica2 30

  output=$(cli_exec clone --recipient mysql-replica1 --donor mysql-replica2 2>&1 || true)
  assert_contains "explicit donor clone reports success" "Clone completed" "$output"

  # Wait for mysql-replica1 to restart after CLONE and reconnect to source
  wait_for_mysql mysql-replica1 60
  wait_for_replication mysql-replica1 60
  echo "  mysql-replica1 replication re-established after clone"

  # Scenario 4: Auto-select donor (omit --donor flag)
  echo "  Scenario 4: Clone mysql-replica1 with auto-selected donor..."
  output=$(cli_exec clone --recipient mysql-replica1 2>&1 || true)
  assert_contains "auto-donor clone reports success" "Clone completed" "$output"

  # Wait for replica to recover again
  wait_for_mysql mysql-replica1 60
  wait_for_replication mysql-replica1 60
  echo "  mysql-replica1 replication re-established after auto-donor clone"

  # Cleanup
  mysql_exec mysql-source "DROP DATABASE IF EXISTS e2e_clone_test;" || true
else
  echo "  NOTE: Skipping actual CLONE execution tests (plugin not available)"
fi

# --- Final: Cluster should return to Healthy state ---
echo "  Waiting for cluster to stabilise to Healthy..."
wait_for_health "Healthy" 60

echo "=== Test 19 PASSED ==="
test_summary
