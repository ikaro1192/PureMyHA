module PureMyHA.EventSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, fromGregorian, UTCTime (..), addUTCTime)
import Test.Hspec

import Fixtures
import PureMyHA.Config
import PureMyHA.Supervisor.Event
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.Types

fixedTime2 :: UTCTime
fixedTime2 = UTCTime (fromGregorian 2024 1 2) 0

testFdc :: FailureDetectionConfig
testFdc = FailureDetectionConfig 300 (AtLeastOne 3)

testFc :: FailoverConfig
testFc = FailoverConfig AutoFailoverOn 1 [] 60 FenceManual Nothing [] AllowUnobserved

testMc :: MonitoringConfig
testMc = MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1

mkTopo :: Map.Map NodeId NodeState -> ClusterTopology
mkTopo nodes = ClusterTopology
  { ctClusterName           = "test"
  , ctNodes                 = nodes
  , ctSourceNodeId          = Nothing
  , ctHealth                = Healthy
  , ctObservedHealthy       = HasBeenObservedHealthy
  , ctRecoveryBlockedUntil  = Nothing
  , ctLastFailoverAt        = Nothing
  , ctPaused                = Running
  , ctTopologyDrift         = NoDrift
  , ctLastEmergencyCheckAt  = Nothing
  }

sourceId :: NodeId
sourceId = nsNodeId healthySource

replicaId :: NodeId
replicaId = nsNodeId healthyReplica

spec :: Spec
spec = describe "PureMyHA.Supervisor.Event" $ do

  describe "applyEvent NodeProbed" $ do
    let baseNodes = clusterHealthy
        baseTopo  = mkTopo baseNodes

    it "resets nsConsecutiveFailures to 0 on ProbeSuccess" $ do
      let withFailures = Map.adjust (\ns -> ns { nsConsecutiveFailures = 5 }) replicaId baseNodes
          topo = baseTopo { ctNodes = withFailures }
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsConsecutiveFailures mNs `shouldBe` Just 0

    it "increments nsConsecutiveFailures on ProbeFailure" $ do
      let withFailures = Map.adjust (\ns -> ns { nsConsecutiveFailures = 2 }) replicaId baseNodes
          topo = baseTopo { ctNodes = withFailures }
          event = NodeProbed replicaId (ProbeFailure "Connection refused") emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsConsecutiveFailures mNs `shouldBe` Just 3

    it "suppresses unhealthy state when below threshold" $ do
      let -- Node has 1 consecutive failure, threshold is 3
          withFailures = Map.adjust (\ns -> ns { nsConsecutiveFailures = 1, nsHealth = Healthy }) replicaId baseNodes
          topo = baseTopo { ctNodes = withFailures }
          event = NodeProbed replicaId (ProbeFailure "timeout") emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      -- 2nd failure, still below threshold of 3 -> health preserved as Healthy
      fmap nsHealth mNs `shouldBe` Just Healthy
      fmap nsConsecutiveFailures mNs `shouldBe` Just 2

    it "applies unhealthy state when at threshold" $ do
      let withFailures = Map.adjust (\ns -> ns { nsConsecutiveFailures = 2, nsHealth = Healthy }) replicaId baseNodes
          topo = baseTopo { ctNodes = withFailures }
          event = NodeProbed replicaId (ProbeFailure "timeout") emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      -- 3rd failure = threshold -> health NOT suppressed
      fmap nsHealth mNs `shouldBe` Just (NodeUnreachable "timeout")
      fmap nsConsecutiveFailures mNs `shouldBe` Just 3

    it "preserves nsPaused from current state" $ do
      let paused = Map.adjust (\ns -> ns { nsPaused = Paused }) replicaId baseNodes
          topo = baseTopo { ctNodes = paused }
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsPaused mNs `shouldBe` Just Paused

    it "preserves nsFenced from current state" $ do
      let fenced = Map.adjust (\ns -> ns { nsFenced = Fenced }) replicaId baseNodes
          topo = baseTopo { ctNodes = fenced }
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsFenced mNs `shouldBe` Just Fenced

    it "preserves nsRole during recovery block" $ do
      let -- Replica was promoted to Source by failover, recovery block active
          promoted = Map.adjust (\ns -> ns { nsRole = Source }) replicaId baseNodes
          topo = baseTopo { ctNodes = promoted, ctRecoveryBlockedUntil = Just fixedTime2 }
          -- Probe sees the node as a Replica (prReplicaStatus = Just ...)
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      -- Role should be preserved as Source (from current state) during recovery block
      fmap nsRole mNs `shouldBe` Just Source
      -- Health should be Healthy (Source ignores residual replica status)
      fmap nsHealth mNs `shouldBe` Just Healthy

    it "Source with residual IOConnecting replica status gets Healthy during recovery block" $ do
      let promoted = Map.adjust (\ns -> ns { nsRole = Source, nsHealth = ReplicaIOConnecting }) replicaId baseNodes
          topo = baseTopo { ctNodes = promoted, ctRecoveryBlockedUntil = Just fixedTime2 }
          -- Probe returns residual replica status with IOConnecting (race with RESET REPLICA ALL)
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOConnecting "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsRole mNs `shouldBe` Just Source
      fmap nsHealth mNs `shouldBe` Just Healthy

    it "uses probe-inferred role when no recovery block" $ do
      let topo = baseTopo
          -- Probe sees the node as a Source (prReplicaStatus = Nothing)
          event = NodeProbed replicaId (ProbeSuccess fixedTime Nothing emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsRole mNs `shouldBe` Just Source

    it "infers Source role from prReplicaStatus = Nothing" $ do
      let topo = baseTopo
          event = NodeProbed sourceId (ProbeSuccess fixedTime Nothing emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup sourceId (ctNodes newTopo)
      fmap nsRole mNs `shouldBe` Just Source

    it "detects NotReplicating when Replica-role node has no replica status" $ do
      let -- db2 was a Replica, but probe returns prReplicaStatus = Nothing
          -- During recovery block, role is preserved as Replica
          withRecovery = baseTopo { ctRecoveryBlockedUntil = Just fixedTime2 }
          event = NodeProbed replicaId (ProbeSuccess fixedTime Nothing emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc withRecovery event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsRole mNs `shouldBe` Just Replica
      fmap nsHealth mNs `shouldBe` Just NotReplicating

    it "emits lag hook on Lagging transition" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100") { rsSecondsBehindSource = Just 120 }
          topo = baseTopo
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just rs) emptyGtidSet) emptyGtidSet fixedTime
          (_, effects) = applyEvent testFdc testFc testMc topo event
          lagEffects = [e | FireHookEffect e _ <- effects, isLagExceeded e]
      lagEffects `shouldSatisfy` (not . null)

    it "recomputes cluster health after node update" $ do
      let deadNodes = clusterWithDeadSource
          topo = (mkTopo deadNodes) { ctHealth = Healthy }
          -- Probe the replica: it sees IO=No
          event = NodeProbed (nsNodeId healthySource) (ProbeFailure "Connection refused") emptyGtidSet fixedTime
          fdc3 = testFdc { fdcConsecutiveFailuresForDead = AtLeastOne 1 }
          (newTopo, _) = applyEvent fdc3 testFc testMc topo event
      ctHealth newTopo `shouldNotBe` Healthy

    it "syncs nsRole to Source when identifySource falls back via replica-reported source" $ do
      let -- db1 was previously demoted to Replica but its probe result no
          -- longer carries replica status (stale state after a prior
          -- FailoverCommitted / NodeDemoted). db2 is still a Replica and
          -- points to db1 as its source, so identifySource's fallback
          -- branch should identify db1.
          staleDemoted = healthySource { nsRole = Replica }
          nodes = Map.fromList
            [ (nsNodeId staleDemoted, staleDemoted)
            , (nsNodeId healthyReplica, healthyReplica)
            ]
          topo = (mkTopo nodes) { ctSourceNodeId = Nothing }
          event = NodeProbed replicaId
            (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet)
            emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      ctSourceNodeId newTopo `shouldBe` Just sourceId
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Source

    it "leaves node roles unchanged when identifySource returns Nothing" $ do
      let -- Two replicas that reference a host which is not part of the
          -- cluster. identifySource's fallback cannot match, so newSrcId
          -- must be Nothing and nsRole must not be forced to Source.
          ghostRs = mkReplicaStatus "ghost-host" 9999 IOYes "uuid1:1-1"
          n1 = mkNodeState (unsafeNodeId "dbx" 3306) Replica (Just ghostRs) Healthy
          n2 = mkNodeState (unsafeNodeId "dby" 3306) Replica (Just ghostRs) Healthy
          nodes = Map.fromList [(nsNodeId n1, n1), (nsNodeId n2, n2)]
          topo = (mkTopo nodes) { ctSourceNodeId = Nothing }
          event = NodeProbed (nsNodeId n1)
            (ProbeSuccess fixedTime (Just ghostRs) emptyGtidSet)
            emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      ctSourceNodeId newTopo `shouldBe` Nothing
      fmap nsRole (Map.lookup (nsNodeId n1) (ctNodes newTopo)) `shouldBe` Just Replica
      fmap nsRole (Map.lookup (nsNodeId n2) (ctNodes newTopo)) `shouldBe` Just Replica

  describe "applyEvent FailoverCommitted" $ do
    it "demotes old sources and promotes new source" $ do
      let topo = mkTopo clusterHealthy
          recoveryUntil = addUTCTime 300 fixedTime
          event = FailoverCommitted replicaId [sourceId] fixedTime recoveryUntil
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica
      fmap nsRole (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Source

    it "resets promoted node health to Healthy" $ do
      let -- Replica had ReplicaIOConnecting before failover (source was dead)
          withIOConnecting = Map.adjust (\ns -> ns { nsHealth = ReplicaIOConnecting }) replicaId (clusterHealthy)
          topo = mkTopo withIOConnecting
          recoveryUntil = addUTCTime 300 fixedTime
          event = FailoverCommitted replicaId [sourceId] fixedTime recoveryUntil
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsHealth (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Healthy
      fmap nsRole (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Source

    it "sets ctLastFailoverAt and ctRecoveryBlockedUntil" $ do
      let topo = mkTopo clusterHealthy
          recoveryUntil = addUTCTime 300 fixedTime
          event = FailoverCommitted replicaId [sourceId] fixedTime recoveryUntil
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      ctLastFailoverAt newTopo `shouldBe` Just fixedTime
      ctRecoveryBlockedUntil newTopo `shouldBe` Just recoveryUntil

  describe "applyEvent TopologyRefreshed" $ do
    it "preserves daemon-managed fields from old topology" $ do
      let topo = (mkTopo clusterHealthy)
            { ctPaused = Paused
            , ctTopologyDrift = DriftDetected
            , ctRecoveryBlockedUntil = Just fixedTime
            , ctHealth = DeadSource
            , ctSourceNodeId = Just sourceId
            , ctLastFailoverAt = Just fixedTime
            }
          newTopo' = mkTopo clusterHealthy
          event = TopologyRefreshed newTopo'
          (merged, _) = applyEvent testFdc testFc testMc topo event
      ctPaused merged `shouldBe` Paused
      ctTopologyDrift merged `shouldBe` DriftDetected
      ctRecoveryBlockedUntil merged `shouldBe` Just fixedTime
      ctHealth merged `shouldBe` DeadSource
      ctSourceNodeId merged `shouldBe` Just sourceId
      ctLastFailoverAt merged `shouldBe` Just fixedTime

  describe "applyEvent TopologyDriftUpdated" $ do
    it "emits drift hook on False -> True transition" $ do
      let topo = mkTopo clusterHealthy
          event = TopologyDriftUpdated DriftDetected [MissingNode (HostName "missing-host")]
          (_, effects) = applyEvent testFdc testFc testMc topo event
          hooks = [e | FireHookEffect e _ <- effects]
      hooks `shouldSatisfy` (not . null)
      hooks `shouldBe` [OnTopologyDrift "missing_node" "missing-host"]

    it "does not emit hook on True -> True (no transition)" $ do
      let topo = (mkTopo clusterHealthy) { ctTopologyDrift = DriftDetected }
          event = TopologyDriftUpdated DriftDetected [MissingNode (HostName "missing-host")]
          (_, effects) = applyEvent testFdc testFc testMc topo event
      [e | FireHookEffect e _ <- effects] `shouldBe` []

  describe "applyEvent simple events" $ do
    it "NodeFenced sets nsFenced = Fenced" $ do
      let topo = mkTopo clusterHealthy
          event = NodeFenced sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsFenced (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Fenced

    it "NodeUnfenced sets nsFenced = Unfenced" $ do
      let fencedNodes = Map.adjust (\ns -> ns { nsFenced = Fenced }) sourceId clusterHealthy
          topo = mkTopo fencedNodes
          event = NodeUnfenced sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsFenced (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Unfenced

    it "ReplicaPaused sets nsPaused = Paused" $ do
      let topo = mkTopo clusterHealthy
          event = ReplicaPaused replicaId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsPaused (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Paused

    it "ReplicaResumed sets nsPaused = Running" $ do
      let pausedNodes = Map.adjust (\ns -> ns { nsPaused = Paused }) replicaId clusterHealthy
          topo = mkTopo pausedNodes
          event = ReplicaResumed replicaId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsPaused (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Running

    it "RecoveryBlockCleared clears ctRecoveryBlockedUntil" $ do
      let topo = (mkTopo clusterHealthy) { ctRecoveryBlockedUntil = Just fixedTime }
          (newTopo, _) = applyEvent testFdc testFc testMc topo RecoveryBlockCleared
      ctRecoveryBlockedUntil newTopo `shouldBe` Nothing

    it "FailoverPaused sets ctPaused = Paused" $ do
      let topo = mkTopo clusterHealthy
          (newTopo, _) = applyEvent testFdc testFc testMc topo FailoverPaused
      ctPaused newTopo `shouldBe` Paused

    it "FailoverResumed sets ctPaused = Running" $ do
      let topo = (mkTopo clusterHealthy) { ctPaused = Paused }
          (newTopo, _) = applyEvent testFdc testFc testMc topo FailoverResumed
      ctPaused newTopo `shouldBe` Running

    it "NodeDemoted sets role to Replica" $ do
      let topo = mkTopo clusterHealthy
          event = NodeDemoted sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica

    it "SwitchoverCommitted swaps roles" $ do
      let topo = mkTopo clusterHealthy
          event = SwitchoverCommitted (Promoted sourceId replicaId)
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica
      fmap nsRole (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Source

  -- E2E scenario: chain events to simulate full failover lifecycle
  describe "Failover E2E scenario" $ do
    it "promoted SOURCE shows Healthy immediately after failover and through recovery" $ do
      let db1 = unsafeNodeId "db1" 3306
          db2 = unsafeNodeId "db2" 3306
          db3 = unsafeNodeId "db3" 3306
          -- Use threshold=1 so probe failures trigger immediately
          fdc1 = testFdc { fdcConsecutiveFailuresForDead = AtLeastOne 1 }

          -- Initial state: db1=Source(dead), db2=Replica(IOConnecting), db3=Replica(Healthy)
          initialNodes = Map.fromList
            [ (db1, (unreachableNode db1) { nsRole = Source })
            , (db2, NodeState
                { nsNodeId              = db2
                , nsRole                = Replica
                , nsHealth              = ReplicaIOConnecting
                , nsProbeResult         = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOConnecting "uuid1:1-100")) emptyGtidSet
                , nsErrantGtids         = emptyGtidSet
                , nsPaused              = Running
                , nsConsecutiveFailures = 0
                , nsFenced              = Unfenced
                })
            , (db3, mkNodeState db3 Replica (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) Healthy)
            ]
          topo0 = (mkTopo initialNodes) { ctHealth = DeadSource }

          -- Step 1: FailoverCommitted (promote db2, demote db1)
          recoveryUntil = addUTCTime 300 fixedTime
          foEvent = FailoverCommitted db2 [db1] fixedTime recoveryUntil
          (topo1, _) = applyEvent fdc1 testFc testMc topo0 foEvent

      -- Immediately after FO: db2 is Source with Healthy (stale health cleared)
      fmap nsRole (Map.lookup db2 (ctNodes topo1)) `shouldBe` Just Source
      fmap nsHealth (Map.lookup db2 (ctNodes topo1)) `shouldBe` Just Healthy
      ctRecoveryBlockedUntil topo1 `shouldBe` Just recoveryUntil

      let -- Step 2: NodeProbed db2 with residual IOConnecting (race with RESET REPLICA ALL)
          probe2 = NodeProbed db2
            (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOConnecting "uuid1:1-100")) emptyGtidSet)
            emptyGtidSet fixedTime
          (topo2, _) = applyEvent fdc1 testFc testMc topo1 probe2

      -- Role preserved as Source, health is Healthy (Source ignores replica status)
      fmap nsRole (Map.lookup db2 (ctNodes topo2)) `shouldBe` Just Source
      fmap nsHealth (Map.lookup db2 (ctNodes topo2)) `shouldBe` Just Healthy
      -- Cluster health should NOT be NeedsAttention due to Source's residual IO status
      ctHealth topo2 `shouldNotBe` NeedsAttention "Replica IO thread not connected"

      let -- Step 3: NodeProbed db2 with no replica status (RESET REPLICA ALL completed)
          probe3 = NodeProbed db2 (ProbeSuccess fixedTime Nothing emptyGtidSet) emptyGtidSet fixedTime
          (topo3, _) = applyEvent fdc1 testFc testMc topo2 probe3

      fmap nsRole (Map.lookup db2 (ctNodes topo3)) `shouldBe` Just Source
      fmap nsHealth (Map.lookup db2 (ctNodes topo3)) `shouldBe` Just Healthy

      let -- Step 4: NodeProbed db3 reconnected to db2 (IOYes, source=db2)
          probe4 = NodeProbed db3
            (ProbeSuccess fixedTime (Just (mkReplicaStatus "db2" 3306 IOYes "uuid1:1-100")) emptyGtidSet)
            emptyGtidSet fixedTime
          (topo4, _) = applyEvent fdc1 testFc testMc topo3 probe4

      fmap nsRole (Map.lookup db3 (ctNodes topo4)) `shouldBe` Just Replica
      fmap nsHealth (Map.lookup db3 (ctNodes topo4)) `shouldBe` Just Healthy

isLagExceeded :: HookEvent -> Bool
isLagExceeded (OnLagThresholdExceeded _) = True
isLagExceeded _                          = False
