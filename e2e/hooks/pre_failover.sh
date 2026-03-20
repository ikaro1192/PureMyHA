#!/bin/sh
echo "pre_failover fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/hook_pre_failover.log
exit 0
