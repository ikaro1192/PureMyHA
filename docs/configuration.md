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

#### Optional: CLONE plugin support

To use `puremyha clone` for re-seeding replicas via the MySQL CLONE plugin, grant the following additional privileges to the monitoring user:

```sql
GRANT BACKUP_ADMIN ON *.* TO 'puremyha'@'%';  -- connect as clone user on the donor
GRANT CLONE_ADMIN  ON *.* TO 'puremyha'@'%';  -- execute CLONE INSTANCE FROM on the recipient
```

These privileges are **not required** for normal HA operations and can be omitted if you do not use the `clone` command.

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

## TLS

PureMyHA supports optional TLS for MySQL connections on a per-cluster basis via the `tls:` key.

```yaml
tls:
  mode: verify-ca                              # disabled | skip-verify | verify-ca | verify-full
  min_version: "1.2"                           # optional; "1.2" (default) | "1.3"
  ca_cert: /etc/puremyha/tls/ca-cert.pem      # required for verify-ca / verify-full
  client_cert: /etc/puremyha/tls/client.pem   # optional (mutual TLS)
  client_key: /etc/puremyha/tls/client-key.pem
```

| Field | Values | Default |
|---|---|---|
| `mode` | `disabled` / `skip-verify` / `verify-ca` / `verify-full` | `disabled` |
| `min_version` | `"1.2"` / `"1.3"` | `"1.2"` (allows TLS 1.2 and 1.3) |
| `ca_cert` | File path | — (required for `verify-ca` / `verify-full`) |
| `client_cert` | File path | — (optional, mutual TLS) |
| `client_key` | File path | — (optional, mutual TLS) |

When `mode` is not `disabled`, PureMyHA sends a MySQL SSL_REQUEST packet before the authentication handshake, compatible with `require_secure_transport=ON`.

## Auto-Fence Split-Brain

When `failover.auto_fence: true` is set, PureMyHA automatically sets `super_read_only=ON` on all non-survivor source nodes when `SplitBrainSuspected` is detected. The survivor is the node with the highest executed GTID transaction count.

```yaml
failover:
  auto_fence: false   # default: false
```

The `on_fence` hook fires fire-and-forget after each successful fence:

```yaml
hooks:
  on_fence: /etc/puremyha/hooks/on_fence.sh
  # Env: PUREMYHA_CLUSTER, PUREMYHA_OLD_SOURCE (fenced host), PUREMYHA_NEW_SOURCE (survivor host)
```

To clear `super_read_only` after verifying data consistency:

```bash
puremyha unfence --host <host>
```
