#!/usr/bin/env bash
# TLS E2E test runner for PureMyHA.
# Starts MySQL containers with TLS enabled (ssl-ca/ssl-cert/ssl-key) and puremyhad
# configured with tls.mode: skip-verify, then runs test 15.
#
# Usage: ./run-tls.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Generate TLS certificates if they do not yet exist
if [ ! -f tls/ca-cert.pem ]; then
  echo "=== Generating TLS certificates ==="
  bash tls/generate-certs.sh
fi

# Override COMPOSE to use both docker-compose files
export COMPOSE="docker compose -f ${SCRIPT_DIR}/docker-compose.yml -f ${SCRIPT_DIR}/docker-compose.tls.yml"

source lib/helpers.sh

cleanup() {
  if [ "${SKIP_TEARDOWN:-}" = "1" ]; then
    echo ""
    echo "=== Skipping teardown (SKIP_TEARDOWN=1) ==="
    return
  fi
  echo ""
  echo "=== Tearing down TLS E2E environment ==="
  $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building TLS E2E environment ==="
$COMPOSE build

echo "=== Starting TLS E2E environment ==="
$COMPOSE up -d

echo "=== Waiting for MySQL containers (TLS) ==="
wait_for_mysql mysql-source 120
wait_for_mysql mysql-replica1 120
wait_for_mysql mysql-replica2 120

echo "=== Setting up replication ==="
setup_replication

echo "=== Waiting for puremyhad to discover topology ==="
wait_for_health "Healthy" 60

echo ""
echo "========================================="
echo "  TLS E2E environment ready. Running test 15."
echo "========================================="
echo ""

PASS_COUNT=0
FAIL_COUNT=0

reset_cluster
bash tests/15-tls.sh

echo ""
echo "========================================="
echo "  TLS E2E Test Summary"
echo "========================================="
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "All TLS tests passed!"
else
  echo "FAILED: $FAIL_COUNT assertion(s) failed"
  exit 1
fi
