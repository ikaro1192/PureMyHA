#!/bin/bash
set -e

echo "[qdevice] Starting corosync-qnetd..."
# -f: run in foreground; -d: debug level (0 = default)
exec /usr/bin/corosync-qnetd -f
