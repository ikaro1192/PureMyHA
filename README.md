# PureMyHA

A simple, pure-Haskell High Availability tool for MySQL 8.4 replication topologies.

Inspired by the design philosophy of Orchestrator, PureMyHA provides topology discovery, failure detection, and automatic failover — with no C library dependencies.

## Features

- **Topology Discovery** — Recursively maps replication trees from seed hosts via `SHOW REPLICA STATUS`
- **Automatic Failover** — Detects dead sources and promotes the best replica (GTID-aware, errant-GTID-safe)
- **Manual Switchover** — Planned maintenance with zero-data-loss semantics
- **Errant GTID Detection & Repair** — Identifies and fixes errant GTIDs via empty transactions
- **Anti-Flap Protection** — Blocks repeated automatic failovers via configurable `recovery_block_period`
- **Hook Support** — Pre/post hooks for failover and switchover events
- **MySQL 8.4 Native** — Uses only modern syntax (`SHOW REPLICA STATUS`, `CHANGE REPLICATION SOURCE TO`, etc.)

## Requirements

- **MySQL**: 8.4+ with GTID enabled (`gtid_mode=ON`, `enforce_gtid_consistency=ON`)
- **OS**: Linux
- **Haskell**: GHC 9.x+, Cabal 3.0+
- **HA for PureMyHA itself**: Pacemaker + QDevice (recommended)

### MySQL Privileges

```sql
GRANT REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'purermyha'@'%';
GRANT SUPER ON *.* TO 'purermyha'@'%';
-- Or fine-grained privileges (MySQL 8.0+):
GRANT REPLICATION_SLAVE_ADMIN, REPLICATION_APPLIER ON *.* TO 'purermyha'@'%';
GRANT SYSTEM_VARIABLES_ADMIN ON *.* TO 'purermyha'@'%';
```

## Architecture

```
┌─────────────────┐     Unix socket      ┌──────────────────┐
│   purermyhad    │◄────────────────────►│   purermyha      │
│   (daemon)      │  /run/purermyhad.sock │   (CLI)          │
└─────────────────┘                      └──────────────────┘
        │
        │  per-node goroutines (STM)
        ▼
┌──────────────────────────────────┐
│  MySQL Cluster                   │
│  db1 (source) ── db2 (replica)   │
└──────────────────────────────────┘
```

| Component    | Role |
|-------------|------|
| `purermyhad` | Long-running daemon. Topology monitoring, failure detection, automatic failover |
| `purermyha`  | CLI tool. Status display and manual operations |

Daemon and CLI communicate over a Unix domain socket (`/run/purermyhad.sock`) using newline-delimited JSON.

### Daemon HA with Pacemaker

```
Node1 (Active)  ─── Corosync/Pacemaker ───  Node2 (Standby)
                            │
                       QDevice (quorum arbiter)
```

PureMyHA does **not** implement leader election itself — it delegates entirely to Pacemaker. Daemon state is held in memory only and rebuilt from MySQL on restart.

## Installation

```bash
git clone https://github.com/yourorg/PureMyHA.git
cd PureMyHA
cabal build all
cabal install purermyhad purermyha
```

## Configuration

Default path: `/etc/purermyha/config.yaml`

```yaml
clusters:
  - name: main
    nodes:
      - host: db1
        port: 3306
      - host: db2
        port: 3306
    credentials:
      user: purermyha
      password_file: /etc/purermyha/mysql.pass

monitoring:
  interval: 3s
  connect_timeout: 2s
  replication_lag_warning: 10s
  replication_lag_critical: 30s

failure_detection:
  recovery_block_period: 3600s   # Block auto-failover for this long after a failover

failover:
  auto_failover: true
  min_replicas_for_failover: 1
  candidate_priority:            # Optional promotion priority (auto-selected by GTID if omitted)
    - host: db2

hooks:
  pre_failover: /etc/purermyha/hooks/pre_failover.sh
  post_failover: /etc/purermyha/hooks/post_failover.sh
  pre_switchover: /etc/purermyha/hooks/pre_switchover.sh
  post_switchover: /etc/purermyha/hooks/post_switchover.sh
```

See `config/config.yaml.example` for a full annotated example.

## Usage

### Start the daemon

```bash
purermyhad --config /etc/purermyha/config.yaml
```

### Global flags

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--socket PATH` | — | `/run/purermyhad.sock` | Daemon socket path |
| `--cluster NAME` | `-C` | — | Target cluster (omit to apply to all) |
| `--json` | `-j` | — | Output in JSON format instead of text |

### CLI commands

```bash
# Show topology and node health
purermyha status

# Show replication tree
purermyha topology

# Manual switchover (planned maintenance)
purermyha switchover [--to=<host>] [--cluster=<name>]

# Acknowledge recovery block (re-enable auto-failover after anti-flap period)
purermyha ack-recovery [--cluster=<name>]

# Detect errant GTIDs
purermyha errant-gtid [--cluster=<name>]

# Fix errant GTIDs by injecting empty transactions
purermyha fix-errant-gtid [--cluster=<name>]

# JSON output (for scripting / Prometheus exporters)
purermyha --json status
purermyha -j topology
purermyha -j errant-gtid
purermyha -j switchover --to db2

# Pipe to jq
purermyha -j status | jq '.[0].health'
purermyha -j topology | jq '.[0].nodes[].host'
```

## Failover Flow

When `DeadSource` is detected, the daemon automatically:

1. Runs `pre_failover` hook
2. Selects the best replica (highest `Executed_Gtid_Set`, no errant GTIDs, respects `candidate_priority`)
3. Promotes: `STOP REPLICA` → `RESET REPLICA ALL` → `SET read_only=OFF`
4. Reconnects remaining replicas: `CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1`
5. Runs `post_failover` hook
6. Sets `recovery_block_period` anti-flap timer

## Failure Scenarios

| Scenario | Definition |
|---------|------------|
| `Healthy` | Normal operation |
| `DeadSource` | Source unreachable and replicas confirm `Replica_IO_Running=No` |
| `UnreachableSource` | Source unreachable from PureMyHA, but replicas can still reach it (possible network partition) |
| `DeadSourceAndAllReplicas` | Source and all replicas are unresponsive |
| `SplitBrainSuspected` | Multiple nodes appear to be acting as source |
| `NeedsAttention` | Other anomaly (errant GTIDs, stale replication, etc.) |

## Technology Stack

| Purpose | Library |
|---------|---------|
| MySQL connectivity | `mysql-haskell` (pure Haskell, no C library dependency) |
| Configuration | `yaml` + `optparse-applicative` |
| Concurrency | `async` + `STM` (each node monitored in an independent thread) |
| Logging | `katip` (structured logging with JSON output) |
| IPC | Unix domain socket, newline-delimited JSON |

## Development

```bash
# Build
cabal build all

# Run tests
cabal test

# Run with a local config
cabal run purermyhad -- --config config/config.yaml.example
```

## License

MIT
