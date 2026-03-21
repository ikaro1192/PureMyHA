#!/bin/bash
set -e

# Write Corosync configuration for this node.
# Docker Compose assigns static IPs; use udpu (unicast) since Docker bridge
# networks do not support multicast.
cat > /etc/corosync/corosync.conf << 'EOF'
totem {
    version: 2
    cluster_name: puremyha-cluster
    transport: udpu
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        ring0_addr: 192.168.100.11
        name: ha1
        nodeid: 1
    }
    node {
        ring0_addr: 192.168.100.12
        name: ha2
        nodeid: 2
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 0
    expected_votes: 3
    device {
        model: net
        net {
            host: 192.168.100.13
            algorithm: ffsplit
        }
    }
}

logging {
    to_stderr: yes
    timestamp: on
}
EOF

# Generate or copy a shared Corosync auth key.
# In this demo environment a fixed key is acceptable; for production,
# generate a unique key with `corosync-keygen` and distribute it securely.
if [ ! -f /etc/corosync/authkey ]; then
    dd if=/dev/urandom bs=128 count=1 > /tmp/authkey_raw 2>/dev/null
    cp /tmp/authkey_raw /etc/corosync/authkey
    chmod 400 /etc/corosync/authkey
fi

# pcsd (the pcs daemon) must be running for `pcs host auth` to work.
/usr/sbin/pcsd &

# Start Corosync and Pacemaker.
# Pacemaker will be started by Corosync via the corosync-pacemaker plugin.
/usr/sbin/corosync -f &
COROSYNC_PID=$!

echo "[entrypoint] Corosync started (pid=${COROSYNC_PID})"
echo "[entrypoint] Run 'make setup' from the host to initialize the cluster."

wait ${COROSYNC_PID}
