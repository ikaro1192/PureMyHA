#!/usr/bin/env bash
# E2E coverage collection script for PureMyHA
# Builds with HPC instrumentation, runs E2E tests, extracts .tix, and generates report.
#
# Usage:
#   ./collect-coverage.sh          # Run all E2E tests with coverage
#   ./collect-coverage.sh 02       # Run only test 02 with coverage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export COMPOSE="docker compose -f docker-compose.yml -f docker-compose.coverage.yml"
COVERAGE_DIR="${SCRIPT_DIR}/coverage-output"

mkdir -p "$COVERAGE_DIR"

cleanup() {
  echo ""
  echo "=== Tearing down E2E coverage environment ==="
  $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building E2E environment with HPC coverage ==="
$COMPOSE build

echo "=== Running E2E tests ==="
# run-all.sh reads COMPOSE from environment
SKIP_TEARDOWN=1 bash run-all.sh "$@" && E2E_OK=true || E2E_OK=false

echo ""
echo "=== Stopping puremyhad gracefully (SIGTERM -> .tix flush) ==="
# docker stop sends SIGTERM first; puremyhad handles it and exits cleanly,
# causing the GHC runtime to write the .tix file.
$COMPOSE stop -t 30 puremyhad

echo "=== Extracting .tix file ==="
if docker cp e2e-puremyhad:/coverage/puremyhad.tix "$COVERAGE_DIR/e2e.tix" 2>/dev/null; then
  echo "  .tix saved to: $COVERAGE_DIR/e2e.tix"
else
  echo "ERROR: No .tix file found. puremyhad may not have exited cleanly."
  echo "  Check: docker logs e2e-puremyhad"
  exit 1
fi

echo "=== Extracting .mix files ==="
rm -rf "$COVERAGE_DIR/hpc-mix"
if docker cp e2e-puremyhad:/hpc-mix "$COVERAGE_DIR/hpc-mix" 2>/dev/null; then
  echo "  .mix files saved to: $COVERAGE_DIR/hpc-mix/"
else
  echo "WARNING: Could not extract .mix files. hpc report will not work."
fi

# Find .mix directory for hpc report
MIX_DIR=""
if [ -d "$COVERAGE_DIR/hpc-mix" ]; then
  MIX_DIR="$COVERAGE_DIR/hpc-mix"
fi

echo ""
echo "========================================="
echo "  E2E Coverage Results"
echo "========================================="

if [ -n "$MIX_DIR" ]; then
  echo ""
  echo "=== HPC Report (E2E only) ==="
  hpc report "$COVERAGE_DIR/e2e.tix" --hpcdir="$MIX_DIR" --exclude=Main --per-module 2>&1 || \
    echo "(hpc report failed — .mix paths may need adjustment)"
fi

# If unit test .tix exists, merge them
UNIT_TIX=""
UNIT_TIX=$(find "$SCRIPT_DIR/../dist-newstyle" -name "*.tix" -path "*/hpc/vanilla/tix/*" 2>/dev/null | head -1) || true

if [ -n "$UNIT_TIX" ]; then
  echo ""
  echo "=== Merging with unit test .tix ==="
  echo "  Unit .tix: $UNIT_TIX"
  echo "  E2E  .tix: $COVERAGE_DIR/e2e.tix"
  if hpc sum --union --output="$COVERAGE_DIR/merged.tix" "$UNIT_TIX" "$COVERAGE_DIR/e2e.tix" 2>&1; then
    echo "  Merged .tix saved to: $COVERAGE_DIR/merged.tix"

    if [ -n "$MIX_DIR" ]; then
      # For merged report, we may also need the unit test .mix directory
      UNIT_MIX_DIR=""
      UNIT_MIX_FILE=$(find "$SCRIPT_DIR/../dist-newstyle" -name "*.mix" \
        -path "*/t/puremyha-test/*" 2>/dev/null | head -1) || true
      if [ -n "$UNIT_MIX_FILE" ]; then
        UNIT_MIX_DIR="$(dirname "$(dirname "$UNIT_MIX_FILE")")"
      fi

      echo ""
      echo "=== HPC Report (Unit + E2E merged) ==="
      HPC_DIRS="--hpcdir=$MIX_DIR"
      if [ -n "$UNIT_MIX_DIR" ]; then
        HPC_DIRS="$HPC_DIRS --hpcdir=$UNIT_MIX_DIR"
      fi
      hpc report "$COVERAGE_DIR/merged.tix" $HPC_DIRS --exclude=Main --per-module 2>&1 || \
        echo "(hpc report failed — .mix paths may need adjustment)"
    fi
  else
    echo "  WARNING: hpc sum failed. Possibly incompatible .tix files."
  fi
else
  echo ""
  echo "NOTE: No unit test .tix found. Run 'cabal test --enable-coverage' first to enable merging."
fi

echo ""
if [ "$E2E_OK" = true ]; then
  echo "All E2E tests passed. Coverage data collected successfully."
else
  echo "Some E2E tests failed, but coverage data was still collected."
  exit 1
fi
