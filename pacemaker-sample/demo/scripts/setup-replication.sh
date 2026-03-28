#!/bin/bash
# =============================================================================
# PureMyHA Pacemaker Demo — MySQL Replication Setup
# =============================================================================
# Configures GTID-based replication from db1 (source) to db2 (replica).
# Run after MySQL containers are healthy.
#
# Called by:  make setup
# =============================================================================
set -e

COMPOSE="docker compose"
MYSQL_ROOT_PASS="rootpass"

mysql_exec() {
    local host="$1"
    shift
    ${COMPOSE} exec -T "$host" mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "$@"
}

echo "==> Waiting for MySQL containers to be healthy..."
for host in db1 db2; do
    for i in $(seq 1 30); do
        if ${COMPOSE} exec -T "$host" mysqladmin ping -uroot -p"${MYSQL_ROOT_PASS}" --silent 2>/dev/null; then
            echo "    $host is ready"
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "    ERROR: Timed out waiting for $host"
            exit 1
        fi
        sleep 2
    done
done

echo "==> Configuring replication on db2..."
for attempt in $(seq 1 5); do
    if mysql_exec db2 "
        STOP REPLICA;
        RESET BINARY LOGS AND GTIDS;
        CHANGE REPLICATION SOURCE TO
            SOURCE_HOST='192.168.100.21',
            SOURCE_PORT=3306,
            SOURCE_USER='repl',
            SOURCE_PASSWORD='repl_pass',
            SOURCE_AUTO_POSITION=1,
            SOURCE_CONNECT_RETRY=5,
            SOURCE_RETRY_COUNT=3,
            GET_SOURCE_PUBLIC_KEY=1;
        START REPLICA;
    "; then
        break
    fi
    echo "    Attempt $attempt failed, retrying in 3s..."
    sleep 3
    if [ "$attempt" -eq 5 ]; then
        echo "    ERROR: Failed to configure replication after 5 attempts"
        exit 1
    fi
done

echo "==> Waiting for replication to start..."
for i in $(seq 1 30); do
    IO_RUNNING=$(mysql_exec db2 "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(mysql_exec db2 "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_SQL_Running:" | awk '{print $2}')
    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        echo "    Replication is running"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "    ERROR: Replication did not start"
        mysql_exec db2 "SHOW REPLICA STATUS\G" || true
        exit 1
    fi
    sleep 2
done

echo "==> MySQL replication setup complete (db1 → db2)"
