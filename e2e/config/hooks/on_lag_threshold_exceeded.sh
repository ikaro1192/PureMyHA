#!/bin/sh
echo "exceeded CLUSTER=$PUREMYHA_CLUSTER NODE=$PUREMYHA_NODE LAG=$PUREMYHA_LAG_SECONDS" > /tmp/hook_lag_exceeded.log
exit 0
