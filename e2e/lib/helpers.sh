#!/usr/bin/env bash
# E2E test helper functions for PureMyHA
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE:-docker compose -f ${E2E_DIR}/docker-compose.yml}"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    ((PASS_COUNT++)) || true
  else
    echo "  FAIL: $desc (expected='$expected', got='$actual')"
    ((FAIL_COUNT++)) || true
  fi
}

assert_neq() {
  local desc="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    echo "  PASS: $desc"
    ((PASS_COUNT++)) || true
  else
    echo "  FAIL: $desc (should differ from '$unexpected')"
    ((FAIL_COUNT++)) || true
  fi
}

assert_not_empty() {
  local desc="$1" actual="$2"
  if [ -n "$actual" ]; then
    echo "  PASS: $desc"
    ((PASS_COUNT++)) || true
  else
    echo "  FAIL: $desc (was empty)"
    ((FAIL_COUNT++)) || true
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    ((PASS_COUNT++)) || true
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    echo "  ACTUAL OUTPUT: $haystack"
    ((FAIL_COUNT++)) || true
  fi
}

test_summary() {
  echo ""
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CLI helpers (communicate with puremyhad via puremyha command)
# ---------------------------------------------------------------------------

cli_exec() {
  $COMPOSE exec -T puremyhad puremyha --json --socket /run/puremyhad.sock "$@"
}

cli_status() {
  cli_exec status
}

cli_topology() {
  cli_exec topology
}

cli_switchover() {
  local to_host="${1:-}"
  local dry_run="${2:-false}"
  local drain_timeout="${3:-}"
  local args=()
  [ -n "$to_host" ] && args+=(--to "$to_host")
  [ "$dry_run" = "true" ] && args+=(--dry-run)
  [ -n "$drain_timeout" ] && args+=(--drain-timeout "$drain_timeout")
  cli_exec switchover "${args[@]}"
}

cli_ack_recovery() {
  cli_exec ack-recovery
}

cli_demote() {
  local host="$1" source_host="$2"
  cli_exec demote --host "$host" --source "$source_host"
}

cli_pause_replica() {
  cli_exec pause-replica --host "$1"
}

cli_resume_replica() {
  cli_exec resume-replica --host "$1"
}

cli_pause_failover() {
  cli_exec pause-failover
}

cli_resume_failover() {
  cli_exec resume-failover
}

cli_errant_gtid() {
  cli_exec errant-gtid
}

cli_fix_errant_gtid() {
  cli_exec fix-errant-gtid
}

cli_unfence() {
  local host="$1"
  cli_exec unfence --host "$host"
}

# ---------------------------------------------------------------------------
# HTTP helpers (communicate with puremyhad via HTTP)
# ---------------------------------------------------------------------------

http_get() {
  local path="$1"
  $COMPOSE exec -T puremyhad curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080${path}"
}

http_get_body() {
  local path="$1"
  $COMPOSE exec -T puremyhad curl -s "http://127.0.0.1:8080${path}"
}

# Extract fields from CLI status response
get_health() {
  cli_status | jq -r '.[0].health // empty' 2>/dev/null || echo ""
}

get_source_host() {
  cli_status | jq -r '.[0].sourceHost // empty' 2>/dev/null || echo ""
}

get_node_count() {
  cli_status | jq -r '.[0].nodeCount // empty' 2>/dev/null || echo ""
}

get_paused() {
  cli_status | jq -r '.[0].paused // empty' 2>/dev/null || echo ""
}

get_recovery_blocked() {
  cli_status | jq -r '.[0].recoveryBlockedUntil // "null"' 2>/dev/null || echo "null"
}

# ---------------------------------------------------------------------------
# MySQL helpers
# ---------------------------------------------------------------------------

mysql_exec() {
  local container="$1"; shift
  $COMPOSE exec -T "$container" mysql -uroot -prootpass -N -e "$*" 2>/dev/null
}

mysql_exec_verbose() {
  local container="$1"; shift
  $COMPOSE exec -T "$container" mysql -uroot -prootpass -N -e "$*"
}

mysql_exec_puremyha() {
  local container="$1"; shift
  $COMPOSE exec -T "$container" mysql -upuremyha -ppuremyha_pass -N -e "$*" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------

wait_for_mysql() {
  local container="$1"
  local max_wait="${2:-60}"
  echo "  Waiting for $container to be ready..."
  for i in $(seq 1 "$max_wait"); do
    if $COMPOSE exec -T "$container" mysqladmin ping -uroot -prootpass &>/dev/null; then
      echo "  $container is ready (${i}s)"
      return 0
    fi
    sleep 1
  done
  echo "  TIMEOUT waiting for $container (${max_wait}s)" >&2
  return 1
}

wait_for_replication() {
  local container="$1"
  local max_wait="${2:-60}"
  echo "  Waiting for replication on $container..."
  for i in $(seq 1 "$max_wait"); do
    local status
    status=$($COMPOSE exec -T "$container" mysql -uroot -prootpass -N -e \
      "SELECT rcs.SERVICE_STATE, ras.SERVICE_STATE FROM performance_schema.replication_connection_status rcs JOIN performance_schema.replication_applier_status ras ON 1=1 LIMIT 1;" 2>/dev/null || echo "")
    if echo "$status" | grep -q "ON.*ON"; then
      echo "  Replication running on $container (${i}s)"
      return 0
    fi
    sleep 1
  done
  echo "  TIMEOUT waiting for replication on $container (${max_wait}s)" >&2
  return 1
}

wait_for_health() {
  local expected="$1"
  local max_wait="${2:-30}"
  echo "  Waiting for health=$expected..."
  for i in $(seq 1 "$max_wait"); do
    local health
    health=$(get_health)
    if [ "$health" = "$expected" ]; then
      echo "  Health is $expected (${i}s)"
      return 0
    fi
    sleep 1
  done
  local actual
  actual=$(get_health)
  echo "  TIMEOUT: expected health=$expected, got '$actual' (${max_wait}s)" >&2
  return 1
}

wait_for_source() {
  local expected="$1"
  local max_wait="${2:-30}"
  echo "  Waiting for source=$expected..."
  for i in $(seq 1 "$max_wait"); do
    local source
    source=$(get_source_host)
    if [ "$source" = "$expected" ]; then
      echo "  Source is $expected (${i}s)"
      return 0
    fi
    sleep 1
  done
  local actual
  actual=$(get_source_host)
  echo "  TIMEOUT: expected source=$expected, got '$actual' (${max_wait}s)" >&2
  return 1
}

# Wait for health to NOT be a given value (transition away)
wait_for_health_not() {
  local unexpected="$1"
  local max_wait="${2:-30}"
  echo "  Waiting for health != $unexpected..."
  for i in $(seq 1 "$max_wait"); do
    local health
    health=$(get_health)
    if [ -n "$health" ] && [ "$health" != "$unexpected" ]; then
      echo "  Health transitioned to $health (${i}s)"
      return 0
    fi
    sleep 1
  done
  echo "  TIMEOUT: health still $unexpected (${max_wait}s)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Cluster setup / reset
# ---------------------------------------------------------------------------

setup_replication() {
  echo "Setting up replication..."
  for replica in mysql-replica1 mysql-replica2; do
    echo "  Configuring $replica..."
    local ok=0
    for attempt in $(seq 1 5); do
      if mysql_exec_verbose "$replica" "
        STOP REPLICA;
        RESET BINARY LOGS AND GTIDS;
        CHANGE REPLICATION SOURCE TO
          SOURCE_HOST='mysql-source',
          SOURCE_PORT=3306,
          SOURCE_USER='repl',
          SOURCE_PASSWORD='repl_pass',
          SOURCE_AUTO_POSITION=1,
          GET_SOURCE_PUBLIC_KEY=1,
          SOURCE_CONNECT_RETRY=1;
        START REPLICA;
      "; then
        ok=1
        break
      fi
      echo "  Attempt $attempt failed for $replica, retrying in 3s..."
      sleep 3
    done
    if [ "$ok" -ne 1 ]; then
      echo "  ERROR: Failed to configure replication on $replica after 5 attempts" >&2
      return 1
    fi
  done
  wait_for_replication mysql-replica1 60
  wait_for_replication mysql-replica2 60
  echo "Replication setup complete."
}

# Reset cluster to original state between tests.
# This attempts a best-effort restore: start any stopped containers,
# unpause any paused containers, reconfigure replication to point at
# mysql-source, and clear recovery blocks.
reset_cluster() {
  echo "Resetting cluster..."

  # Unpause any paused containers
  docker unpause e2e-source 2>/dev/null || true
  docker unpause e2e-replica1 2>/dev/null || true
  docker unpause e2e-replica2 2>/dev/null || true

  # Start any stopped containers
  $COMPOSE start mysql-source 2>/dev/null || true
  $COMPOSE start mysql-replica1 2>/dev/null || true
  $COMPOSE start mysql-replica2 2>/dev/null || true

  # Wait for all MySQL containers
  wait_for_mysql mysql-source 60
  wait_for_mysql mysql-replica1 60
  wait_for_mysql mysql-replica2 60

  # Ensure source has correct read_only setting and clean GTID/replica state
  mysql_exec mysql-source "STOP REPLICA; RESET REPLICA ALL;" || true
  mysql_exec mysql-source "SET GLOBAL read_only = OFF;" || true
  mysql_exec mysql-source "RESET BINARY LOGS AND GTIDS;" || true

  # Ensure replicas are read_only (clear any fence state first so CHANGE REPLICATION SOURCE TO succeeds)
  mysql_exec mysql-replica1 "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = ON;" || true
  mysql_exec mysql-replica2 "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = ON;" || true

  # Reconfigure replication on both replicas to point at mysql-source
  for replica in mysql-replica1 mysql-replica2; do
    mysql_exec "$replica" "
      STOP REPLICA;
      RESET REPLICA ALL;
      RESET BINARY LOGS AND GTIDS;
      CHANGE REPLICATION SOURCE TO
        SOURCE_HOST='mysql-source',
        SOURCE_PORT=3306,
        SOURCE_USER='repl',
        SOURCE_PASSWORD='repl_pass',
        SOURCE_AUTO_POSITION=1,
        GET_SOURCE_PUBLIC_KEY=1,
        SOURCE_CONNECT_RETRY=1;
      START REPLICA;
    " || true
  done

  wait_for_replication mysql-replica1 60 || true
  wait_for_replication mysql-replica2 60 || true

  # Clear recovery block and resume failover via CLI
  cli_ack_recovery >/dev/null 2>&1 || true
  cli_resume_failover >/dev/null 2>&1 || true

  # Clear hook marker files
  $COMPOSE exec -T puremyhad rm -f /tmp/hook_*.log 2>/dev/null || true

  # Wait for daemon to see healthy state with mysql-source as source.
  # After a failover in a previous test, workers need time to re-probe and
  # detect the reconfigured topology (mysql-source = actual source).
  wait_for_health "Healthy" 60
  wait_for_source "mysql-source" 30 || true

  echo "Cluster reset complete."
}
