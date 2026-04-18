#!/usr/bin/env bash
# Test: SIGHUP config reload (issue #182)
# Verifies that SIGHUP still triggers a config reload after the handler was
# rewritten to a tiny async-signal-safe signaller that delegates to a worker
# thread. Also verifies the worker keeps responding to subsequent SIGHUPs
# and that the daemon stays healthy through repeated signals.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 27: SIGHUP Config Reload ==="

LOG_FILE=/var/log/puremyha.log

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

wait_for_health "Healthy" 60

# Baseline: whatever reload events are already in the log (should be 0 on a
# fresh cluster but we don't assume).
baseline=$(count_reload_lines)
baseline=${baseline:-0}
echo "  Baseline 'SIGHUP: config reloaded' count: $baseline"

# --- First SIGHUP ------------------------------------------------------------
send_sighup
target=$((baseline + 1))
if wait_for_reload_count "$target" 10; then
  echo "  PASS: first SIGHUP produced a reload log line"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: first SIGHUP did not produce a reload log line within 10s"
  $COMPOSE exec -T puremyhad tail -n 40 "$LOG_FILE" || true
  ((FAIL_COUNT++)) || true
fi

health=$(get_health)
assert_eq "Daemon healthy after first SIGHUP" "Healthy" "$health"

# --- Second SIGHUP -----------------------------------------------------------
# Proves the worker is still blocked on takeMVar waiting for the next signal,
# not one-shot. Sleep briefly so the worker has finished the first reload.
sleep 2
send_sighup
target=$((baseline + 2))
if wait_for_reload_count "$target" 10; then
  echo "  PASS: second SIGHUP produced another reload log line"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: second SIGHUP did not produce another reload log line within 10s"
  $COMPOSE exec -T puremyhad tail -n 40 "$LOG_FILE" || true
  ((FAIL_COUNT++)) || true
fi

health=$(get_health)
assert_eq "Daemon healthy after second SIGHUP" "Healthy" "$health"

# --- SIGHUP burst ------------------------------------------------------------
# tryPutMVar coalesces extras, but the daemon must never crash regardless of
# signal frequency. Send a short burst and verify the daemon still responds.
for _ in 1 2 3 4 5; do
  send_sighup
done
sleep 3

health=$(get_health)
assert_eq "Daemon healthy after SIGHUP burst" "Healthy" "$health"

# At least one additional reload should have been observed from the burst.
after_burst=$(count_reload_lines)
after_burst=${after_burst:-0}
if [ "$after_burst" -gt $((baseline + 2)) ]; then
  echo "  PASS: SIGHUP burst produced at least one additional reload ($after_burst total)"
  ((PASS_COUNT++)) || true
else
  echo "  FAIL: no additional reload after SIGHUP burst (count still $after_burst)"
  ((FAIL_COUNT++)) || true
fi

test_summary
