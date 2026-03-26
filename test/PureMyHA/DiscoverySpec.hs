module PureMyHA.DiscoverySpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec
import Fixtures
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..), MonitoringConfig (..), FailureDetectionConfig (..), FailoverConfig (..))
import PureMyHA.Topology.Discovery
  ( buildNodeStateFromProbe
  , buildClusterTopology
  , nextDiscoveryTargets
  , buildInitialTopology
  )
import PureMyHA.Types

now :: UTCTime
now = UTCTime (fromGregorian 2024 6 1) 0

testNid :: NodeId
testNid = NodeId "db1" 3306

testRs :: ReplicaStatus
testRs = mkReplicaStatus "db0" 3306 IOYes "uuid1:1-100"

testCC :: ClusterConfig
testCC = ClusterConfig
  { ccName                   = "test-cluster"
  , ccNodes                  = [NodeConfig "db1" 3306]
  , ccCredentials            = Credentials "root" "/run/pw"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig 3 5 30 60 300 1 1
  , ccFailureDetection       = FailureDetectionConfig 3600 3
  , ccFailover               = FailoverConfig True 1 [] 60 False Nothing []
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

spec :: Spec
spec = do

  describe "buildNodeStateFromProbe" $ do

    it "connection failure sets NeedsAttention health and ProbeFailure" $ do
      let ns = buildNodeStateFromProbe testNid now (Left "Connection refused")
      nsHealth ns `shouldBe` NeedsAttention "Connection refused"
      nsProbeResult ns `shouldBe` ProbeFailure "Connection refused"

    it "success with replica status sets role=Replica" $ do
      let ns = buildNodeStateFromProbe testNid now (Right (Just testRs, "uuid1:1-100"))
      nsRole ns `shouldBe` Replica
      prReplicaStatus (nsProbeResult ns) `shouldBe` Just testRs
      prLastSeen (nsProbeResult ns) `shouldBe` now

    it "success without replica status sets role=Source" $ do
      let ns = buildNodeStateFromProbe testNid now (Right (Nothing, "uuid1:1-100"))
      nsRole ns `shouldBe` Source
      prReplicaStatus (nsProbeResult ns) `shouldBe` Nothing

    it "success records the provided timestamp in prLastSeen" $ do
      let t  = UTCTime (fromGregorian 2025 12 31) 3600
          ns = buildNodeStateFromProbe testNid t (Right (Nothing, "uuid1:1-5"))
      prLastSeen (nsProbeResult ns) `shouldBe` t

  describe "buildClusterTopology" $ do

    it "healthy cluster has Healthy health and correct source" $ do
      let topo = buildClusterTopology "prod" clusterHealthy
      ctHealth          topo `shouldBe` Healthy
      ctSourceNodeId    topo `shouldBe` Just (NodeId "db1" 3306)
      ctObservedHealthy topo `shouldBe` True

    it "cluster with dead source has DeadSource health" $ do
      let topo = buildClusterTopology "prod" clusterWithDeadSource
      ctHealth          topo `shouldBe` DeadSource
      ctObservedHealthy topo `shouldBe` False

    it "empty cluster has NeedsAttention health and no source" $ do
      let topo = buildClusterTopology "empty" Map.empty
      ctSourceNodeId topo `shouldBe` Nothing
      case ctHealth topo of
        NeedsAttention _ -> pure ()
        other            -> expectationFailure $ "Expected NeedsAttention, got " <> show other

  describe "nextDiscoveryTargets" $ do

    it "adds upstream source when not yet visited" $ do
      let rs  = mkReplicaStatus "db0" 3306 IOYes "uuid1:1-100"
          ns  = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.singleton (NodeId "db0" 3306)

    it "does not add upstream source when already visited" $ do
      let rs      = mkReplicaStatus "db0" 3306 IOYes "uuid1:1-100"
          ns      = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
          visited = Set.singleton (NodeId "db0" 3306)
          res     = nextDiscoveryTargets ns visited Set.empty
      res `shouldBe` Set.empty

    it "does not add anything when rsSourceHost is empty" $ do
      let rs  = mkReplicaStatus "" 3306 IOYes "uuid1:1-100"
          ns  = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.empty

    it "does not add anything when nsReplicaStatus is Nothing" $ do
      let ns  = mkNodeState (NodeId "db1" 3306) Source Nothing Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.empty

  describe "buildClusterTopology edge cases" $ do

    it "all unreachable nodes reports DeadSourceAndAllReplicas" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, unreachableNode (NodeId "db1" 3306))
            , (NodeId "db2" 3306, unreachableNode (NodeId "db2" 3306))
            ]
          topo = buildClusterTopology "prod" nodes
      ctHealth topo `shouldBe` DeadSourceAndAllReplicas

    it "single source only is Healthy" $ do
      let nodes = Map.singleton (NodeId "db1" 3306) healthySource
          topo = buildClusterTopology "prod" nodes
      ctHealth topo `shouldBe` Healthy
      ctSourceNodeId topo `shouldBe` Just (NodeId "db1" 3306)

    it "cluster with errant GTIDs still reports Healthy (errant GTIDs are a warning)" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db3" 3306, replicaWithErrantGtid)
            ]
          topo = buildClusterTopology "prod" nodes
      ctHealth topo `shouldBe` Healthy

  describe "buildInitialTopology" $ do

    it "produces an empty topology with NeedsAttention Initializing" $ do
      let topo = buildInitialTopology testCC
      ctNodes  topo `shouldBe` Map.empty
      ctHealth topo `shouldBe` NeedsAttention "Initializing"
      ctClusterName topo `shouldBe` "test-cluster"
