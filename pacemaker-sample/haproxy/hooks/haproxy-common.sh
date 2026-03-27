# =============================================================================
# haproxy-common.sh — Shared library for PureMyHA HAProxy hook scripts
# =============================================================================
# Source this file from hook scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "${SCRIPT_DIR}/haproxy-common.sh"
# =============================================================================

HAPROXY_SOCKET="${HAPROXY_SOCKET:-/run/haproxy/admin.sock}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

# --- Logging ----------------------------------------------------------------

log_hook() {
    logger -t "puremyha-haproxy-hook" "$*"
}

# --- HAProxy Runtime API (stats socket) -------------------------------------

# Send a command to the HAProxy stats socket.
# Usage: haproxy_cmd "show stat"
haproxy_cmd() {
    echo "$1" | socat stdio "unix-connect:${HAPROXY_SOCKET}" 2>/dev/null
}

# Change the address of a server in a backend.
# Usage: haproxy_set_server_addr <backend> <server> <host> <port>
haproxy_set_server_addr() {
    local backend="$1" server="$2" host="$3" port="$4"
    haproxy_cmd "set server ${backend}/${server} addr ${host} port ${port}"
    log_hook "Runtime API: set server ${backend}/${server} addr ${host}:${port}"
}

# Enable a server in a backend.
# Usage: haproxy_enable_server <backend> <server>
haproxy_enable_server() {
    local backend="$1" server="$2"
    haproxy_cmd "set server ${backend}/${server} state ready"
    log_hook "Runtime API: enabled ${backend}/${server}"
}

# Disable a server in a backend (graceful drain).
# Usage: haproxy_disable_server <backend> <server>
haproxy_disable_server() {
    local backend="$1" server="$2"
    haproxy_cmd "set server ${backend}/${server} state maint"
    log_hook "Runtime API: disabled ${backend}/${server} (maint)"
}

# --- Config file persistence ------------------------------------------------

# Rewrite the HAProxy config file so changes survive HAProxy restarts.
# Updates the "server source" line in mysql_source backend and the
# enabled/disabled state of servers in mysql_replicas backend.
#
# Usage: update_haproxy_cfg <new_source_host> <old_source_host>
update_haproxy_cfg() {
    local new_source="$1"
    local old_source="$2"

    if [ ! -f "${HAPROXY_CFG}" ]; then
        log_hook "WARNING: ${HAPROXY_CFG} not found, skipping config persistence"
        return 1
    fi

    local tmp="${HAPROXY_CFG}.tmp.$$"
    cp "${HAPROXY_CFG}" "${tmp}"

    # Update the source backend: point "server source" to the new source.
    sed -i \
        "s|^\(    server source \)[^ ]*:[0-9]*|\1${new_source}:${MYSQL_PORT}|" \
        "${tmp}"

    # In mysql_replicas: enable the old source (now a replica) and disable
    # the new source (now handling writes).
    # "disabled" is appended/removed at end of the server line.
    #
    # Enable old_source: remove " disabled" if present.
    sed -i \
        "/^    server ${old_source} /s/ disabled//" \
        "${tmp}"
    # Disable new_source: add " disabled" before the final server options
    # if not already present.
    if grep -q "^    server ${new_source} " "${tmp}" && \
       ! grep -q "^    server ${new_source} .* disabled" "${tmp}"; then
        sed -i \
            "/^    server ${new_source} /s/$/ disabled/" \
            "${tmp}"
    fi

    mv "${tmp}" "${HAPROXY_CFG}"
    log_hook "Config persisted: source=${new_source}, ${old_source} enabled in replicas"
}

# --- Common hook logic ------------------------------------------------------

# Update HAProxy after a topology change (failover or switchover).
# Reads PUREMYHA_NEW_SOURCE and PUREMYHA_OLD_SOURCE from the environment.
#
# Usage: handle_topology_change
handle_topology_change() {
    local new_source="${PUREMYHA_NEW_SOURCE:?PUREMYHA_NEW_SOURCE is not set}"
    local old_source="${PUREMYHA_OLD_SOURCE:-}"
    local cluster="${PUREMYHA_CLUSTER:-unknown}"

    log_hook "Topology change detected: cluster=${cluster} new_source=${new_source} old_source=${old_source}"

    # 1. Update the write backend to point to the new source.
    haproxy_set_server_addr "mysql_source" "source" "${new_source}" "${MYSQL_PORT}"

    # 2. In the read backend, disable the new source (it is now handling writes)
    #    and enable the old source (it is now a replica).
    haproxy_disable_server "mysql_replicas" "${new_source}"
    if [ -n "${old_source}" ]; then
        haproxy_enable_server "mysql_replicas" "${old_source}"
    fi

    # 3. Persist changes to the config file.
    if [ -n "${old_source}" ]; then
        update_haproxy_cfg "${new_source}" "${old_source}"
    fi

    log_hook "HAProxy update complete for cluster=${cluster}"
}
