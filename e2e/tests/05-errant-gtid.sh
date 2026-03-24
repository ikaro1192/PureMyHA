#!/usr/bin/env bash
# Test: Errant GTID Detection and Repair
# Injects an errant transaction on a replica and verifies detection and fix.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 05: Errant GTID ==="

wait_for_health "Healthy" 60

# Verify no errant GTIDs initially
errant_before=$(cli_errant_gtid)
errant_count_before=$(echo "$errant_before" | jq '. | length')
assert_eq "No errant GTIDs initially" "0" "$errant_count_before"

# Inject an errant transaction on mysql-replica1
echo "  Injecting errant GTID on mysql-replica1..."
mysql_exec mysql-replica1 "
  SET GLOBAL read_only = OFF;
  SET GTID_NEXT = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:1';
  BEGIN; COMMIT;
  SET GTID_NEXT = 'AUTOMATIC';
  SET GLOBAL read_only = ON;
"

# Wait for the monitor to detect the errant GTID
echo "  Waiting for errant GTID detection..."
for i in $(seq 1 20); do
  errant_result=$(cli_errant_gtid)
  errant_count=$(echo "$errant_result" | jq '. | length')
  if [ "$errant_count" -ge 1 ]; then
    echo "  Errant GTID detected (${i}s)"
    break
  fi
  sleep 1
done

errant_result=$(cli_errant_gtid)
errant_count=$(echo "$errant_result" | jq '. | length')
assert_eq "Errant GTID detected" "1" "$errant_count"

# Fix errant GTIDs
echo "  Fixing errant GTIDs..."
fix_result=$(cli_fix_errant_gtid)
echo "  Fix response: $fix_result"
fix_success=$(echo "$fix_result" | jq -r '.success // empty')
assert_not_empty "Fix errant GTID returns success" "$fix_success"

# Wait for the fix to propagate
echo "  Waiting for fix to propagate..."
for i in $(seq 1 20); do
  errant_after=$(cli_errant_gtid)
  errant_count_after=$(echo "$errant_after" | jq '. | length')
  if [ "$errant_count_after" -eq 0 ]; then
    echo "  Errant GTIDs cleared (${i}s)"
    break
  fi
  sleep 1
done

errant_after=$(cli_errant_gtid)
errant_count_after=$(echo "$errant_after" | jq '. | length')
assert_eq "No errant GTIDs after fix" "0" "$errant_count_after"

test_summary
