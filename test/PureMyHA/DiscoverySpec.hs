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
  , ccFailover               = FailoverConfig True 1 [] 60
  , ccHooks                  = Nothing
  }

spec :: Spec
spec = do

  describe "buildNodeStateFromProbe" $ do

    it "connection failure sets NeedsAttention health and connectError" $ do
      let ns = buildNodeStateFromProbe testNid now (Left "Connection refused")
      nsHealth      ns `shouldBe` NeedsAttention "Connection refused"
      nsConnectError ns `shouldBe` Just "Connection refused"
      nsLastSeen    ns `shouldBe` Nothing

    it "success with replica status sets isSource=False" $ do
      let ns = buildNodeStateFromProbe testNid now (Right (Just testRs, "uuid1:1-100"))
      nsIsSource      ns `shouldBe` False
      nsReplicaStatus ns `shouldBe` Just testRs
      nsLastSeen      ns `shouldBe` Just now

    it "success without replica status sets isSource=True" $ do
      let ns = buildNodeStateFromProbe testNid now (Right (Nothing, "uuid1:1-100"))
      nsIsSource      ns `shouldBe` True
      nsReplicaStatus ns `shouldBe` Nothing

    it "success records the provided timestamp in nsLastSeen" $ do
      let t  = UTCTime (fromGregorian 2025 12 31) 3600
          ns = buildNodeStateFromProbe testNid t (Right (Nothing, "uuid1:1-5"))
      nsLastSeen ns `shouldBe` Just t

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
          ns  = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.singleton (NodeId "db0" 3306)

    it "does not add upstream source when already visited" $ do
      let rs      = mkReplicaStatus "db0" 3306 IOYes "uuid1:1-100"
          ns      = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
          visited = Set.singleton (NodeId "db0" 3306)
          res     = nextDiscoveryTargets ns visited Set.empty
      res `shouldBe` Set.empty

    it "does not add anything when rsSourceHost is empty" $ do
      let rs  = mkReplicaStatus "" 3306 IOYes "uuid1:1-100"
          ns  = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.empty

    it "does not add anything when nsReplicaStatus is Nothing" $ do
      let ns  = mkNodeState (NodeId "db1" 3306) True Nothing Healthy
          res = nextDiscoveryTargets ns Set.empty Set.empty
      res `shouldBe` Set.empty

  describe "buildInitialTopology" $ do

    it "produces an empty topology with NeedsAttention Initializing" $ do
      let topo = buildInitialTopology testCC
      ctNodes  topo `shouldBe` Map.empty
      ctHealth topo `shouldBe` NeedsAttention "Initializing"
      ctClusterName topo `shouldBe` "test-cluster"
