#!/bin/sh
echo "on_topology_drift fired: cluster=${PUREMYHA_CLUSTER} type=${PUREMYHA_DRIFT_TYPE} details=${PUREMYHA_DRIFT_DETAILS} at=${PUREMYHA_TIMESTAMP}" > /tmp/hook_topology_drift.log
exit 0
