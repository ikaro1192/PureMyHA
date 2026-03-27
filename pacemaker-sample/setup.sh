#!/bin/bash
# =============================================================================
# PureMyHA Pacemaker Cluster Setup Reference
# =============================================================================
# This script is a REFERENCE, not a run-all script.
# Read and adapt each section to your environment before executing.
#
# Topology:
#   ha1      192.168.10.11  — cluster node (Active puremyhad + HAProxy)
#   ha2      192.168.10.12  — cluster node (Standby puremyhad + HAProxy)
#   qdevice  192.168.10.13  — quorum device host (corosync-qnetd only)
#   db1      MySQL source
#   db2      MySQL replica
#
# Virtual IPs:
#   192.168.10.100 — Write VIP (routes to MySQL source via HAProxy)
#   192.168.10.101 — Read VIP  (routes to MySQL replicas via HAProxy)
#
# Pacemaker Resource Group (start order):
#   puremyhad → haproxy → vip-write → vip-read
#
# Prerequisites on ha1 and ha2:
#   - pacemaker, pcs, corosync, fence-agents, haproxy, socat installed
#   - /etc/corosync/corosync.conf deployed (see corosync.conf.example)
#   - /etc/hosts or DNS entries for ha1, ha2, qdevice
#   - hacluster user password set: echo "PASSWORD" | passwd --stdin hacluster
#
# Prerequisites on qdevice:
#   - corosync-qnetd installed and running:
#       systemctl enable --now corosync-qnetd
# =============================================================================


# --- SECTION 1: Install packages ---
# Run on ha1 AND ha2.

# Debian / Ubuntu
apt-get install -y pacemaker pcs corosync fence-agents haproxy socat

# RHEL / Rocky / AlmaLinux
# dnf install -y pacemaker pcs corosync fence-agents-all haproxy socat

# On the QDevice host only:
# apt-get install -y corosync-qnetd     # Debian
# dnf install -y corosync-qnetd         # RHEL


# --- SECTION 2: Set hacluster password ---
# Run on ha1 AND ha2. Use the same password on both nodes.
echo "hacluster_password_here" | passwd --stdin hacluster


# --- SECTION 3: Deploy Corosync configuration ---
# Run on ha1 AND ha2. Use corosync.conf.example as a template.
cp /path/to/corosync.conf.example /etc/corosync/corosync.conf
# Edit the file to set the correct IP addresses for your environment.

# Generate a Corosync auth key (run once on ha1, then copy to ha2):
corosync-keygen
scp /etc/corosync/authkey ha2:/etc/corosync/authkey


# --- SECTION 4: Disable systemd auto-restart for puremyhad ---
# Run on ha1 AND ha2.
#
# IMPORTANT: puremyhad.service has Restart=on-failure. When Pacemaker manages
# the service, systemd must NOT be allowed to restart it independently.
# Use a drop-in override to disable the Restart directive.
#
mkdir -p /etc/systemd/system/puremyhad.service.d/
cat > /etc/systemd/system/puremyhad.service.d/pacemaker.conf << 'EOF'
[Service]
Restart=no
EOF
systemctl daemon-reload

# Prevent puremyhad from starting at boot independently — Pacemaker controls it:
systemctl disable puremyhad


# --- SECTION 5: Install the OCF Resource Agent ---
# Run on ha1 AND ha2.
# The OCF RA is in pacemaker-sample/ocf/puremyha in this repository.
install -m 755 /path/to/pacemaker-sample/ocf/puremyha \
    /usr/lib/ocf/resource.d/puremyha/puremyhad


# --- SECTION 6: Deploy HAProxy configuration and hook scripts ---
# Run on ha1 AND ha2.
#
# HAProxy sits between clients and MySQL. It runs in TCP (Layer 4) mode:
#   Write VIP:3306 → mysql_source backend  (single active source)
#   Read  VIP:3306 → mysql_replicas backend (replica pool)
#
# PureMyHA hook scripts update HAProxy backends automatically on failover
# or switchover using the HAProxy Runtime API (stats socket) and also
# rewrite the config file for persistence.

# Deploy HAProxy config (edit VIP addresses and server entries first):
cp /path/to/pacemaker-sample/haproxy/haproxy.cfg.example /etc/haproxy/haproxy.cfg

# Create the stats socket directory:
mkdir -p /run/haproxy

# Install hook scripts:
mkdir -p /etc/puremyha/hooks
install -m 755 /path/to/pacemaker-sample/haproxy/hooks/haproxy-common.sh \
    /etc/puremyha/hooks/haproxy-common.sh
install -m 755 /path/to/pacemaker-sample/haproxy/hooks/post_failover.sh \
    /etc/puremyha/hooks/post_failover.sh
install -m 755 /path/to/pacemaker-sample/haproxy/hooks/post_switchover.sh \
    /etc/puremyha/hooks/post_switchover.sh

# Disable HAProxy systemd service — Pacemaker manages it:
systemctl disable haproxy
systemctl stop haproxy

# Add hooks to PureMyHA config (/etc/puremyha/config.yaml):
#   global:
#     hooks:
#       post_failover: /etc/puremyha/hooks/post_failover.sh
#       post_switchover: /etc/puremyha/hooks/post_switchover.sh


# --- SECTION 7: Authenticate and bootstrap the cluster ---
# Run on ONE node (ha1) only.

# Authenticate pcs to both nodes (uses the hacluster password set in Section 2):
pcs host auth ha1 ha2 -u hacluster -p hacluster_password_here

# Create and start the cluster:
pcs cluster setup puremyha-cluster ha1 ha2 \
    --start \
    --enable


# --- SECTION 8: Add the QDevice ---
# Run on ONE node (ha1) only.
# The QDevice host must have corosync-qnetd running before this step.
pcs quorum device add model net \
    host=192.168.10.13 \
    algorithm=ffsplit

# Verify quorum is healthy with 3 expected votes:
pcs quorum status


# --- SECTION 9: Configure STONITH (fencing) ---
# STONITH is MANDATORY in production. A cluster without fencing risks
# data corruption if a node hangs partway through a failover.
# NEVER run `pcs property set stonith-enabled=false` in production.

# Option A: IPMI/BMC fencing (recommended for bare metal)
pcs stonith create fence-ha1 fence_ipmilan \
    ipaddr=192.168.10.101 \
    login=admin \
    passwd=ipmi_password_here \
    lanplus=1 \
    pcmk_host_list=ha1

pcs stonith create fence-ha2 fence_ipmilan \
    ipaddr=192.168.10.102 \
    login=admin \
    passwd=ipmi_password_here \
    lanplus=1 \
    pcmk_host_list=ha2

# Option B: libvirt/KVM fencing (virtual machines)
# pcs stonith create fence-ha1 fence_virsh \
#     ipaddr=kvm_host_ip \
#     login=root \
#     pcmk_host_list=ha1
# (repeat for ha2)

# Each node should be fenced by the OTHER node (not itself):
pcs constraint location fence-ha1 avoids ha1
pcs constraint location fence-ha2 avoids ha2

# Test fencing — CAUTION: this will power-cycle ha2:
# pcs stonith fence ha2


# --- SECTION 10: Create the puremyhad resource ---
# Uses the OCF RA installed in Section 5.
# Set http_port only if http.enabled=true in config.yaml (port must match http.port).
# The monitor operation will then verify the /health endpoint on every check interval.
pcs resource create puremyhad ocf:puremyha:puremyhad \
    config=/etc/puremyha/config.yaml \
    socket=/run/puremyhad.sock \
    http_port=8080 \
    op start   timeout=30s \
    op stop    timeout=30s \
    op monitor interval=15s timeout=15s


# --- SECTION 11: Create the HAProxy resource ---
# In production, use systemd:haproxy instead of ocf:heartbeat:anything:
#   pcs resource create haproxy systemd:haproxy \
#       op start timeout=30s op stop timeout=30s op monitor interval=10s timeout=10s
#
# ocf:heartbeat:anything is used here because the demo environment runs
# without systemd. For production with systemd, prefer the systemd RA above.
pcs resource create haproxy ocf:heartbeat:anything \
    binfile="/usr/sbin/haproxy" \
    cmdline_options="-f /etc/haproxy/haproxy.cfg -p /run/haproxy/haproxy.pid -Ws" \
    pidfile="/run/haproxy/haproxy.pid" \
    op start   timeout=30s \
    op stop    timeout=30s \
    op monitor interval=10s timeout=10s


# --- SECTION 12: Create the Virtual IP resources ---
# Two VIPs are used — both on port 3306 — so clients distinguish read/write
# by IP address, not port number.

# Write VIP: clients connect here for read-write access to the MySQL source.
pcs resource create vip-write IPaddr2 \
    ip=192.168.10.100 \
    cidr_netmask=24 \
    op monitor interval=10s timeout=10s

# Read VIP: clients connect here for read-only access to MySQL replicas.
pcs resource create vip-read IPaddr2 \
    ip=192.168.10.101 \
    cidr_netmask=24 \
    op monitor interval=10s timeout=10s


# --- SECTION 13: Create a Resource Group ---
# A resource group ensures all resources run on the same node and
# start/stop in the correct order:
#   Start: puremyhad → haproxy → vip-write → vip-read
#   Stop:  vip-read → vip-write → haproxy → puremyhad
pcs resource group add puremyha-group \
    puremyhad haproxy vip-write vip-read


# --- SECTION 14: Prefer ha1 as the active node (optional) ---
# After maintenance, the resource group will prefer to return to ha1 (score=50).
# Remove this if you want the group to stay on whichever node it is on.
pcs constraint location puremyha-group prefers ha1=50


# =============================================================================
# Verification
# =============================================================================

# Overall cluster status (both nodes online, no resources in failed state):
pcs status

# Confirm quorum device is providing its vote:
pcs quorum status

# Show all constraints:
pcs constraint show

# Planned failover test (moves the entire resource group to ha2):
pcs node standby ha1
pcs status
# Confirm all resources (puremyhad, haproxy, vip-write, vip-read) are on ha2,
# then restore ha1:
pcs node unstandby ha1

# Check that HAProxy is listening and the stats socket exists on the active node:
# ss -tlnp | grep 3306           # should show HAProxy listening
# ls -la /run/haproxy/admin.sock # should exist on the active node

# Test the HAProxy stats socket (on the active node):
# echo "show stat" | socat stdio /run/haproxy/admin.sock

# Reload puremyhad config (sends SIGHUP via ExecReload in the systemd unit):
# pcs resource reload puremyhad

# Check that the Unix socket exists only on the active node:
# ls -la /run/puremyhad.sock   # run on the active node — should exist
# ls -la /run/puremyhad.sock   # run on the standby node — should NOT exist
