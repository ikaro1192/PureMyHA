#!/bin/bash
set -e

# Ensure pcsd data directory exists with correct ownership.
mkdir -p /var/lib/pcsd
chown hacluster:haclient /var/lib/pcsd

# Start pcsd daemons (needed for certificate exchange during
# 'pcs quorum device add' from cluster nodes).
/usr/share/pcsd/pcsd &
/usr/sbin/pcsd &

# Initialize qdevice NSS certificate database.
pcs qdevice setup model net --enable 2>/dev/null || true

echo "[qdevice] pcsd and corosync-qnetd starting..."
exec /usr/bin/corosync-qnetd -f
