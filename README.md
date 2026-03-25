# PureMyHA

[![CI](https://github.com/ikaro1192/PureMyHA/actions/workflows/ci.yml/badge.svg)](https://github.com/ikaro1192/PureMyHA/actions/workflows/ci.yml)
[![codecov](https://codecov.io/github/ikaro1192/PureMyHA/graph/badge.svg?token=9G8GHTASEX)](https://codecov.io/github/ikaro1192/PureMyHA)
[![Release](https://img.shields.io/github/v/release/ikaro1192/PureMyHA)](https://github.com/ikaro1192/PureMyHA/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Haskell](https://img.shields.io/badge/language-Haskell-5D4F85)](https://www.haskell.org/)

A simple, pure-Haskell High Availability tool for MySQL 8.4 replication topologies.

Inspired by the design philosophy of Orchestrator, PureMyHA provides topology discovery, failure detection, and automatic failover — with no C library dependencies.

## Philosophy

- **Pure Haskell, no C dependencies** — PureMyHA is built entirely on `mysql-haskell`, a pure-Haskell MySQL client. No libmysqlclient, no CGo, no FFI — just a single statically-linked binary that runs anywhere.
- **Correctness before convenience** — Every failover decision is GTID-aware: errant GTIDs are detected and repaired, relay log apply is awaited before promotion, and split-brain scenarios are identified before acting. A failover that corrupts data is worse than no failover.
- **Simple by deliberate omission** — PureMyHA targets MySQL 8.4+ exclusively and does not support legacy syntax, older authentication plugins, or non-GTID topologies. Saying no to compatibility layers keeps the code small, auditable, and correct.
- **Do one thing well** — PureMyHA is a focused HA tool, not a topology manager, query router, or schema migration framework. It detects failure, promotes a replica, and gets out of the way.
- **Delegate what you do not own** — PureMyHA does not implement leader election for itself. Its own high availability is delegated entirely to Pacemaker, which is already purpose-built for that problem.
- **Stateless by design** — The daemon holds no durable state. All topology knowledge is derived from MySQL on startup and continuously refreshed at runtime, making recovery from a daemon crash trivially safe.
- **Transparent operation** — Dry-run mode, config hot-reload, and pause/resume controls give operators full visibility and control without requiring a daemon restart.

## Features

- **Topology Discovery** — Recursively maps replication trees from seed hosts via `SHOW REPLICA STATUS`
- **Automatic Failover** — Detects dead sources and promotes the best replica (GTID-aware, errant-GTID-safe, waits for relay log apply)
- **Manual Switchover** — Planned maintenance with zero-data-loss semantics
- **Errant GTID Detection & Repair** — Identifies and fixes errant GTIDs via empty transactions
- **Consecutive Failure Threshold** — Requires N consecutive probe failures before marking a node dead, preventing failover on transient TCP timeouts or momentary MySQL unresponsiveness (configurable `consecutive_failures_for_dead`, default 3)
- **Anti-Flap Protection** — Blocks repeated automatic failovers via configurable `recovery_block_period`
- **Hook Support** — Pre/post hooks for failover and switchover events
- **Optional TLS** — Per-cluster TLS for MySQL connections (`disabled` / `skip-verify` / `verify-ca` / `verify-full`), supports `require_secure_transport=ON`; minimum TLS version configurable (`"1.2"` / `"1.3"`)
- **MySQL 8.4 Native** — Uses only modern syntax (`SHOW REPLICA STATUS`, `CHANGE REPLICATION SOURCE TO`, etc.)
- **Graceful Shutdown** — Cleans up the socket file and exits on SIGTERM/SIGINT
- **Config Hot-Reload** — Reloads `monitoring` and `hooks` config per cluster on SIGHUP without restart
- **Topology Auto-Discovery** — Automatically detects and begins monitoring new nodes at a configurable interval
- **Dry-run Mode** — Run `switchover --dry-run` to preview the candidate selection without executing any SQL
- **Pause/Resume Auto-Failover** — Temporarily disable automatic failover for maintenance windows
- **HTTP Health Check Endpoint** — Optional read-only HTTP listener for load balancer probes and Kubernetes liveness/readiness checks (`GET /health`, `/cluster/:name/status`, `/cluster/:name/topology`)
- **Prometheus Metrics Endpoint** — `GET /metrics` exposes cluster health, replication lag, consecutive failures, and node role in Prometheus text exposition format for Grafana and other monitoring stacks
- **Runtime Log Level Control** — Change log verbosity without restarting the daemon via `puremyha set-log-level debug|info|warn|error`
- **Config Validation** — `puremyha validate-config` validates the config file offline (no daemon required)

## Requirements

- **MySQL**: 8.4+ with GTID enabled (`gtid_mode=ON`, `enforce_gtid_consistency=ON`) and `caching_sha2_password` authentication (default in MySQL 8.4). `mysql_native_password` is not supported.
- **OS**: Linux
- **HA for PureMyHA itself** *(optional)*: Pacemaker + QDevice (recommended) or VIP-watching cron / systemd.timer (simple)

See [docs/configuration.md](docs/configuration.md) for required MySQL user privileges and full configuration reference.

## Architecture

```mermaid
graph LR
    CLI["puremyha (CLI)"] <-->|"Unix socket\n/run/puremyhad.sock"| Daemon["puremyhad (daemon)"]
    LB["Load balancer / K8s probe"] -->|"HTTP :8080\n(read-only)"| Daemon
    Daemon -->|"per-node threads (STM)"| db1["db1 (source)"]
    db1 -->|replication| db2["db2 (replica)"]
```

| Component    | Role |
|-------------|------|
| `puremyhad` | Long-running daemon. Topology monitoring, failure detection, automatic failover |
| `puremyha`  | CLI tool. Status display and manual operations |

Daemon and CLI communicate over a Unix domain socket (`/run/puremyhad.sock`) using newline-delimited JSON.
An optional HTTP listener (disabled by default) exposes read-only health check endpoints for external probes.

PureMyHA does **not** implement leader election itself. See [docs/daemon-ha.md](docs/daemon-ha.md) for Pacemaker and VIP-watching setup instructions.

## Installation

### From packages (recommended)

Download the latest release from the [Releases page](https://github.com/ikaro1192/PureMyHA/releases).

#### Debian / Ubuntu

```bash
sudo dpkg -i puremyha_<VERSION>_amd64.deb    # x86_64
sudo dpkg -i puremyha_<VERSION>_arm64.deb    # aarch64
```

#### RHEL / Rocky / AlmaLinux

```bash
sudo rpm -ivh puremyha-<VERSION>-1.x86_64.rpm   # x86_64
sudo rpm -ivh puremyha-<VERSION>-1.aarch64.rpm  # aarch64
```

#### Post-install setup

```bash
# Copy the example config and edit it
sudo cp /etc/puremyha/config.yaml.example /etc/puremyha/config.yaml
sudo vi /etc/puremyha/config.yaml

# Enable and start the daemon
sudo systemctl enable --now puremyhad
```

### From source

- **Build requirements:** GHC 9.x+ and Cabal 3.0+ (not needed for package installs)

```bash
git clone https://github.com/ikaro1192/PureMyHA
cd PureMyHA
cabal build all
cabal install puremyhad puremyha
```

### Docker build (Linux binary)

Build Linux binaries without installing GHC locally.

```bash
# Build (tests run automatically during build)
docker build -t puremyha .

# Extract binaries
mkdir -p dist-bins
docker create --name tmp puremyha
docker cp tmp:/usr/bin/puremyha ./dist-bins/
docker cp tmp:/usr/sbin/puremyhad ./dist-bins/
docker rm tmp
```

## Configuration

```yaml
clusters:
  - name: main
    nodes:
      - host: db1
        port: 3306
      - host: db2
        port: 3306
    credentials:
      user: puremyha
      password_file: /etc/puremyha/mysql.pass

global:
  monitoring:
    interval: 3s
    connect_timeout: 2s
  failure_detection:
    consecutive_failures_for_dead: 3
    recovery_block_period: 3600s
  failover:
    auto_failover: true
    min_replicas_for_failover: 1
```

See [docs/configuration.md](docs/configuration.md) for the full configuration reference including all fields, per-cluster overrides, and MySQL user setup.

## Usage

```bash
# Start the daemon
puremyhad --config /etc/puremyha/config.yaml

# Show topology and node health
puremyha status

# Show replication tree
puremyha topology

# Manual switchover (planned maintenance)
puremyha switchover [--to=<host>]

# Validate config file offline
puremyha validate-config
```

See [docs/cli.md](docs/cli.md) for the full CLI reference including all commands, global flags, and JSON output examples.

## Documentation

- [docs/configuration.md](docs/configuration.md) — Full configuration reference and MySQL user setup
- [docs/cli.md](docs/cli.md) — CLI commands and global flags
- [docs/http-api.md](docs/http-api.md) — HTTP health check and Prometheus metrics endpoints
- [docs/logging.md](docs/logging.md) — Log levels, events, and log rotation
- [docs/failover.md](docs/failover.md) — Failover flow and failure scenarios
- [docs/daemon-ha.md](docs/daemon-ha.md) — Daemon HA setup (Pacemaker and VIP-watching)
- [docs/development.md](docs/development.md) — Build instructions and E2E test setup

## Technology Stack

| Purpose | Library |
|---------|---------|
| MySQL connectivity | `mysql-haskell` (pure Haskell, no C library dependency) + custom `caching_sha2_password` auth + optional TLS (1.2 / 1.3) |
| Configuration | `yaml` + `optparse-applicative` |
| Concurrency | `async` + `STM` (each node monitored in an independent thread) |
| Logging | `katip` (structured logging with JSON output) |
| IPC | Unix domain socket, newline-delimited JSON |
| HTTP health checks | `warp` + `wai` (pure Haskell, optional read-only listener) |

## Development

See [docs/development.md](docs/development.md) for build instructions, unit tests, and E2E test setup.

## License

MIT
