#!/usr/bin/env bash
# Test: validate-config command
# Verifies that puremyha validate-config correctly validates config files
# without requiring a daemon connection.
set -euo pipefail
source "$(dirname "$0")/../lib/helpers.sh"
echo "=== Test 16: Config Validation ==="

# 1. Valid config succeeds
output=$($COMPOSE exec -T puremyhad puremyha validate-config --config /etc/puremyha/puremyha.yaml)
assert_contains "valid config outputs success message" "Config is valid" "$output"

# 2. Valid config with --json outputs valid=true
output=$($COMPOSE exec -T puremyhad puremyha --json validate-config --config /etc/puremyha/puremyha.yaml)
assert_eq "valid config JSON valid=true" "true" "$(echo "$output" | jq -r '.valid')"

# 3. YAML syntax error exits 1
exit_code=0
$COMPOSE exec -T puremyhad puremyha validate-config --config /etc/puremyha/invalid-syntax.yaml \
  || exit_code=$?
assert_eq "YAML syntax error exits 1" "1" "$exit_code"

# 4. YAML syntax error with --json outputs valid=false
exit_code=0
output=$($COMPOSE exec -T puremyhad puremyha --json validate-config \
  --config /etc/puremyha/invalid-syntax.yaml 2>&1) || exit_code=$?
assert_eq "YAML syntax error JSON exits 1" "1" "$exit_code"
assert_eq "YAML syntax error JSON valid=false" "false" "$(echo "$output" | jq -r '.valid')"

# 5. Semantic error exits 1 and mentions the offending field
exit_code=0
output=$($COMPOSE exec -T puremyhad puremyha validate-config \
  --config /etc/puremyha/invalid-semantic.yaml 2>&1) || exit_code=$?
assert_eq "semantic error exits 1" "1" "$exit_code"
assert_contains "semantic error mentions port" "port" "$output"

# 6. Semantic error with --json outputs valid=false
exit_code=0
output=$($COMPOSE exec -T puremyhad puremyha --json validate-config \
  --config /etc/puremyha/invalid-semantic.yaml 2>&1) || exit_code=$?
assert_eq "semantic error JSON exits 1" "1" "$exit_code"
assert_eq "semantic error JSON valid=false" "false" "$(echo "$output" | jq -r '.valid')"

# 7. Non-existent file exits 1
exit_code=0
$COMPOSE exec -T puremyhad puremyha validate-config \
  --config /etc/puremyha/does-not-exist.yaml || exit_code=$?
assert_eq "nonexistent file exits 1" "1" "$exit_code"

test_summary
