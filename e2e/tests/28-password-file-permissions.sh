#!/usr/bin/env bash
# Test: Password File Permissions
#
# Verifies that puremyhad refuses to start when a configured password_file
# is world- or group-accessible, or owned by an untrusted user. A password
# file holds MySQL credentials; the daemon must fail loudly at startup
# rather than silently accept a misconfigured (e.g. 0644) deployment.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 28: Password File Permissions ==="

# ---------------------------------------------------------------------------
# 1. Happy path: the image-baked password files must have the strict mode
#    and ownership that the validator requires. This doubles as a regression
#    guard against future Dockerfile changes.
# ---------------------------------------------------------------------------
wait_for_health "Healthy" 60

for pass in mysql.pass repl.pass; do
  mode=$($COMPOSE exec -T puremyhad stat -c '%a' /etc/puremyha-secrets/$pass | tr -d '\r')
  assert_eq "$pass mode is 0600" "600" "$mode"

  owner=$($COMPOSE exec -T puremyhad stat -c '%U:%G' /etc/puremyha-secrets/$pass | tr -d '\r')
  assert_eq "$pass owned by root:root" "root:root" "$owner"
done

# ---------------------------------------------------------------------------
# 2. Negative: daemon must refuse to start with a 0644 password file.
#    We spawn a one-shot puremyhad against a throwaway config rather than
#    restarting the long-running daemon container.
# ---------------------------------------------------------------------------
$COMPOSE exec -T puremyhad sh -c '
  set -e
  mkdir -p /tmp/pwtest
  echo "pw" > /tmp/pwtest/bad.pass
  chmod 0644 /tmp/pwtest/bad.pass
  cat > /tmp/pwtest/bad.yaml <<EOF
clusters:
  - name: perm-test
    nodes:
      - host: mysql-source
        port: 3306
    credentials:
      user: puremyha
      password_file: /tmp/pwtest/bad.pass

global:
  monitoring:
    interval: 1s
    connect_timeout: 2s
    replication_lag_warning: 5s
    replication_lag_critical: 10s
  failure_detection:
    recovery_block_period: 30s
  failover:
    auto_failover: false
EOF
'

exit_code=0
output=$($COMPOSE exec -T puremyhad puremyhad \
  --config /tmp/pwtest/bad.yaml \
  --socket /tmp/pwtest/sock 2>&1) || exit_code=$?

assert_neq "daemon exits non-zero with 0644 password file" "0" "$exit_code"
assert_contains "daemon error mentions group/other access" "group or other" "$output"
assert_contains "daemon error names the offending path" "/tmp/pwtest/bad.pass" "$output"

# ---------------------------------------------------------------------------
# 3. Negative: daemon must also refuse a 0640 (group-readable) file.
# ---------------------------------------------------------------------------
$COMPOSE exec -T puremyhad chmod 0640 /tmp/pwtest/bad.pass

exit_code=0
output=$($COMPOSE exec -T puremyhad puremyhad \
  --config /tmp/pwtest/bad.yaml \
  --socket /tmp/pwtest/sock 2>&1) || exit_code=$?

assert_neq "daemon exits non-zero with 0640 password file" "0" "$exit_code"
assert_contains "daemon error mentions group/other access (0640)" "group or other" "$output"

# ---------------------------------------------------------------------------
# 4. Positive control: flipping the same file to 0600 lets the daemon
#    advance past password loading. It will still fail afterwards (the yaml
#    has no such MySQL user), but the failure must NOT be the permission
#    rejection. We assert that "group or other" does not appear.
# ---------------------------------------------------------------------------
$COMPOSE exec -T puremyhad chmod 0600 /tmp/pwtest/bad.pass

exit_code=0
output=$($COMPOSE exec -T puremyhad timeout 3 puremyhad \
  --config /tmp/pwtest/bad.yaml \
  --socket /tmp/pwtest/sock 2>&1) || exit_code=$?

if echo "$output" | grep -qF "group or other"; then
  echo "  FAIL: 0600 password file still triggered the permission rejection"
  echo "  ACTUAL: $output"
  ((FAIL_COUNT++)) || true
else
  echo "  PASS: 0600 password file bypasses the permission check"
  ((PASS_COUNT++)) || true
fi

# Clean up test artefacts so re-runs start fresh
$COMPOSE exec -T puremyhad rm -rf /tmp/pwtest 2>/dev/null || true

test_summary
