# Failover Behavior

## Automatic Failover Flow

When `DeadSource` is detected, the daemon automatically:

1. Runs `pre_failover` hook
2. Selects the best replica (highest `Executed_Gtid_Set`, no errant GTIDs, respects `candidate_priority`)
3. Waits for the candidate to apply all retrieved GTIDs (`wait_for_relay_log_apply_timeout`, default 60 s)
4. Promotes: `STOP REPLICA` → `RESET REPLICA ALL` → `SET read_only=OFF`
5. Reconnects remaining replicas: `CHANGE REPLICATION SOURCE TO SOURCE_HOST=... SOURCE_USER=... SOURCE_PASSWORD=... SOURCE_AUTO_POSITION=1`
6. Runs `post_failover` hook
7. Sets `recovery_block_period` anti-flap timer

## Failure Scenarios

| Scenario | Definition |
|---------|------------|
| `Healthy` | Normal operation |
| `DeadSource` | Source unreachable and replicas confirm `Replica_IO_Running=No` |
| `UnreachableSource` | Source unreachable from PureMyHA, but replicas can still reach it (possible network partition) |
| `DeadSourceAndAllReplicas` | Source and all replicas are unresponsive |
| `SplitBrainSuspected` | Multiple nodes appear to be acting as source |
| `NodeUnreachable` | Probe connect failure (node is not responding) |
| `ReplicaIOStopped` | Replica IO thread stopped (with or without error) |
| `ReplicaIOConnecting` | Replica IO thread in Connecting state (transient) |
| `ReplicaSQLStopped` | Replica SQL thread stopped |
| `ErrantGtidDetected` | Errant GTIDs detected on the node |
| `NoSourceDetected` | No node has the source role in the cluster |
| `NeedsAttention` | Other unclassified anomaly (escape hatch) |

## Anti-Flap Protection

After a failover completes, automatic failover is blocked for `recovery_block_period` (default: 3600s). To re-enable it manually:

```bash
puremyha ack-recovery [--cluster=<name>]
```

## Errant GTID Detection & Repair

Errant GTIDs are detected automatically during candidate selection. They can also be managed manually:

```bash
# Detect errant GTIDs
puremyha errant-gtid [--cluster=<name>]

# Fix by injecting empty transactions on the source
puremyha fix-errant-gtid [--cluster=<name>]
```

## Auto-Fence Split-Brain

When `SplitBrainSuspected` is detected (multiple nodes acting as source), enabling `failover.auto_fence: true` causes the daemon to:

1. Wait 2× the monitoring interval so GTID data is fresh
2. Select the **survivor** — the source with the highest executed GTID count
3. Set `super_read_only=ON` on all other sources (fenced nodes)
4. Fire the `on_fence` hook for each fenced node

Auto-fence fires only on **transition** into `SplitBrainSuspected` to avoid re-fencing after an operator runs `unfence`.

### Recovery

After resolving data divergence and choosing which node's writes to keep:

```bash
# Re-enable writes on the recovered node
puremyha unfence --host <host>

# Then re-point replicas if needed
puremyha demote --host <old-source> --source <survivor> [--cluster=<name>]
```

> **Warning:** Always verify data consistency between fenced and survivor nodes before unfencing.
