module PureMyHA.WorkerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait, AsyncCancelled(..))
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO)
import Control.Exception (SomeException, try, fromException)
import qualified Data.Map.Strict as Map
import Test.Hspec
import Fixtures
import Data.List.NonEmpty (NonEmpty ((:|)))
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..), FailoverConfig (..), MonitoringConfig (..), FailureDetectionConfig (..), Port (..), PositiveDuration (..), AtLeastOne (..))
import PureMyHA.Env (runApp)
import qualified Data.Set as Set
import PureMyHA.Monitor.Worker (suppressBelowThreshold, enrichErrantGtids, computeStaleNodes, pruneStaleWorkers, detectAndPruneStaleWorkers, probeTimeoutMicros, buildLagHookEnv, mergeNodeState, detectTopologyDrift, mergeTopology, computeNewNodes, computeDriftConditions)
import PureMyHA.Monitor.Event (decideClusterActions)
import PureMyHA.Hook (HookEnv (..))
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types

testCC :: ClusterConfig
testCC = ClusterConfig
  { ccName                   = "main"
  , ccNodes                  = NodeConfig "db1" (Port 3306) :| []
  , ccCredentials            = Credentials "user" "/dev/null"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1
  , ccFailureDetection       = FailureDetectionConfig 3600 (AtLeastOne 3)
  , ccFailover               = FailoverConfig True 1 [] 60 False Nothing [] False
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

testFC :: FailoverConfig
testFC = FailoverConfig
  { fcAutoFailover                   = True
  , fcMinReplicasForFailover         = 1
  , fcCandidatePriority              = []
  , fcWaitRelayLogTimeout            = 60
  , fcAutoFence                      = False
  , fcMaxReplicaLagForCandidate      = Nothing
  , fcNeverPromote                   = []
  , fcFailoverWithoutObservedHealthy = False
  }

spec :: Spec
spec = do

  describe "probeTimeoutMicros" $ do

    it "computes 6s for default config (2s timeout, 1 retry)" $
      probeTimeoutMicros 2 1 `shouldBe` 6_000_000

    it "computes 2s when no retries (2s timeout, 0 retries)" $
      probeTimeoutMicros 2 0 `shouldBe` 2_000_000

    it "scales correctly with higher retries (3s timeout, 2 retries)" $
      probeTimeoutMicros 3 2 `shouldBe` 15_000_000

  describe "enrichErrantGtids" $ do

    it "returns ns unchanged when monitored node is unreachable (skips TCP connect)" $ do
      tvar <- newDaemonState
      let topo = (buildClusterTopology 1 "main" clusterWithDeadSource)
                   { ctSourceNodeId = Just (NodeId "db1" 3306) }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env (enrichErrantGtids unreachableReplica)
      nsErrantGtids result `shouldBe` nsErrantGtids unreachableReplica

    it "returns ns unchanged when source is unreachable (skips TCP connect)" $ do
      tvar <- newDaemonState
      let topo = (buildClusterTopology 1 "main" clusterWithDeadSource)
                   { ctSourceNodeId = Just (NodeId "db1" 3306) }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env (enrichErrantGtids healthyReplica)
      nsErrantGtids result `shouldBe` nsErrantGtids healthyReplica

    it "returns ns unchanged when no topology exists" $ do
      tvar <- newDaemonState
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env (enrichErrantGtids healthyReplica)
      nsErrantGtids result `shouldBe` nsErrantGtids healthyReplica

    it "returns ns unchanged when topology has no source node" $ do
      tvar <- newDaemonState
      let topo = (buildClusterTopology 1 "main" clusterWithDeadSource)
                   { ctSourceNodeId = Nothing }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env (enrichErrantGtids healthyReplica)
      nsErrantGtids result `shouldBe` nsErrantGtids healthyReplica

  describe "suppressBelowThreshold" $ do
    let threshold = 3
        errNs     = healthySource
                      { nsHealth              = NodeUnreachable "refused"
                      , nsProbeResult         = ProbeFailure "refused"
                      , nsConsecutiveFailures = 1
                      }

    it "keeps previous health when failCount is below threshold" $
      suppressBelowThreshold threshold 1 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = Healthy }

    it "applies unhealthy state when failCount equals threshold" $
      suppressBelowThreshold threshold 3 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = NodeUnreachable "refused" }

    it "applies unhealthy state when failCount exceeds threshold" $
      suppressBelowThreshold threshold 5 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = NodeUnreachable "refused" }

    it "uses Healthy as fallback when no previous state (first probe)" $
      suppressBelowThreshold threshold 1 Nothing errNs
        `shouldBe` errNs { nsHealth = Healthy }

    it "does not suppress when failCount is 0 (success case)" $
      suppressBelowThreshold threshold 0 (Just healthySource) healthySource
        `shouldBe` healthySource

    it "resets to Healthy on success after previous unhealthy state" $ do
      let prev = healthySource { nsHealth = NodeUnreachable "err", nsConsecutiveFailures = 2 }
          curr = healthySource { nsConsecutiveFailures = 0 }
      suppressBelowThreshold threshold 0 (Just prev) curr `shouldBe` curr

    it "preserves previous unhealthy state when below threshold" $ do
      let prev = healthySource { nsHealth = NodeUnreachable "prior err", nsConsecutiveFailures = 2 }
      suppressBelowThreshold threshold 2 (Just prev) errNs
        `shouldBe` errNs { nsHealth = NodeUnreachable "prior err" }

  describe "computeStaleNodes" $ do
    let db1 = NodeId "db1" 3306
        db2 = NodeId "db2" 3306
        db3 = NodeId "db3" 3306
        db4 = NodeId "db4" 3306

    it "returns empty when all known nodes are in discovered set" $
      computeStaleNodes (Set.fromList [db1, db2]) (Set.fromList [db1, db2]) Set.empty
        `shouldBe` Set.empty

    it "returns empty when all known nodes are in configured set" $
      computeStaleNodes (Set.fromList [db1, db2]) Set.empty (Set.fromList [db1, db2])
        `shouldBe` Set.empty

    it "returns stale node absent from both discovered and configured" $
      computeStaleNodes (Set.fromList [db1, db2, db3]) (Set.fromList [db1]) (Set.fromList [db2])
        `shouldBe` Set.singleton db3

    it "returns empty when known is empty" $
      computeStaleNodes Set.empty (Set.fromList [db1]) (Set.fromList [db2])
        `shouldBe` Set.empty

    it "preserves configured nodes even if not discovered" $
      computeStaleNodes (Set.fromList [db1, db2]) (Set.fromList [db1]) (Set.fromList [db2])
        `shouldBe` Set.empty

    it "preserves discovered nodes even if not configured" $
      computeStaleNodes (Set.fromList [db1, db2]) (Set.fromList [db2]) (Set.fromList [db1])
        `shouldBe` Set.empty

    it "returns multiple stale nodes" $
      computeStaleNodes (Set.fromList [db1, db2, db3, db4]) (Set.fromList [db1]) (Set.fromList [db2])
        `shouldBe` Set.fromList [db3, db4]

  describe "pruneStaleWorkers" $ do
    let db1 = NodeId "db1" 3306
        db2 = NodeId "db2" 3306
        db3 = NodeId "db3" 3306

    it "removes stale worker from registry and cancels its async" $ do
      a1 <- async (threadDelay maxBound)
      a2 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1), (db2, a2)])
      pruneStaleWorkers reg [db2]
      registry <- readTVarIO reg
      Map.keys registry `shouldBe` [db1]
      result <- try @SomeException (wait a2)
      case result of
        Left e  -> fromException e `shouldBe` Just AsyncCancelled
        Right _ -> expectationFailure "expected AsyncCancelled"

    it "does nothing when staleNodes list is empty" $ do
      a1 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1)])
      pruneStaleWorkers reg []
      registry <- readTVarIO reg
      Map.size registry `shouldBe` 1

    it "handles NodeId not in registry without error" $ do
      reg <- newTVarIO Map.empty
      pruneStaleWorkers reg [db3]
      registry <- readTVarIO reg
      Map.size registry `shouldBe` 0

    it "prunes multiple stale workers" $ do
      a1 <- async (threadDelay maxBound)
      a2 <- async (threadDelay maxBound)
      a3 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1), (db2, a2), (db3, a3)])
      pruneStaleWorkers reg [db2, db3]
      registry <- readTVarIO reg
      Map.keys registry `shouldBe` [db1]

  describe "detectAndPruneStaleWorkers" $ do
    let db1 = NodeId "db1" 3306
        db2 = NodeId "db2" 3306
        db3 = NodeId "db3" 3306
        ccWith nodes = testCC { ccNodes = nodes }

    it "detects and prunes stale nodes not in discovered or configured sets" $ do
      a1 <- async (threadDelay maxBound)
      a2 <- async (threadDelay maxBound)
      a3 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1), (db2, a2), (db3, a3)])
      let discovered = Set.singleton db1
          cc = ccWith (NodeConfig "db2" (Port 3306) :| [])
      stale <- detectAndPruneStaleWorkers reg cc discovered
      stale `shouldBe` [db3]
      registry <- readTVarIO reg
      Map.keys registry `shouldMatchList` [db1, db2]

    it "returns empty list when no nodes are stale" $ do
      a1 <- async (threadDelay maxBound)
      a2 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1), (db2, a2)])
      let discovered = Set.fromList [db1, db2]
      stale <- detectAndPruneStaleWorkers reg testCC discovered
      stale `shouldBe` []
      registry <- readTVarIO reg
      Map.size registry `shouldBe` 2

    it "preserves configured seed nodes even if not discovered" $ do
      a1 <- async (threadDelay maxBound)
      a2 <- async (threadDelay maxBound)
      reg <- newTVarIO (Map.fromList [(db1, a1), (db2, a2)])
      let discovered = Set.singleton db1
          cc = ccWith (NodeConfig "db2" (Port 3306) :| [])
      stale <- detectAndPruneStaleWorkers reg cc discovered
      stale `shouldBe` []
      registry <- readTVarIO reg
      Map.size registry `shouldBe` 2

  describe "buildLagHookEnv" $ do

    it "sets hookNode to the node's host" $
      hookNode (buildLagHookEnv "main" (NodeId "db2" 3306) "2026-01-01T00:00:00Z")
        `shouldBe` Just "db2"

    it "does not set hookNewSource, hookOldSource, hookFailureType, or hookLagSeconds" $ do
      let e = buildLagHookEnv "main" (NodeId "db2" 3306) "2026-01-01T00:00:00Z"
      hookNewSource   e `shouldBe` Nothing
      hookOldSource   e `shouldBe` Nothing
      hookFailureType e `shouldBe` Nothing
      hookLagSeconds  e `shouldBe` Nothing

    it "sets hookClusterName correctly" $
      hookClusterName (buildLagHookEnv "main" (NodeId "db2" 3306) "ts")
        `shouldBe` "main"

    it "sets hookTimestamp correctly" $
      hookTimestamp (buildLagHookEnv "main" (NodeId "db2" 3306) "2026-01-01T00:00:00Z")
        `shouldBe` "2026-01-01T00:00:00Z"

  describe "detectTopologyDrift" $ do
    let db1 = HostName "db1"
        db2 = HostName "db2"
        db3 = HostName "db3"

    it "returns [] when configured and discovered sets match and replicas >= threshold" $
      detectTopologyDrift (Set.fromList [db1, db2]) (Set.fromList [db1, db2]) 1 1
        `shouldBe` []

    it "returns [] when replica count equals threshold exactly" $
      detectTopologyDrift (Set.fromList [db1]) (Set.fromList [db1]) 1 1
        `shouldBe` []

    it "returns [MissingNode] when a configured node is not discovered" $
      detectTopologyDrift (Set.fromList [db1, db2]) (Set.fromList [db1]) 1 1
        `shouldBe` [MissingNode db2]

    it "returns [UnexpectedNode] when a discovered node is not in config" $
      detectTopologyDrift (Set.fromList [db1]) (Set.fromList [db1, db3]) 1 1
        `shouldBe` [UnexpectedNode db3]

    it "returns [ReplicaCountBelowThreshold] when healthy replicas < min" $
      detectTopologyDrift (Set.fromList [db1, db2]) (Set.fromList [db1, db2]) 1 0
        `shouldBe` [ReplicaCountBelowThreshold 0 1]

    it "returns multiple conditions when missing node and below threshold" $ do
      let result = detectTopologyDrift (Set.fromList [db1, db2]) (Set.fromList [db1]) 1 0
      result `shouldContain` [MissingNode db2]
      result `shouldContain` [ReplicaCountBelowThreshold 0 1]

    it "returns [] when min_replicas_for_failover=0 and no replicas present" $
      detectTopologyDrift (Set.fromList [db1]) (Set.fromList [db1]) 0 0
        `shouldBe` []

  describe "mergeNodeState" $ do

    it "preserves Source role from old when new has ProbeFailure (Replica)" $ do
      -- Simulates topology refresh discovering the dead source as Replica
      let new = (unreachableNode (NodeId (mkHostInfoFromName "db1") 3306))
                  { nsRole = Replica }
          old = healthySource
      nsRole (mergeNodeState new old) `shouldBe` Source

    it "preserves Source role from old even when new probe succeeded as Replica" $ do
      -- Ensures topology refresh never overrides monitoring-worker role assignment
      let new = healthyReplica { nsNodeId = nsNodeId healthySource }
          old = healthySource
      nsRole (mergeNodeState new old) `shouldBe` Source

    it "preserves Replica role from old" $ do
      let new = healthySource { nsNodeId = nsNodeId healthyReplica, nsRole = Source }
          old = healthyReplica
      nsRole (mergeNodeState new old) `shouldBe` Replica

  describe "decideClusterActions" $ do
    let mkTopo :: NodeHealth -> Bool -> ClusterTopology
        mkTopo health obs = ClusterTopology
          { ctClusterName          = "test"
          , ctNodes                = Map.empty
          , ctSourceNodeId         = Nothing
          , ctHealth               = health
          , ctObservedHealthy      = obs
          , ctRecoveryBlockedUntil = Nothing
          , ctLastFailoverAt       = Nothing
          , ctPaused               = False
          , ctTopologyDrift        = False
          }
        fcWithFence = testFC { fcAutoFence = True }

    -- FireHook tests (transition only)
    it "fires OnFailureDetection hook on transition to DeadSource" $
      decideClusterActions testFC (mkTopo Healthy True) DeadSource
        `shouldContain` [FireHook (OnFailureDetection "DeadSource")]

    it "fires OnFailureDetection hook on transition to InsufficientQuorum" $
      decideClusterActions testFC (mkTopo Healthy True) InsufficientQuorum
        `shouldContain` [FireHook (OnFailureDetection "InsufficientQuorum")]

    it "fires OnFailureDetection hook on transition to DeadSourceAndAllReplicas" $
      decideClusterActions testFC (mkTopo Healthy True) DeadSourceAndAllReplicas
        `shouldContain` [FireHook (OnFailureDetection "DeadSourceAndAllReplicas")]

    it "does not fire hook when health has not transitioned" $
      filter isFireHook (decideClusterActions testFC (mkTopo DeadSource True) DeadSource)
        `shouldBe` []

    -- TriggerAutoFailover tests
    it "triggers auto-failover on transition to DeadSource when enabled and observed healthy" $
      decideClusterActions testFC (mkTopo Healthy True) DeadSource
        `shouldContain` [TriggerAutoFailover]

    it "triggers auto-failover even without transition (resume-failover)" $
      decideClusterActions testFC (mkTopo DeadSource True) DeadSource
        `shouldContain` [TriggerAutoFailover]

    it "does not trigger auto-failover when disabled" $
      decideClusterActions (testFC { fcAutoFailover = False }) (mkTopo Healthy True) DeadSource
        `shouldNotContain` [TriggerAutoFailover]

    it "does not trigger auto-failover when not observed healthy" $
      decideClusterActions testFC (mkTopo (NodeUnreachable "err") False) DeadSource
        `shouldNotContain` [TriggerAutoFailover]

    it "triggers auto-failover without observed healthy when failover_without_observed_healthy is true" $
      decideClusterActions (testFC { fcFailoverWithoutObservedHealthy = True })
        (mkTopo (NodeUnreachable "err") False) DeadSource
        `shouldContain` [TriggerAutoFailover]

    -- TriggerAutoFence tests
    it "triggers auto-fence on transition to SplitBrainSuspected when enabled and observed healthy" $
      decideClusterActions fcWithFence (mkTopo Healthy True) SplitBrainSuspected
        `shouldContain` [TriggerAutoFence]

    it "does not trigger auto-fence without transition" $
      decideClusterActions fcWithFence (mkTopo SplitBrainSuspected True) SplitBrainSuspected
        `shouldNotContain` [TriggerAutoFence]

    -- TriggerEmergencyReplicaCheck tests
    it "triggers emergency replica check on transition to UnreachableSource" $
      decideClusterActions testFC (mkTopo Healthy True) UnreachableSource
        `shouldContain` [TriggerEmergencyReplicaCheck]

    it "does not trigger emergency replica check without transition" $
      decideClusterActions testFC (mkTopo UnreachableSource True) UnreachableSource
        `shouldNotContain` [TriggerEmergencyReplicaCheck]

    -- Empty actions
    it "returns empty list when health stays Healthy" $
      decideClusterActions testFC (mkTopo Healthy True) Healthy
        `shouldBe` []

  describe "mergeTopology" $ do
    let baseTopo nodes = ClusterTopology
          { ctClusterName          = "test"
          , ctNodes                = nodes
          , ctSourceNodeId         = Nothing
          , ctHealth               = Healthy
          , ctObservedHealthy      = False
          , ctRecoveryBlockedUntil = Nothing
          , ctLastFailoverAt       = Nothing
          , ctPaused               = False
          , ctTopologyDrift        = False
          }

    it "returns newTopo unchanged when mOldTopo is Nothing" $ do
      let newTopo = baseTopo (Map.singleton (nsNodeId healthySource) healthySource)
          merged  = mergeTopology newTopo Nothing
      ctNodes merged `shouldBe` ctNodes newTopo

    it "merges nodes from old topology preserving old health/role" $ do
      let db1 = nsNodeId healthySource
          -- new topology discovers db1 as Replica (e.g. probe without replica status failed)
          newNs = healthyReplica { nsNodeId = db1 }
          newTopo = baseTopo (Map.singleton db1 newNs)
          oldTopo = baseTopo (Map.singleton db1 healthySource)
          merged = mergeTopology newTopo (Just oldTopo)
      -- mergeNodeState preserves old role
      nsRole (ctNodes merged Map.! db1) `shouldBe` Source

    it "includes nodes only present in old topology" $ do
      let db1 = nsNodeId healthySource
          db2 = nsNodeId healthyReplica
          newTopo = baseTopo (Map.singleton db1 healthySource)
          oldTopo = baseTopo (Map.singleton db2 healthyReplica)
          merged = mergeTopology newTopo (Just oldTopo)
      Map.size (ctNodes merged) `shouldBe` 2

  describe "computeNewNodes" $ do
    let db1 = NodeId "db1" 3306
        db2 = NodeId "db2" 3306
        db3 = NodeId "db3" 3306

    it "returns nodes in discovered but not in known" $
      computeNewNodes (Set.fromList [db1, db2, db3]) (Set.fromList [db1])
        `shouldMatchList` [db2, db3]

    it "returns [] when discovered is subset of known" $
      computeNewNodes (Set.fromList [db1]) (Set.fromList [db1, db2])
        `shouldBe` []

    it "returns all discovered when known is empty" $
      computeNewNodes (Set.fromList [db1, db2]) Set.empty
        `shouldMatchList` [db1, db2]

  describe "computeDriftConditions" $ do
    let mkTopo nodes = ClusterTopology
          { ctClusterName          = "test"
          , ctNodes                = nodes
          , ctSourceNodeId         = Nothing
          , ctHealth               = Healthy
          , ctObservedHealthy      = True
          , ctRecoveryBlockedUntil = Nothing
          , ctLastFailoverAt       = Nothing
          , ctPaused               = False
          , ctTopologyDrift        = False
          }
        ccWith nodes fc = testCC { ccNodes = nodes, ccFailover = fc }

    it "returns [] when all configured hosts are reachable with sufficient replicas" $ do
      let cc = ccWith (NodeConfig "db1" (Port 3306) :| [NodeConfig "db2" (Port 3306)]) (testFC { fcMinReplicasForFailover = 1 })
          topo = mkTopo (Map.fromList [(nsNodeId healthySource, healthySource), (nsNodeId healthyReplica, healthyReplica)])
      computeDriftConditions cc topo `shouldBe` []

    it "returns [MissingNode] for configured host absent from reachable nodes" $ do
      let cc = ccWith (NodeConfig "db1" (Port 3306) :| [NodeConfig "db2" (Port 3306)]) (testFC { fcMinReplicasForFailover = 0 })
          topo = mkTopo (Map.singleton (nsNodeId healthySource) healthySource)
      computeDriftConditions cc topo `shouldContain` [MissingNode (HostName "db2")]

    it "returns [ReplicaCountBelowThreshold] when healthy replicas < min" $ do
      let cc = ccWith (NodeConfig "db1" (Port 3306) :| []) (testFC { fcMinReplicasForFailover = 1 })
          topo = mkTopo (Map.singleton (nsNodeId healthySource) healthySource)
      computeDriftConditions cc topo `shouldContain` [ReplicaCountBelowThreshold 0 1]

    it "excludes unreachable nodes from discovered hosts" $ do
      let db2id = NodeId (mkHostInfoFromName "db2") 3306
          cc = ccWith (NodeConfig "db1" (Port 3306) :| [NodeConfig "db2" (Port 3306)]) (testFC { fcMinReplicasForFailover = 0 })
          topo = mkTopo (Map.fromList [(nsNodeId healthySource, healthySource), (db2id, unreachableNode db2id)])
      -- db2 is in the topology but unreachable, so it should be missing from discovered hosts
      computeDriftConditions cc topo `shouldContain` [MissingNode (HostName "db2")]

isFireHook :: ClusterAction -> Bool
isFireHook (FireHook _) = True
isFireHook _            = False
