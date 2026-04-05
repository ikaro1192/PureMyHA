module PureMyHA.EventSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, fromGregorian, UTCTime (..), addUTCTime)
import Test.Hspec

import Fixtures
import PureMyHA.Config
import PureMyHA.Monitor.Event
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.Types

fixedTime2 :: UTCTime
fixedTime2 = UTCTime (fromGregorian 2024 1 2) 0

testFdc :: FailureDetectionConfig
testFdc = FailureDetectionConfig 300 (AtLeastOne 3)

testFc :: FailoverConfig
testFc = FailoverConfig True 1 [] 60 False Nothing [] False

testMc :: MonitoringConfig
testMc = MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1

mkTopo :: Map.Map NodeId NodeState -> ClusterTopology
mkTopo nodes = ClusterTopology
  { ctClusterName           = "test"
  , ctNodes                 = nodes
  , ctSourceNodeId          = Nothing
  , ctHealth                = Healthy
  , ctObservedHealthy       = True
  , ctRecoveryBlockedUntil  = Nothing
  , ctLastFailoverAt        = Nothing
  , ctPaused                = False
  , ctTopologyDrift         = False
  , ctLastEmergencyCheckAt  = Nothing
  }

sourceId :: NodeId
sourceId = nsNodeId healthySource

replicaId :: NodeId
replicaId = nsNodeId healthyReplica

spec :: Spec
spec = describe "PureMyHA.Monitor.Event" $ do

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
      let paused = Map.adjust (\ns -> ns { nsPaused = True }) replicaId baseNodes
          topo = baseTopo { ctNodes = paused }
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsPaused mNs `shouldBe` Just True

    it "preserves nsFenced from current state" $ do
      let fenced = Map.adjust (\ns -> ns { nsFenced = True }) replicaId baseNodes
          topo = baseTopo { ctNodes = fenced }
          event = NodeProbed replicaId (ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) emptyGtidSet) emptyGtidSet fixedTime
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
          mNs = Map.lookup replicaId (ctNodes newTopo)
      fmap nsFenced mNs `shouldBe` Just True

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

  describe "applyEvent FailoverCommitted" $ do
    it "demotes old sources and promotes new source" $ do
      let topo = mkTopo clusterHealthy
          recoveryUntil = addUTCTime 300 fixedTime
          event = FailoverCommitted replicaId [sourceId] fixedTime recoveryUntil
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica
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
            { ctPaused = True
            , ctTopologyDrift = True
            , ctRecoveryBlockedUntil = Just fixedTime
            , ctHealth = DeadSource
            , ctSourceNodeId = Just sourceId
            , ctLastFailoverAt = Just fixedTime
            }
          newTopo' = mkTopo clusterHealthy
          event = TopologyRefreshed newTopo'
          (merged, _) = applyEvent testFdc testFc testMc topo event
      ctPaused merged `shouldBe` True
      ctTopologyDrift merged `shouldBe` True
      ctRecoveryBlockedUntil merged `shouldBe` Just fixedTime
      ctHealth merged `shouldBe` DeadSource
      ctSourceNodeId merged `shouldBe` Just sourceId
      ctLastFailoverAt merged `shouldBe` Just fixedTime

  describe "applyEvent TopologyDriftUpdated" $ do
    it "emits drift hook on False -> True transition" $ do
      let topo = mkTopo clusterHealthy
          event = TopologyDriftUpdated True [MissingNode (HostName "missing-host")]
          (_, effects) = applyEvent testFdc testFc testMc topo event
          hooks = [e | FireHookEffect e _ <- effects]
      hooks `shouldSatisfy` (not . null)
      hooks `shouldBe` [OnTopologyDrift "missing_node" "missing-host"]

    it "does not emit hook on True -> True (no transition)" $ do
      let topo = (mkTopo clusterHealthy) { ctTopologyDrift = True }
          event = TopologyDriftUpdated True [MissingNode (HostName "missing-host")]
          (_, effects) = applyEvent testFdc testFc testMc topo event
      [e | FireHookEffect e _ <- effects] `shouldBe` []

  describe "applyEvent simple events" $ do
    it "NodeFenced sets nsFenced = True" $ do
      let topo = mkTopo clusterHealthy
          event = NodeFenced sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsFenced (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just True

    it "NodeUnfenced sets nsFenced = False" $ do
      let fencedNodes = Map.adjust (\ns -> ns { nsFenced = True }) sourceId clusterHealthy
          topo = mkTopo fencedNodes
          event = NodeUnfenced sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsFenced (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just False

    it "ReplicaPaused sets nsPaused = True" $ do
      let topo = mkTopo clusterHealthy
          event = ReplicaPaused replicaId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsPaused (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just True

    it "ReplicaResumed sets nsPaused = False" $ do
      let pausedNodes = Map.adjust (\ns -> ns { nsPaused = True }) replicaId clusterHealthy
          topo = mkTopo pausedNodes
          event = ReplicaResumed replicaId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsPaused (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just False

    it "RecoveryBlockCleared clears ctRecoveryBlockedUntil" $ do
      let topo = (mkTopo clusterHealthy) { ctRecoveryBlockedUntil = Just fixedTime }
          (newTopo, _) = applyEvent testFdc testFc testMc topo RecoveryBlockCleared
      ctRecoveryBlockedUntil newTopo `shouldBe` Nothing

    it "FailoverPaused sets ctPaused = True" $ do
      let topo = mkTopo clusterHealthy
          (newTopo, _) = applyEvent testFdc testFc testMc topo FailoverPaused
      ctPaused newTopo `shouldBe` True

    it "FailoverResumed sets ctPaused = False" $ do
      let topo = (mkTopo clusterHealthy) { ctPaused = True }
          (newTopo, _) = applyEvent testFdc testFc testMc topo FailoverResumed
      ctPaused newTopo `shouldBe` False

    it "NodeDemoted sets role to Replica" $ do
      let topo = mkTopo clusterHealthy
          event = NodeDemoted sourceId
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica

    it "SwitchoverCommitted swaps roles" $ do
      let topo = mkTopo clusterHealthy
          event = SwitchoverCommitted replicaId (Just sourceId)
          (newTopo, _) = applyEvent testFdc testFc testMc topo event
      fmap nsRole (Map.lookup sourceId (ctNodes newTopo)) `shouldBe` Just Replica
      fmap nsRole (Map.lookup replicaId (ctNodes newTopo)) `shouldBe` Just Source

isLagExceeded :: HookEvent -> Bool
isLagExceeded (OnLagThresholdExceeded _) = True
isLagExceeded _                          = False
