# Configuration Reference

Default config path: `/etc/puremyha/config.yaml`

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

See [`config/config.yaml.example`](../config/config.yaml.example) for the complete annotated configuration file.

## Precedence Rules

`monitoring`, `failure_detection`, `failover`, and `hooks` can be set per-cluster or defined as defaults in the `global` section. Per-cluster settings take precedence over `global` on a section-by-section basis. `monitoring`, `failure_detection`, and `failover` are required in at least one of the two.

The `logging` section is optional and global (defaults to `/var/log/puremyha.log` and `log_level: info` when omitted).
