#!/bin/bash
set -e

# Remove default config files installed by packages.
# pcs cluster setup will distribute its own authkey and corosync.conf.
# Pre-existing files trigger a "cluster already exists" warning + destroy cycle.
rm -f /etc/corosync/corosync.conf /etc/corosync/authkey

# Ensure pcsd data directory exists with correct ownership.
# Without this, pcsd may fail to save known-hosts in Docker environments.
mkdir -p /var/lib/pcsd
chown hacluster:haclient /var/lib/pcsd

# pcsd consists of two daemons:
#   1) pcsd-ruby (/usr/share/pcsd/pcsd) — Ruby backend on localhost, handles
#      set_configs, check_host, and other cluster operations.
#   2) pcsd (/usr/sbin/pcsd) — Python frontend on port 2224, delegates to the
#      Ruby backend.
# Both must be running for pcs host auth / pcs cluster setup to work.
/usr/share/pcsd/pcsd &
/usr/sbin/pcsd &

echo "[entrypoint] pcsd started."
echo "[entrypoint] Run 'make setup' from the host to initialize the cluster."

# Keep the container alive. Corosync and Pacemaker will be started later
# by 'pcs cluster setup --start' (called from setup-cluster.sh).
exec sleep infinity
