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
GRANT PROCESS                 ON *.* TO 'puremyha'@'%';  -- performance_schema.processlist (topology discovery)
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

## Hooks

Shell scripts invoked at key lifecycle events. See [docs/features.md](features.md#hooks) for the full list of hooks.

### Security requirements

`puremyhad` typically runs as root, so every configured hook script is validated each time it is about to be executed. A hook is refused if any of these checks fail:

- **Absolute path** — relative paths are rejected.
- **Regular file** — symlinks, directories, and device files are rejected. Symlinks are explicitly disallowed to prevent TOCTOU swaps after config load.
- **Trusted owner** — the file's owner UID must be 0 (root) or the UID running `puremyhad`.
- **Not world-writable** — `mode & 0o002` must be zero.

The recommended install is `chown root:root` and `chmod 0755` for every hook script, living in a directory that is itself not world-writable.

A rejected `pre_failover` or `pre_switchover` hook aborts the operation (because the operator explicitly opted into a pre-check that cannot be trusted). A rejected fire-and-forget hook is logged and skipped; the surrounding operation continues.

### `hook_timeout`

```yaml
hooks:
  hook_timeout: 30s   # default: 30s
```

Maximum wall-clock time for any single hook invocation. On overrun the daemon:

1. sends `SIGTERM` to the hook's process group (the child is started as a new group leader so any subprocesses it forked are included),
2. waits up to 2 seconds for the group to exit,
3. sends `SIGKILL` to the group, reaps the child, and returns an error.

This prevents a stuck pre-hook from indefinitely blocking failover and prevents fire-and-forget hooks from leaking processes.

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

## Permanent Promotion Exclusion (never_promote)

`failover.never_promote` permanently excludes specific hosts from being selected as failover or switchover candidates. These nodes continue to be monitored and replicate normally but are never promoted to source.

```yaml
failover:
  never_promote:
    - db3-analytics   # analytics replica, backup node, or delayed replication target
```

**Behavior:**

- Excluded from automatic failover candidate selection (`selectCandidate`)
- `switchover --to <host>` is rejected with a clear error message if the target is in `never_promote`
- The node continues to replicate and appears in `status` / `topology` output
- Hot-reloadable via SIGHUP (same as other `failover` settings)
- If all eligible candidates are excluded or unavailable, failover fails with a clear log message

**Difference from `candidate_priority`:** `candidate_priority` controls promotion *ordering*; `never_promote` provides hard *exclusion* regardless of priority or availability.

| Field | Type | Default | Description |
|---|---|---|---|
| `never_promote` | list of strings | `[]` | Host names permanently excluded from promotion |
