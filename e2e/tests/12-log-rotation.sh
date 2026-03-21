#!/usr/bin/env bash
# Test: Log Rotation (SIGUSR1)
# Simulates logrotate behavior: renames the log file, sends SIGUSR1,
# and verifies the daemon reopens a new log file and keeps running.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 12: Log Rotation ==="

LOG_FILE=/var/log/puremyha.log
LOG_ROTATED=/var/log/puremyha.log.1

wait_for_health "Healthy" 60

# Clean up any leftover rotated log from a previous run
$COMPOSE exec -T puremyhad rm -f "$LOG_ROTATED" 2>/dev/null || true

# Verify log file exists and has content before rotation
log_exists=$($COMPOSE exec -T puremyhad ls "$LOG_FILE" 2>/dev/null || echo "")
assert_not_empty "Log file exists before rotation" "$log_exists"

# Simulate logrotate 'create' method: rename current log file
$COMPOSE exec -T puremyhad mv "$LOG_FILE" "$LOG_ROTATED"

# Send SIGUSR1 to daemon to reopen the log file
$COMPOSE exec -T puremyhad sh -c 'kill -USR1 $(pidof puremyhad)'

# Wait for daemon to reopen and write to the new log file
# (the handler itself logs "SIGUSR1: log file reopened" immediately after reopening)
sleep 2

# Verify new log file was created after SIGUSR1
new_log=$($COMPOSE exec -T puremyhad cat "$LOG_FILE" 2>/dev/null || echo "")
assert_not_empty "New log file created after SIGUSR1" "$new_log"

# Verify rotated log still has original content
rotated_log=$($COMPOSE exec -T puremyhad cat "$LOG_ROTATED" 2>/dev/null || echo "")
assert_not_empty "Rotated log retains original content" "$rotated_log"

# Verify daemon is still healthy via IPC
health=$(get_health)
assert_eq "Daemon still healthy after log rotation" "Healthy" "$health"

test_summary
