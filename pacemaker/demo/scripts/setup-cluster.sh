#!/bin/bash
# =============================================================================
# PureMyHA Pacemaker Demo — Cluster Setup Script
# =============================================================================
# Run this script inside the ha1 container ONCE after `make start`:
#
#   docker compose exec ha1 /setup/setup-cluster.sh
#
# Or simply:  make setup
# =============================================================================
set -e

HACLUSTER_PASSWORD="hacluster"
QDEVICE_HOST="192.168.100.13"

echo "==> Waiting for pcsd on ha1 and ha2..."
for node in ha1 ha2; do
    for i in $(seq 1 20); do
        if curl -sk "https://${node}:2224/" > /dev/null 2>&1; then
            echo "    ${node}: ready"
            break
        fi
        if [ $i -eq 20 ]; then
            echo "    ${node}: pcsd not ready after 20 seconds — aborting"
            exit 1
        fi
        sleep 1
    done
done

echo "==> Authenticating cluster nodes..."
pcs host auth ha1 ha2 \
    -u hacluster \
    -p "${HACLUSTER_PASSWORD}"

echo "==> Setting up cluster..."
pcs cluster setup puremyha-cluster ha1 ha2 \
    --start \
    --enable \
    --force

echo "==> Waiting for cluster to stabilize..."
sleep 5
pcs cluster status

echo "==> Adding QDevice..."
pcs quorum device add model net \
    host="${QDEVICE_HOST}" \
    algorithm=ffsplit

echo "==> Disabling STONITH (demo only — never do this in production)..."
pcs property set stonith-enabled=false

echo "==> Installing OCF Resource Agent on ha2..."
# The Dockerfile already installed it on ha1 (the build context).
# Distribute to ha2 via pcs if needed; for demo it was baked into the image.

echo "==> Creating puremyhad resource..."
pcs resource create puremyhad ocf:puremyha:puremyhad \
    config=/etc/puremyha/config.yaml \
    socket=/run/puremyhad.sock \
    op start   timeout=30s \
    op stop    timeout=30s \
    op monitor interval=15s timeout=15s

echo "==> Creating Virtual IP resource..."
pcs resource create puremyha-vip IPaddr2 \
    ip=192.168.100.100 \
    cidr_netmask=24 \
    op monitor interval=10s timeout=10s

echo "==> Setting colocation and ordering constraints..."
pcs constraint colocation add puremyha-vip with puremyhad INFINITY
pcs constraint order puremyhad then puremyha-vip

echo ""
echo "==> Cluster setup complete!"
echo ""
pcs status
