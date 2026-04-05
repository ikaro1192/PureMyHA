{-# LANGUAGE StrictData #-}
module PureMyHA.Monitor.Event
  ( MonitorEvent (..)
  , StateEffect (..)
  , applyEvent
  , decideClusterActions
  , decideLagActions
  ) where

import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (UTCTime)
import PureMyHA.Config (FailureDetectionConfig (..), FailoverConfig (..), MonitoringConfig (..), AtLeastOne (..))
import PureMyHA.Monitor.Detector (detectClusterHealth, detectNodeHealth, identifySource)
import PureMyHA.MySQL.GTID (GtidSet)
import PureMyHA.Types

-- | Events representing raw facts produced by workers and operations.
-- Each event carries only the data observed by IO — all derived state
-- computation (health, thresholds, role inference) happens in the reducer.
data MonitorEvent
  = NodeProbed
      { neNodeId      :: NodeId
      , neProbeResult :: ProbeResult     -- ^ Raw probe outcome
      , neErrantGtids :: GtidSet         -- ^ Errant GTIDs from enrichment
      }
  | TopologyRefreshed
      { neMergedTopology :: ClusterTopology
      }
  | TopologyDriftUpdated
      { neDrift          :: Bool
      , neDriftConditions :: [DriftCondition]
      }
  | FailoverCommitted
      { neNewSourceId        :: NodeId
      , neOldSourceIds       :: [NodeId]
      , neFailoverAt         :: UTCTime
      , neRecoveryBlockUntil :: UTCTime
      }
  | NodeFenced
      { neFencedNodeId :: NodeId
      }
  | NodeUnfenced
      { neUnfencedNodeId :: NodeId
      }
  | NodeDemoted
      { neDemotedNodeId :: NodeId
      }
  | SwitchoverCommitted
      { neSwNewSourceId :: NodeId
      , neSwOldSourceId :: Maybe NodeId
      }
  | ReplicaPaused
      { nePausedNodeId :: NodeId
      }
  | ReplicaResumed
      { neResumedNodeId :: NodeId
      }
  | RecoveryBlockCleared
  | FailoverPaused
  | FailoverResumed
  deriving (Show)

-- | Side effects emitted by the reducer, to be executed asynchronously
-- by the stateManager after applying the state transition.
data StateEffect
  = FireHookEffect HookEvent (Maybe NodeId)
  | TriggerActionEffect ClusterAction
  | LogHealthTransition ClusterName T.Text
  deriving (Eq, Show)

-- | Pure reducer: apply an event to the current cluster topology.
-- Returns the new topology and a list of side effects to execute asynchronously.
--
-- This function integrates all state-dependent logic:
-- - Consecutive failure counting and threshold suppression
-- - Node health detection
-- - Role inference and preservation
-- - Cluster-level health recomputation
-- - Hook/action decision making
applyEvent
  :: FailureDetectionConfig
  -> FailoverConfig
  -> MonitoringConfig
  -> ClusterTopology
  -> MonitorEvent
  -> (ClusterTopology, [StateEffect])

-- NodeProbed: the most complex case. Integrates failure counting,
-- health detection, role/pause/fence preservation, cluster health
-- recomputation, and hook/action decisions.
applyEvent fdc fc mc ct (NodeProbed nid probeResult errantGtids) =
  let -- 1. Read current node state
      mOldNs = Map.lookup nid (ctNodes ct)

      -- 2. Consecutive failure counting (reducer owns this)
      prevFailures = maybe 0 nsConsecutiveFailures mOldNs
      newFailures = case probeResult of
        ProbeFailure{} -> prevFailures + 1
        ProbeSuccess{} -> 0

      -- 3. Role inference from probe result
      inferredRole = case probeResult of
        ProbeSuccess{prReplicaStatus = Nothing} -> Source
        ProbeSuccess{prReplicaStatus = Just _}  -> Replica
        ProbeFailure{} -> maybe Replica nsRole mOldNs

      -- 4. Build raw node state
      rawNs = NodeState
        { nsNodeId              = nid
        , nsRole                = inferredRole
        , nsHealth              = Healthy   -- placeholder, computed below
        , nsProbeResult         = probeResult
        , nsErrantGtids         = errantGtids
        , nsPaused              = False     -- placeholder, preserved below
        , nsConsecutiveFailures = newFailures
        , nsFenced              = False     -- placeholder, preserved below
        }

      -- 5. Detect node health
      lagThreshold = Just (round (realToFrac (mcReplicationLagCritical mc) :: Double) :: Int)
      healthNs = rawNs { nsHealth = detectNodeHealth lagThreshold rawNs }

      -- 6. Suppress below threshold
      threshold = unAtLeastOne (fdcConsecutiveFailuresForDead fdc)
      suppressed
        | newFailures > 0 && newFailures < threshold =
            healthNs { nsHealth = maybe Healthy nsHealth mOldNs }
        | otherwise = healthNs

      -- 7. Preserve nsPaused, nsFenced, and conditionally nsRole
      --    (replicates updateNodeStatePreserveRole logic)
      preserveRole = isJust (ctRecoveryBlockedUntil ct)
      finalNs = suppressed
        { nsRole   = if preserveRole
                       then maybe (nsRole suppressed) nsRole mOldNs
                       else nsRole suppressed
        , nsPaused = maybe (nsPaused suppressed) nsPaused mOldNs
        , nsFenced = maybe (nsFenced suppressed) nsFenced mOldNs
        }

      -- 8. Update node map
      newNodes = Map.insert nid finalNs (ctNodes ct)

      -- 9. Below-threshold failure log
      belowThresholdLog
        | newFailures > 0 && newFailures < threshold =
            case probeResult of
              ProbeFailure{prConnectError = err} ->
                [LogHealthTransition (ctClusterName ct) $
                  "Node " <> unHostName (nodeHost nid)
                  <> " probe failed (" <> T.pack (show newFailures) <> "/"
                  <> T.pack (show threshold) <> "): " <> err]
              _ -> []
        | otherwise = []

      -- 10. Node health transition log
      nodeHealthLog = case (fmap nsHealth mOldNs, nsHealth finalNs) of
        (Just Healthy, newH) | Just err <- healthErrorMessage newH ->
          [LogHealthTransition (ctClusterName ct) $
            "Node " <> unHostName (nodeHost nid) <> " unreachable: " <> err]
        (Just oldH, Healthy) | isUnhealthy oldH ->
          [LogHealthTransition (ctClusterName ct) $
            "Node " <> unHostName (nodeHost nid) <> " recovered"]
        (Nothing, newH) | Just err <- healthErrorMessage newH ->
          [LogHealthTransition (ctClusterName ct) $
            "Node " <> unHostName (nodeHost nid) <> " initial connect failed: " <> err]
        _ -> []

      -- 11. Lag hook effects
      lagActions = decideLagActions (fmap nsHealth mOldNs) (nsHealth finalNs)
      lagEffects = [FireHookEffect e (Just nid) | FireHook e <- lagActions]

      -- 12. Cluster-level health recomputation
      minReplicas = fcMinReplicasForFailover fc
      newClusterHealth = detectClusterHealth minReplicas newNodes
      newSrcId = identifySource (Map.elems newNodes)
      observedHealthy = ctObservedHealthy ct || newClusterHealth == Healthy
      clusterTransitioned = ctHealth ct /= newClusterHealth

      -- 13. Cluster health transition log
      clusterHealthLog
        | clusterTransitioned =
            [LogHealthTransition (ctClusterName ct) $
              "Cluster health: " <> T.pack (show (ctHealth ct))
              <> " \x2192 " <> T.pack (show newClusterHealth)]
        | otherwise = []

      -- 14. Cluster-level action decisions
      clusterActions = decideClusterActions fc ct newClusterHealth
      clusterEffects =
        [FireHookEffect e Nothing | FireHook e <- clusterActions]
        ++ [TriggerActionEffect a | a <- clusterActions, isNotHook a]

      -- 15. Assemble new topology
      newCt = ct
        { ctNodes           = newNodes
        , ctHealth          = newClusterHealth
        , ctSourceNodeId    = newSrcId
        , ctObservedHealthy = observedHealthy
        }

      allEffects = belowThresholdLog ++ nodeHealthLog ++ lagEffects
                   ++ clusterHealthLog ++ clusterEffects

  in (newCt, allEffects)

-- TopologyRefreshed: merge new topology, preserving daemon-managed fields
applyEvent _ _ _ ct (TopologyRefreshed newTopo) =
  let merged = newTopo
        { ctObservedHealthy      = ctObservedHealthy ct || ctObservedHealthy newTopo
        , ctPaused               = ctPaused ct
        , ctTopologyDrift        = ctTopologyDrift ct
        , ctRecoveryBlockedUntil = ctRecoveryBlockedUntil ct
        , ctHealth               = ctHealth ct
        , ctSourceNodeId         = ctSourceNodeId ct
        , ctLastFailoverAt       = ctLastFailoverAt ct
        }
  in (merged, [])

-- TopologyDriftUpdated: set drift flag, fire per-condition hooks on False→True transition
applyEvent _ _ _ ct (TopologyDriftUpdated hasDrift driftConditions) =
  let wasInDrift = ctTopologyDrift ct
      newCt = ct { ctTopologyDrift = hasDrift }
      effects
        | hasDrift && not wasInDrift =
            [ FireHookEffect (OnTopologyDrift dt dd) Nothing
            | dc <- driftConditions
            , let (dt, dd) = renderDriftCondition dc
            ]
        | otherwise = []
  in (newCt, effects)

-- FailoverCommitted: atomic role swap + recovery block + timestamp
applyEvent _ _ _ ct (FailoverCommitted newSrcId oldSrcIds failoverAt recoveryBlockUntil) =
  let -- Demote old sources to Replica
      demoteNode nodes srcId = Map.adjust (\ns -> ns { nsRole = Replica }) srcId nodes
      demotedNodes = foldl demoteNode (ctNodes ct) oldSrcIds
      -- Promote new source
      promotedNodes = Map.adjust (\ns -> ns { nsRole = Source }) newSrcId demotedNodes
      newCt = ct
        { ctNodes                = promotedNodes
        , ctLastFailoverAt       = Just failoverAt
        , ctRecoveryBlockedUntil = Just recoveryBlockUntil
        }
  in (newCt, [])

-- NodeFenced: set nsFenced = True
applyEvent _ _ _ ct (NodeFenced nid) =
  let newCt = ct { ctNodes = Map.adjust (\ns -> ns { nsFenced = True }) nid (ctNodes ct) }
  in (newCt, [])

-- NodeUnfenced: set nsFenced = False
applyEvent _ _ _ ct (NodeUnfenced nid) =
  let newCt = ct { ctNodes = Map.adjust (\ns -> ns { nsFenced = False }) nid (ctNodes ct) }
  in (newCt, [])

-- NodeDemoted: set role to Replica
applyEvent _ _ _ ct (NodeDemoted nid) =
  let newCt = ct { ctNodes = Map.adjust (\ns -> ns { nsRole = Replica }) nid (ctNodes ct) }
  in (newCt, [])

-- SwitchoverCommitted: role swap
applyEvent _ _ _ ct (SwitchoverCommitted newSrcId mOldSrcId) =
  let demoted = case mOldSrcId of
        Just srcId -> Map.adjust (\ns -> ns { nsRole = Replica }) srcId (ctNodes ct)
        Nothing    -> ctNodes ct
      promoted = Map.adjust (\ns -> ns { nsRole = Source }) newSrcId demoted
      newCt = ct { ctNodes = promoted }
  in (newCt, [])

-- ReplicaPaused: set nsPaused = True
applyEvent _ _ _ ct (ReplicaPaused nid) =
  let newCt = ct { ctNodes = Map.adjust (\ns -> ns { nsPaused = True }) nid (ctNodes ct) }
  in (newCt, [])

-- ReplicaResumed: set nsPaused = False
applyEvent _ _ _ ct (ReplicaResumed nid) =
  let newCt = ct { ctNodes = Map.adjust (\ns -> ns { nsPaused = False }) nid (ctNodes ct) }
  in (newCt, [])

-- RecoveryBlockCleared
applyEvent _ _ _ ct RecoveryBlockCleared =
  (ct { ctRecoveryBlockedUntil = Nothing }, [])

-- FailoverPaused
applyEvent _ _ _ ct FailoverPaused =
  (ct { ctPaused = True }, [])

-- FailoverResumed
applyEvent _ _ _ ct FailoverResumed =
  (ct { ctPaused = False }, [])

-- Helper: reuse pure decision functions from Worker module
-- (inlined here to avoid circular imports)

decideLagActions :: Maybe NodeHealth -> NodeHealth -> [ClusterAction]
decideLagActions oldHealth newHealth = case (oldHealth, newHealth) of
  (Just (Lagging _), Lagging _) -> []
  (_, Lagging lag)              -> [FireHook (OnLagThresholdExceeded lag)]
  (Just (Lagging _), _)        -> [FireHook OnLagThresholdRecovered]
  _                             -> []

decideClusterActions :: FailoverConfig -> ClusterTopology -> NodeHealth -> [ClusterAction]
decideClusterActions fc topo newHealth =
  let transitioned    = ctHealth topo /= newHealth
      observedHealthy = fcFailoverWithoutObservedHealthy fc || ctObservedHealthy topo || newHealth == Healthy
      hookActions
        | transitioned = case newHealth of
            DeadSource               -> [FireHook (OnFailureDetection "DeadSource")]
            InsufficientQuorum       -> [FireHook (OnFailureDetection "InsufficientQuorum")]
            DeadSourceAndAllReplicas -> [FireHook (OnFailureDetection "DeadSourceAndAllReplicas")]
            _                        -> []
        | otherwise = []
      failoverActions =
        [ TriggerAutoFailover
        | newHealth == DeadSource, fcAutoFailover fc, observedHealthy ]
      fenceActions =
        [ TriggerAutoFence
        | transitioned, newHealth == SplitBrainSuspected, fcAutoFence fc, observedHealthy ]
      replicaCheckActions =
        [ TriggerEmergencyReplicaCheck
        | transitioned, newHealth == UnreachableSource ]
  in hookActions ++ failoverActions ++ fenceActions ++ replicaCheckActions

isNotHook :: ClusterAction -> Bool
isNotHook (FireHook _) = False
isNotHook _            = True
