#!/bin/bash
# =============================================================================
# post_failover.sh — PureMyHA hook: update HAProxy after automatic failover
# =============================================================================
# Fired asynchronously after a successful automatic failover.
#
# Environment variables (set by PureMyHA):
#   PUREMYHA_CLUSTER     — cluster name
#   PUREMYHA_NEW_SOURCE  — hostname of the newly promoted source
#   PUREMYHA_OLD_SOURCE  — hostname of the old (failed) source
#   PUREMYHA_TIMESTAMP   — ISO 8601 UTC timestamp
#
# This script:
#   1. Updates the HAProxy write backend via the Runtime API (stats socket)
#   2. Swaps replica pool membership (disable new source, enable old source)
#   3. Rewrites the HAProxy config file for persistence
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/haproxy-common.sh"

handle_topology_change
