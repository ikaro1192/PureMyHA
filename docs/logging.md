# Logging

PureMyHA writes structured, timestamped logs via [katip](https://hackage.haskell.org/package/katip). The log file path is configured with `logging.log_file` (default: `/var/log/puremyha.log`).

## Log Level

The minimum log level is set via `logging.log_level` in the config (default: `info`). Valid values: `debug`, `info`, `warn`, `error`.

```yaml
logging:
  log_level: info   # debug | info | warn | error
```

The level can also be changed at runtime without restarting the daemon:

```bash
# Increase verbosity for incident investigation
puremyha set-log-level debug

# Restore to normal
puremyha set-log-level info
```

The IPC override takes precedence until the next SIGHUP, which resets the level to whatever is in the config file.

## Logged Events

| Event | Level |
|-------|-------|
| Daemon started | Info |
| Node probe failed (below consecutive threshold) | Info |
| Node unreachable / connect failed (threshold reached) | Warn |
| Node recovered | Info |
| Auto-failover started / completed / failed | Info / Error |
| Switchover started / completed / failed | Info / Error |
| Config reloaded (SIGHUP) | Info |
| Config reload failed (SIGHUP) | Warn |
| Topology refresh: N new node(s) found | Info |
| Daemon shutting down | Info |

## Example Output

```
[2026-03-17 12:34:56 UTC] [Info] puremyhad started
[2026-03-17 12:35:01 UTC] [Warn] [main] Node db1 unreachable: Connection refused
[2026-03-17 12:35:10 UTC] [Info] [main] Auto-failover started
[2026-03-17 12:35:12 UTC] [Info] [main] Auto-failover completed: new source is db2
[2026-03-17 12:35:13 UTC] [Info] [main] Node db1 recovered
```

## Log Rotation

Send `SIGUSR1` to reopen the log file after rotation:

```bash
# logrotate postrotate example
kill -USR1 $(pidof puremyhad)
```
