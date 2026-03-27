#!/bin/bash
# =============================================================================
# PureMyHA Pacemaker Demo — Resource Configuration Script (Phase 2)
# =============================================================================
# Waits for the cluster to form, then configures QDevice, resources, and
# a resource group. Run after both ha1 and ha2 have corosync/pacemaker running.
#
# Resource Group (start order):
#   puremyhad → haproxy → vip-write → vip-read
#
# Called by:  make setup
# =============================================================================
set -e

QDEVICE_HOST="qdevice"

echo "==> Waiting for cluster to form..."
# Use crm_mon instead of pcs cluster status — pcs relies on systemd which
# is unavailable in Docker.
for i in $(seq 1 60); do
    OUTPUT=$(crm_mon -1 2>&1) || true
    if echo "${OUTPUT}" | grep -q "Online:"; then
        echo "    Cluster is online"
        echo "${OUTPUT}"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "    ERROR: Timed out waiting for cluster"
        echo "${OUTPUT}"
        exit 1
    fi
    sleep 2
done

echo "==> Adding QDevice..."
pcs quorum device add model net \
    host="${QDEVICE_HOST}" \
    algorithm=ffsplit

echo "==> Disabling STONITH (demo only — never do this in production)..."
pcs property set stonith-enabled=false

echo "==> Creating puremyhad resource..."
pcs resource create puremyhad ocf:puremyha:puremyhad \
    config=/etc/puremyha/config.yaml \
    socket=/run/puremyhad.sock \
    op start   timeout=30s \
    op stop    timeout=60s \
    op monitor interval=15s timeout=15s

echo "==> Creating HAProxy resource..."
# ocf:heartbeat:anything is used because the demo runs without systemd.
# In production, use: pcs resource create haproxy systemd:haproxy ...
pcs resource create haproxy ocf:heartbeat:anything \
    binfile="/usr/sbin/haproxy" \
    cmdline_options="-f /etc/haproxy/haproxy.cfg -p /run/haproxy/haproxy.pid -Ws" \
    pidfile="/run/haproxy/haproxy.pid" \
    op start   timeout=30s \
    op stop    timeout=30s \
    op monitor interval=10s timeout=10s

echo "==> Creating Write VIP resource..."
pcs resource create vip-write IPaddr2 \
    ip=192.168.100.100 \
    cidr_netmask=24 \
    op monitor interval=10s timeout=10s

echo "==> Creating Read VIP resource..."
pcs resource create vip-read IPaddr2 \
    ip=192.168.100.101 \
    cidr_netmask=24 \
    op monitor interval=10s timeout=10s

echo "==> Creating resource group (puremyhad → haproxy → vip-write → vip-read)..."
pcs resource group add puremyha-group \
    puremyhad haproxy vip-write vip-read

echo ""
echo "==> Cluster setup complete!"
echo ""
crm_mon -1
