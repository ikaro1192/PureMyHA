#!/bin/sh
echo "pre_switchover fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/hook_pre_switchover.log
exit 0
