# CLI Reference

## Global Flags

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--socket PATH` | — | `/run/puremyhad.sock` | Daemon socket path |
| `--cluster NAME` | `-C` | — | Target cluster (omit to apply to all) |
| `--json` | `-j` | — | Output in JSON format instead of text |

## Commands

```bash
# Show topology and node health
puremyha status

# Show replication tree
puremyha topology

# Manual switchover (planned maintenance)
puremyha switchover [--to=<host>] [--cluster=<name>]

# Dry-run: show which replica would be promoted without executing
puremyha switchover --dry-run [--to=<host>]

# Acknowledge recovery block (re-enable auto-failover after anti-flap period)
puremyha ack-recovery [--cluster=<name>]

# Detect errant GTIDs
puremyha errant-gtid [--cluster=<name>]

# Fix errant GTIDs by injecting empty transactions
puremyha fix-errant-gtid [--cluster=<name>]

# Demote a node to replica under a specified source (resolve split-brain)
puremyha demote --host db1 --source db2 [--cluster=<name>]

# Pause replication on a replica (STOP REPLICA + stop monitoring)
puremyha pause-replica --host db2 [--cluster=<name>]

# Resume replication on a paused replica (START REPLICA + resume monitoring)
puremyha resume-replica --host db2 [--cluster=<name>]

# Trigger manual topology discovery
puremyha discovery [--cluster=<name>]

# Pause automatic failover (e.g. during maintenance)
puremyha pause-failover [--cluster=<name>]

# Resume automatic failover
puremyha resume-failover [--cluster=<name>]

# Change daemon log level at runtime (no restart required)
# IPC override takes precedence until the next SIGHUP
puremyha set-log-level debug|info|warn|error

# Validate config file without connecting to the daemon
# Checks YAML syntax, required fields, and semantic constraints (port ranges, threshold ordering, etc.)
puremyha validate-config [--config /etc/puremyha/config.yaml]
```

## JSON Output

Use `--json` / `-j` for scripting and Prometheus exporters:

```bash
# JSON output
puremyha --json status
puremyha -j topology
puremyha -j errant-gtid
puremyha -j switchover --to db2

# Pipe to jq
puremyha -j status | jq '.[0].health'
puremyha -j topology | jq '.[0].nodes[].host'

# validate-config JSON output
puremyha --json validate-config --config /etc/puremyha/config.yaml
# → {"valid":true} or {"valid":false,"errors":["cluster 'main': node port 99999 is out of range (1-65535)",...]}
```

## Daemon Signals

| Signal | Effect |
|--------|--------|
| `SIGTERM` / `SIGINT` | Graceful shutdown — stops all workers and removes the socket file |
| `SIGHUP` | Hot-reload `monitoring`, `hooks`, `http`, and `log_level` config without restart |
| `SIGUSR1` | Reopen the log file (for log rotation tools such as logrotate) |

```bash
# Reload config (e.g. after editing intervals, hooks, or log_level)
systemctl reload puremyhad        # via systemd (preferred)
kill -HUP $(pidof puremyhad)      # direct signal (non-systemd)

# Graceful stop
kill -TERM $(pidof puremyhad)
```
