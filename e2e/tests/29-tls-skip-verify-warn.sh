#!/usr/bin/env bash
# Test: TLS skip-verify WARN at startup and on SIGHUP (issue #185)
# Verifies that puremyhad emits a prominent WARN when a cluster is configured
# with tls.mode: skip-verify, both on daemon startup and on each SIGHUP reload.
# Requires the TLS environment (run via e2e/run-tls.sh); skips gracefully otherwise.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 29: TLS skip-verify WARN ==="

# Skip if not running in TLS environment (certificates not mounted)
if ! $COMPOSE exec -T mysql-source sh -c "test -f /etc/mysql/tls/ca-cert.pem" 2>/dev/null; then
  echo "  SKIP: TLS certificates not mounted — run via e2e/run-tls.sh"
  test_summary
  exit 0
fi

LOG_FILE=/var/log/puremyha.log
WARN_PATTERN="TLS mode 'skip-verify'"

count_warn_lines() {
  $COMPOSE exec -T puremyhad sh -c "grep -c \"$WARN_PATTERN\" $LOG_FILE || true" \
    | tr -d '[:space:]'
}

count_reload_lines() {
  $COMPOSE exec -T puremyhad sh -c "grep -c 'SIGHUP: config reloaded' $LOG_FILE || true" \
    | tr -d '[:space:]'
}

send_sighup() {
  $COMPOSE exec -T puremyhad sh -c 'kill -HUP $(pidof puremyhad)'
}

wait_for_reload_count() {
  local target="$1" max_wait="${2:-10}"
  for _ in $(seq 1 "$max_wait"); do
    local n
    n=$(count_reload_lines)
    if [ "${n:-0}" -ge "$target" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# --- Case 1: startup WARN is present -----------------------------------------
startup_warns=$(count_warn_lines)
startup_warns=${startup_warns:-0}
echo "  Startup '$WARN_PATTERN' count: $startup_warns"
if [ "$startup_warns" -ge 1 ]; then
  echo "  PASS: startup WARN for skip-verify present in daemon log"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: no startup WARN for skip-verify in $LOG_FILE"
  $COMPOSE exec -T puremyhad tail -n 40 "$LOG_FILE" || true
  ((FAIL_COUNT++)) || true
fi

# Confirm the cluster name is embedded in the WARN line (e.g. "[e2e]")
cluster_prefixed=$($COMPOSE exec -T puremyhad sh -c \
  "grep -c \"\[e2e\].*$WARN_PATTERN\" $LOG_FILE || true" | tr -d '[:space:]')
if [ "${cluster_prefixed:-0}" -ge 1 ]; then
  echo "  PASS: WARN line includes cluster name prefix"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: WARN line missing cluster name prefix"
  ((FAIL_COUNT++)) || true
fi

# --- Case 2: SIGHUP re-emits the WARN ----------------------------------------
reload_baseline=$(count_reload_lines)
reload_baseline=${reload_baseline:-0}
before=$startup_warns

send_sighup
if ! wait_for_reload_count "$((reload_baseline + 1))" 10; then
  echo "  FAIL: SIGHUP did not produce a reload log line within 10s"
  ((FAIL_COUNT++)) || true
else
  # Allow the reload worker to finish writing the WARN line after the atomically block
  sleep 1
  after=$(count_warn_lines)
  after=${after:-0}
  if [ "$after" -gt "$before" ]; then
    echo "  PASS: SIGHUP reload re-emitted skip-verify WARN ($before → $after)"
    ((PASS_COUNT++)) || true
  else
    echo "  FAIL: SIGHUP reload did not re-emit skip-verify WARN (still $after)"
    $COMPOSE exec -T puremyhad tail -n 40 "$LOG_FILE" || true
    ((FAIL_COUNT++)) || true
  fi
fi

test_summary
