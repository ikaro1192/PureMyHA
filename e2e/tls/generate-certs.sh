#!/usr/bin/env bash
# Generate self-signed CA + MySQL server certificate + puremyhad client certificate for TLS E2E tests.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Generating TLS certificates for E2E tests ==="

# CA
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -nodes -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/CN=PureMyHA-Test-CA"

# MySQL server certificate with SANs for all 3 containers
openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem -out server-req.pem \
  -subj "/CN=mysql-server"
openssl x509 -req -in server-req.pem -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out server-cert.pem -days 3650 \
  -extfile <(printf "subjectAltName=DNS:mysql-source,DNS:mysql-replica1,DNS:mysql-replica2")

# Client certificate for puremyhad (mutual TLS)
openssl genrsa -out client-key.pem 2048
openssl req -new -key client-key.pem -out client-req.pem \
  -subj "/CN=puremyha-client"
openssl x509 -req -in client-req.pem -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out client-cert.pem -days 3650

# Clean up request files
rm -f server-req.pem client-req.pem ca-cert.srl

echo "=== Certificate generation complete ==="
echo "  ca-cert.pem      — CA certificate"
echo "  server-cert.pem  — MySQL server certificate"
echo "  server-key.pem   — MySQL server private key"
echo "  client-cert.pem  — puremyhad client certificate"
echo "  client-key.pem   — puremyhad client private key"
