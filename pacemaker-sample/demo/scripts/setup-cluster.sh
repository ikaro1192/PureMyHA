#!/bin/bash
# =============================================================================
# PureMyHA Pacemaker Demo — Cluster Setup Script (Phase 1)
# =============================================================================
# Authenticates nodes and distributes cluster configuration.
# Daemons (corosync, pacemakerd) are started by the Makefile, not this script,
# because Docker has no systemd and we need to start them on both nodes.
#
# Called by:  make setup
# =============================================================================
set -e

HACLUSTER_PASSWORD="hacluster"

echo "==> Waiting for pcsd on ha1, ha2, and qdevice..."
for node in ha1 ha2 qdevice; do
    for i in $(seq 1 30); do
        if curl -sk "https://${node}:2224/" > /dev/null 2>&1; then
            echo "    ${node}: ready"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "    ${node}: pcsd not ready after 30 seconds — aborting"
            exit 1
        fi
        sleep 1
    done
done

# pcsd may respond on port 2224 before internal initialization is complete.
echo "==> Waiting for pcsd internal initialization..."
sleep 5

echo "==> Authenticating cluster nodes and qdevice..."
for attempt in 1 2 3; do
    echo "    Attempt ${attempt}/3..."
    if pcs host auth \
        ha1 addr=192.168.100.11 \
        ha2 addr=192.168.100.12 \
        qdevice addr=192.168.100.13 \
        -u hacluster -p "${HACLUSTER_PASSWORD}" 2>&1; then
        break
    fi
    sleep 3
done

# Fallback: if pcs host auth failed to save known-hosts (common in Docker),
# create the file manually by fetching tokens directly from pcsd.
if [ ! -f /var/lib/pcsd/known-hosts ]; then
    echo "==> known-hosts not created by pcs — creating manually via pcsd API..."

    TOKEN_HA1=$(curl -sk -d "username=hacluster&password=${HACLUSTER_PASSWORD}" \
        https://192.168.100.11:2224/remote/auth 2>/dev/null)
    TOKEN_HA2=$(curl -sk -d "username=hacluster&password=${HACLUSTER_PASSWORD}" \
        https://192.168.100.12:2224/remote/auth 2>/dev/null)
    TOKEN_QDEVICE=$(curl -sk -d "username=hacluster&password=${HACLUSTER_PASSWORD}" \
        https://192.168.100.13:2224/remote/auth 2>/dev/null)

    if [ -n "${TOKEN_HA1}" ] && [ -n "${TOKEN_HA2}" ] && [ -n "${TOKEN_QDEVICE}" ]; then
        cat > /var/lib/pcsd/known-hosts << KHEOF
{
    "format_version": 2,
    "data_version": 1,
    "known_hosts": {
        "ha1": {
            "dest_list": [{"addr": "192.168.100.11", "port": 2224}],
            "token": "${TOKEN_HA1}"
        },
        "ha2": {
            "dest_list": [{"addr": "192.168.100.12", "port": 2224}],
            "token": "${TOKEN_HA2}"
        },
        "qdevice": {
            "dest_list": [{"addr": "192.168.100.13", "port": 2224}],
            "token": "${TOKEN_QDEVICE}"
        }
    }
}
KHEOF
        chmod 600 /var/lib/pcsd/known-hosts
        chown hacluster:haclient /var/lib/pcsd/known-hosts 2>/dev/null || true
        echo "    known-hosts created successfully"
    else
        echo "    ERROR: Failed to get tokens from pcsd"
        echo "    TOKEN_HA1=${TOKEN_HA1}"
        echo "    TOKEN_HA2=${TOKEN_HA2}"
        echo "    TOKEN_QDEVICE=${TOKEN_QDEVICE}"
        exit 1
    fi
fi

echo "==> Setting up cluster..."
# Use udpu (unicast) because Docker bridge networks do not support multicast.
# Do NOT use --start/--enable: systemd is not available in Docker containers.
pcs cluster setup puremyha-cluster \
    ha1 addr=192.168.100.11 \
    ha2 addr=192.168.100.12 \
    transport udpu \
    --force

echo "==> Phase 1 complete. Cluster config distributed to both nodes."
