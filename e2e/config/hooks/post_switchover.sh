#!/bin/sh
echo "post_switchover fired at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /tmp/hook_post_switchover.log
exit 0
