# Development

## Build & Test

```bash
# Build
cabal build all

# Run tests
cabal test

# Run with a local config
cabal run puremyhad -- --config config/config.yaml.example
```

## E2E Tests

The `e2e/` directory contains a Docker Compose based end-to-end test framework. It spins up a real MySQL 8.4 GTID-replication cluster (1 source + 2 replicas) and runs failover scenarios against the `puremyhad` daemon.

**Prerequisites:** Docker and Docker Compose.

```bash
cd e2e

# Run all tests
make e2e

# Run a specific test (e.g., auto-failover only)
make e2e-test T=02

# Follow puremyhad logs (useful for debugging)
make e2e-logs

# Check container status
make e2e-status

# Tear down the environment
make e2e-clean
```

### Test scenarios

There are test scripts in `e2e/tests/`. Filenames are self-documenting (e.g. `01-topology-discovery.sh`, `10-pause-resume-failover.sh`).

The test environment uses accelerated timings (`interval: 1s`, `recovery_block_period: 30s`) so the full suite completes in a few minutes. Cluster state is automatically reset between tests.

