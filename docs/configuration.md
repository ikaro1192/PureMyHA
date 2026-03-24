# Configuration Reference

Default config path: `/etc/puremyha/config.yaml`

See `config/config.yaml.example` for a full annotated example.

## MySQL Users

PureMyHA uses two distinct MySQL users.

### Monitoring / management user

Connects to every node for health checks, topology discovery, and failover operations.

```sql
CREATE USER 'puremyha'@'%' IDENTIFIED BY '...';

-- Fine-grained privileges (MySQL 8.0+, recommended):
GRANT REPLICATION CLIENT      ON *.* TO 'puremyha'@'%';  -- SHOW REPLICA STATUS, SHOW REPLICAS
GRANT PROCESS                 ON *.* TO 'puremyha'@'%';  -- SHOW PROCESSLIST (topology discovery)
GRANT REPLICATION_SLAVE_ADMIN ON *.* TO 'puremyha'@'%';  -- STOP/START REPLICA, RESET REPLICA ALL, CHANGE REPLICATION SOURCE TO
GRANT SYSTEM_VARIABLES_ADMIN  ON *.* TO 'puremyha'@'%';  -- SET GLOBAL read_only
GRANT REPLICATION_APPLIER     ON *.* TO 'puremyha'@'%';  -- SET GTID_NEXT (errant GTID repair)

-- Or with the legacy SUPER privilege:
-- GRANT REPLICATION CLIENT, SUPER ON *.* TO 'puremyha'@'%';
```

### Replication user

Used as `SOURCE_USER` in `CHANGE REPLICATION SOURCE TO` when reconnecting replicas after a failover or switchover. This is the same user already configured on each replica's `CHANGE REPLICATION SOURCE TO` statement.

```sql
CREATE USER 'repl'@'%' IDENTIFIED BY '...';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
```

> **Note:** If you use the same account for both monitoring and replication, omit `replication_credentials` from the config. PureMyHA will fall back to `credentials` automatically.

## Full Configuration Reference

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
    replication_credentials:           # Optional; falls back to credentials if omitted
      user: repl
      password_file: /etc/puremyha/repl.pass
    # monitoring / failure_detection / failover / hooks can be specified here
    # to override the global defaults for this cluster only.

global:
  monitoring:
    interval: 3s
    connect_timeout: 2s
    replication_lag_warning: 10s
    replication_lag_critical: 30s
    discovery_interval: 300s   # Optional; 0s = disabled. Default: 300s
  failure_detection:
    recovery_block_period: 3600s   # Block auto-failover for this long after a failover
    consecutive_failures_for_dead: 3  # Require N consecutive probe failures before marking a node dead (default: 3)
  failover:
    auto_failover: true
    min_replicas_for_failover: 1
    wait_for_relay_log_apply_timeout: 60s  # Optional; default: 60s
    candidate_priority:            # Optional promotion priority (auto-selected by GTID if omitted)
      - host: db2
  hooks:
    pre_failover: /etc/puremyha/hooks/pre_failover.sh
    post_failover: /etc/puremyha/hooks/post_failover.sh
    pre_switchover: /etc/puremyha/hooks/pre_switchover.sh
    post_switchover: /etc/puremyha/hooks/post_switchover.sh
    on_failure_detection: /etc/puremyha/hooks/on_failure_detection.sh    # Optional
    post_unsuccessful_failover: /etc/puremyha/hooks/post_unsuccessful_failover.sh  # Optional

http:                                  # Optional HTTP server (disabled by default)
  enabled: false
  listen_address: "127.0.0.1"        # Use "0.0.0.0" to listen on all interfaces
  port: 8080
  # Endpoints (read-only, GET only):
  #   GET /health                 → 200 {"status":"ok"} / 503 {"status":"degraded"}
  #   GET /cluster/:name/status   → ClusterStatus JSON
  #   GET /cluster/:name/topology → ClusterTopologyView JSON
  #   GET /metrics                → Prometheus text format metrics (all clusters)

logging:
  log_file: /var/log/puremyha.log  # Optional; defaults to /var/log/puremyha.log
  log_level: info                   # Optional; debug | info | warn | error (default: info)
```

## Precedence Rules

`monitoring`, `failure_detection`, `failover`, and `hooks` can be set per-cluster or defined as defaults in the `global` section. Per-cluster settings take precedence over `global` on a section-by-section basis. `monitoring`, `failure_detection`, and `failover` are required in at least one of the two.

The `logging` section is optional and global (defaults to `/var/log/puremyha.log` and `log_level: info` when omitted).
