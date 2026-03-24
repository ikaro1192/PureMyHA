#!/usr/bin/env bash
# Test: Demote (change a replica's replication source)
# Tests demoting a replica to replicate from a different source via puremyha CLI.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 09: Demote ==="

wait_for_health "Healthy" 60

# --- Step 1: Switchover to mysql-replica1 (make it the new source) ---
echo "  Switching over to mysql-replica1..."
switch_result=$(cli_switchover "mysql-replica1" "false")
echo "  Switchover response: $switch_result"

switch_success=$(echo "$switch_result" | jq -r '.success // empty')
assert_not_empty "Switchover returns success" "$switch_success"

# Wait for topology to settle
sleep 3
wait_for_source "mysql-replica1" 30

# Verify current topology: mysql-replica1 is source
source_host=$(get_source_host)
assert_eq "Source is mysql-replica1" "mysql-replica1" "$source_host"

# --- Step 2: Demote mysql-replica2 to replicate from mysql-replica1 ---
# After switchover, mysql-replica2 should already replicate from mysql-replica1,
# but let's verify the demote command works by explicitly pointing it there.
# First, check current replication source of mysql-replica2 via MySQL
current_repl_source=$(mysql_exec mysql-replica2 "SELECT HOST FROM performance_schema.replication_connection_configuration LIMIT 1;" | tr -d '[:space:]')
echo "  mysql-replica2 current replication source: $current_repl_source"

echo "  Demoting mysql-replica2 to replicate from mysql-replica1..."
demote_result=$(cli_demote "mysql-replica2" "mysql-replica1")
echo "  Demote response: $demote_result"

demote_success=$(echo "$demote_result" | jq -r '.success // empty')
assert_not_empty "Demote returns success message" "$demote_success"

# Wait for replication to re-establish
sleep 5

# Verify mysql-replica2's replication source changed to mysql-replica1
new_repl_source=$(mysql_exec mysql-replica2 "SELECT HOST FROM performance_schema.replication_connection_configuration LIMIT 1;" | tr -d '[:space:]')
echo "  mysql-replica2 new replication source: $new_repl_source"
assert_eq "mysql-replica2 replicates from mysql-replica1" "mysql-replica1" "$new_repl_source"

# --- Step 3: Verify cluster health ---
wait_for_health "Healthy" 30
health=$(get_health)
assert_eq "Cluster healthy after demote" "Healthy" "$health"

# --- Step 4: Verify data flows through the chain ---
echo "  Writing data on new source (mysql-replica1) to verify replication chain..."
mysql_exec mysql-replica1 "CREATE DATABASE IF NOT EXISTS e2e_demote_test;"
mysql_exec mysql-replica1 "CREATE TABLE IF NOT EXISTS e2e_demote_test.t1 (id INT PRIMARY KEY);"
mysql_exec mysql-replica1 "INSERT INTO e2e_demote_test.t1 VALUES (1);"

# Wait for replication
sleep 3

# Verify data reached mysql-replica2 (via mysql-replica1)
count=$(mysql_exec mysql-replica2 "SELECT COUNT(*) FROM e2e_demote_test.t1;" 2>/dev/null || echo "0")
count=$(echo "$count" | tr -d '[:space:]')
assert_eq "Data replicated to mysql-replica2 via new source" "1" "$count"

# Also verify data reached mysql-source (now a replica of mysql-replica1)
count_source=$(mysql_exec mysql-source "SELECT COUNT(*) FROM e2e_demote_test.t1;" 2>/dev/null || echo "0")
count_source=$(echo "$count_source" | tr -d '[:space:]')
assert_eq "Data replicated to mysql-source (now replica)" "1" "$count_source"

# Cleanup test data
mysql_exec mysql-replica1 "DROP DATABASE IF EXISTS e2e_demote_test;" || true

test_summary
