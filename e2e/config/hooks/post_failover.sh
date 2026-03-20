#!/bin/sh
echo "post_failover fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/hook_post_failover.log
exit 0
