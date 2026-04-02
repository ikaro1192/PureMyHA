# Feature Reference

Full details for every PureMyHA feature. For a summary, see the [README Features section](../README.md#features).

---

## Topology & Discovery

### Topology Discovery
Recursively maps the replication tree starting from the configured seed hosts using `SHOW REPLICA STATUS`. Each node's role (source / replica), replication health, and GTID state is tracked continuously.

### Topology Auto-Discovery
At a configurable interval, PureMyHA queries each known node's `SHOW REPLICA STATUS` output to detect replicas that have joined the topology since startup. Newly discovered nodes are added to monitoring automatically without a daemon restart.

### MySQL 8.4 Native
PureMyHA targets MySQL 8.4+ exclusively and uses only modern syntax:
- `SHOW REPLICA STATUS` (not `SHOW SLAVE STATUS`)
- `CHANGE REPLICATION SOURCE TO` (not `CHANGE MASTER TO`)
- `caching_sha2_password` authentication (default in MySQL 8.4); `mysql_native_password` is not supported

---

## Failover & Safety

### Automatic Failover
When a `DeadSource` scenario is detected (source unreachable **and** replicas confirm `Replica_IO_Running=No` **and** witness count meets `min_replicas_for_failover` quorum), PureMyHA automatically:

1. Runs the `pre_failover` hook
2. Selects the best replica (highest `Executed_Gtid_Set`, no errant GTIDs, respects `candidate_priority`)
3. Waits for the candidate to apply all retrieved GTIDs (`wait_for_relay_log_apply_timeout`, default 60s)
4. Promotes: `STOP REPLICA` → `RESET REPLICA ALL` → `SET read_only=OFF`
5. Reconnects remaining replicas with `SOURCE_AUTO_POSITION=1`
6. Runs the `post_failover` hook
7. Sets the `recovery_block_period` anti-flap timer

See [docs/failover.md](failover.md) for full failure scenario definitions.

### Manual Switchover
A planned promotion with zero-data-loss semantics. PureMyHA waits for the target replica to be fully caught up before promoting it.

```bash
puremyha switchover [--to=<host>]
puremyha switchover --dry-run   # preview candidate selection without executing any SQL
```

### Errant GTID Detection & Repair
PureMyHA detects errant GTIDs (transactions present on a replica but absent from the source's `Executed_Gtid_Set`) and repairs them by injecting empty transactions to neutralise them before promotion.

### Consecutive Failure Threshold
To prevent failover on transient TCP timeouts or momentary MySQL unresponsiveness, PureMyHA requires **N consecutive probe failures** before marking a node dead.

| Config key | Default | Scope |
|---|---|---|
| `failure_detection.consecutive_failures_for_dead` | `3` | global / per-cluster |

### Anti-Flap Protection
After an automatic failover completes, further automatic failovers are blocked for `recovery_block_period`. This prevents repeated failover loops when a cluster is in an unstable state.

| Config key | Default | Scope |
|---|---|---|
| `failure_detection.recovery_block_period` | `3600s` | global / per-cluster |

To re-enable automatic failover before the period expires:

```bash
puremyha resume-failover --cluster <name>
```

### Auto-Fence Split-Brain
When `SplitBrainSuspected` is detected (multiple nodes appear to be acting as source), PureMyHA can automatically set `super_read_only=ON` on all non-survivor sources to prevent write divergence.

| Config key | Default |
|---|---|
| `failover.auto_fence` | `false` |

To recover a fenced host after the split-brain is resolved:

```bash
puremyha unfence --host <host>
```

### Graceful Shutdown
On `SIGTERM` or `SIGINT`, the daemon cleans up the Unix socket file and exits cleanly. In-progress failover operations are allowed to complete.

---

## Replica Health

### Replica Lag Monitoring
Two independent lag thresholds govern replica health and candidate selection:

| Config key | Effect |
|---|---|
| `monitoring.replication_lag_critical` | Replica transitions to `Lagging` health and is excluded from all failover candidates |
| `failover.max_replica_lag_for_candidate` | Stricter threshold applied during candidate selection only (does not change health state) |

When a replica crosses `replication_lag_critical`, the `on_lag_threshold_exceeded` hook fires. When it recovers, `on_lag_threshold_recovered` fires.

### Replica Re-seeding via CLONE Plugin
Re-seeds a replica from a donor node using the MySQL CLONE plugin. When `--donor` is omitted, PureMyHA auto-selects the donor with the highest GTID transaction count.

```bash
puremyha clone --target <host> [--donor <host>]
```

---

## Observability & Integrations

### HTTP Endpoints
When `http.enabled: true` is set, `puremyhad` exposes a lightweight read-only HTTP listener (default port 8080). All endpoints are `GET`-only.

| Endpoint | Use case |
|---|---|
| `GET /health` | Kubernetes liveness probe; `503` if no cluster is `Healthy` |
| `GET /cluster/:name/status` | Readiness probe / load balancer routing |
| `GET /cluster/:name/topology` | Monitoring dashboards |
| `GET /metrics` | Prometheus scraping |

See [docs/http-api.md](http-api.md) for full response schemas and examples.

### Prometheus Metrics
`GET /metrics` exposes the following in Prometheus text exposition format:
- Cluster health state
- Per-node replication lag
- Per-node consecutive failure count
- Per-node role (source / replica)

### Hooks
Shell hooks are called at key lifecycle events. All hooks receive cluster and node context as environment variables.

| Hook | Trigger |
|---|---|
| `pre_failover` | Before automatic failover begins |
| `post_failover` | After automatic failover completes |
| `pre_switchover` | Before manual switchover begins |
| `post_switchover` | After manual switchover completes |
| `on_lag_threshold_exceeded` | Replica crosses `replication_lag_critical` — provides `PUREMYHA_NODE` (replica hostname) and `PUREMYHA_LAG_SECONDS` |
| `on_lag_threshold_recovered` | Replica recovers below `replication_lag_critical` — provides `PUREMYHA_NODE` (replica hostname) |

See [docs/configuration.md](configuration.md) for hook configuration syntax.

### Optional TLS
Per-cluster TLS for MySQL connections. Supports `require_secure_transport=ON`.

| Mode | Behaviour |
|---|---|
| `disabled` | Plain text (default) |
| `skip-verify` | TLS, server certificate not verified |
| `verify-ca` | TLS, CA certificate verified |
| `verify-full` | TLS, CA + hostname verified |

Minimum TLS version is configurable: `"1.2"` or `"1.3"`.

---

## Operator Controls

### Config Hot-Reload
Send `SIGHUP` to the daemon to reload `monitoring` and `hooks` configuration for all clusters without a restart. Changes to `clusters`, `credentials`, or `global` structural settings require a full restart.

```bash
kill -HUP $(pidof puremyhad)
# or
systemctl reload puremyhad
```

### Pause / Resume Auto-Failover
Temporarily disable automatic failover cluster-wide for planned maintenance windows without stopping the daemon.

```bash
puremyha pause-failover --cluster <name>
puremyha resume-failover --cluster <name>
```

### Runtime Log Level Control
Change log verbosity at runtime without restarting the daemon.

```bash
puremyha set-log-level debug|info|warn|error
```

See [docs/logging.md](logging.md) for log levels, structured event fields, and log rotation setup.

### Config Validation
Validate the configuration file offline without a running daemon.

```bash
puremyha validate-config [--config /path/to/config.yaml]
```

See [docs/configuration.md](configuration.md) for the full configuration reference.
