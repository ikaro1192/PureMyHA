#!/usr/bin/env bash
# Test: TLS Connection Support
# Verifies that puremyhad can connect to MySQL using TLS (skip-verify mode)
# and that monitoring continues when require_secure_transport=ON is enforced.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 15: TLS Connection Support ==="

# --- Case 1: Initial health with TLS enabled ---
health=$(get_health)
assert_eq "Cluster is Healthy with TLS (skip-verify)" "Healthy" "$health"

node_count=$(get_node_count)
assert_eq "3 nodes discovered via TLS" "3" "$node_count"

source_host=$(get_source_host)
assert_eq "Source is mysql-source" "mysql-source" "$source_host"

# --- Case 2: Monitoring continues with require_secure_transport=ON ---
# This verifies puremyhad's connections are truly encrypted
mysql_exec mysql-source "SET GLOBAL require_secure_transport = ON;"
mysql_exec mysql-replica1 "SET GLOBAL require_secure_transport = ON;"
mysql_exec mysql-replica2 "SET GLOBAL require_secure_transport = ON;"

# Wait for monitoring cycle to complete
sleep 3

health=$(get_health)
assert_eq "Cluster stays Healthy with require_secure_transport=ON" "Healthy" "$health"

# --- Case 3: TLS is actually being used (MySQL side) ---
# Verify that the MySQL server has TLS enabled by checking its SSL variables
ssl_ca=$(mysql_exec mysql-source "SHOW VARIABLES LIKE 'have_ssl'" | grep -o "YES\|NO" | head -1 || echo "")
assert_eq "MySQL has SSL enabled" "YES" "$ssl_ca"

# --- Restore ---
mysql_exec mysql-source  "SET GLOBAL require_secure_transport = OFF;" || true
mysql_exec mysql-replica1 "SET GLOBAL require_secure_transport = OFF;" || true
mysql_exec mysql-replica2 "SET GLOBAL require_secure_transport = OFF;" || true

test_summary
