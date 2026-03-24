#!/usr/bin/env bash
# Test: TLS Connection Support
# Verifies that puremyhad can connect to MySQL using TLS (skip-verify mode)
# and that monitoring continues when require_secure_transport=ON is enforced.
# Requires TLS environment (run via e2e/run-tls.sh); skips gracefully otherwise.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 15: TLS Connection Support ==="

# Skip if not running in TLS environment (certificates not mounted)
if ! $COMPOSE exec -T mysql-source sh -c "test -f /etc/mysql/tls/ca-cert.pem" 2>/dev/null; then
  echo "  SKIP: TLS certificates not mounted — run via e2e/run-tls.sh"
  test_summary
  exit 0
fi

# --- Case 1: Initial health with TLS enabled ---
health=$(get_health)
assert_eq "Cluster is Healthy with TLS (skip-verify)" "Healthy" "$health"

node_count=$(get_node_count)
assert_eq "3 nodes discovered via TLS" "3" "$node_count"

source_host=$(get_source_host)
assert_eq "Source is mysql-source" "mysql-source" "$source_host"

# --- Case 2: Monitoring continues with require_secure_transport=ON ---
# This verifies puremyhad's connections are truly encrypted
mysql_exec mysql-source  "SET GLOBAL require_secure_transport = ON;"
mysql_exec mysql-replica1 "SET GLOBAL require_secure_transport = ON;"
mysql_exec mysql-replica2 "SET GLOBAL require_secure_transport = ON;"

# Wait for monitoring cycle to complete
sleep 3

health=$(get_health)
assert_eq "Cluster stays Healthy with require_secure_transport=ON" "Healthy" "$health"

# --- Case 3: TLS is actually being used (MySQL side) ---
# @@ssl_ca is set when MySQL is started with ssl-ca option (requires TLS overlay)
ssl_ca=$(mysql_exec mysql-source "SELECT @@ssl_ca" 2>/dev/null | tr -d '[:space:]' || echo "")
assert_not_empty "MySQL SSL CA certificate configured" "$ssl_ca"

# --- Restore ---
mysql_exec mysql-source  "SET GLOBAL require_secure_transport = OFF;" || true
mysql_exec mysql-replica1 "SET GLOBAL require_secure_transport = OFF;" || true
mysql_exec mysql-replica2 "SET GLOBAL require_secure_transport = OFF;" || true

test_summary
