module PureMyHA.SwitchoverSpec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Test.Hspec
import Fixtures
import PureMyHA.Config (ClusterConfig (..), Credentials (..), FailoverConfig (..), MonitoringConfig (..), FailureDetectionConfig (..))
import PureMyHA.Env (runApp)
import PureMyHA.Failover.Switchover (switchoverReconnectTargets, dryRunSwitchover)
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types

spec :: Spec
spec = do
  describe "switchoverReconnectTargets" $ do

    it "excludes the candidate node from the result" $ do
      let candidateId = NodeId "db2" 3306
          result      = switchoverReconnectTargets clusterHealthy candidateId
      all (\ns -> nsNodeId ns /= candidateId) result `shouldBe` True

    it "includes all non-candidate nodes" $ do
      let candidateId = NodeId "db2" 3306
          result      = switchoverReconnectTargets clusterHealthy candidateId
      length result `shouldBe` 1

    it "returns empty list when only the candidate is present" $ do
      let candidateId = NodeId "db1" 3306
          singleNode  = Map.fromList [(candidateId, healthySource)]
          result      = switchoverReconnectTargets singleNode candidateId
      result `shouldBe` []

    it "returns two nodes when candidate is excluded from three-node cluster" $ do
      let replica3    = healthyReplica { nsNodeId = NodeId "db3" 3306 }
          candidateId = NodeId "db2" 3306
          threeNodes  = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            , (NodeId "db3" 3306, replica3)
            ]
          result      = switchoverReconnectTargets threeNodes candidateId
      length result `shouldBe` 2

  describe "dryRunSwitchover" $ do

    it "selects candidate and returns dry-run message" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover Nothing
      result `shouldSatisfy` isRight

    it "result contains 'Dry run: would promote'" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover Nothing
      case result of
        Right msg -> msg `shouldSatisfy` T.isPrefixOf "Dry run: would promote"
        Left err  -> expectationFailure (show err)

    it "returns Left when cluster is not found" $ do
      tvar <- newDaemonState
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover Nothing
      result `shouldBe` Left "Cluster not found"

    it "returns Left when specified host does not exist" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover (Just "nonexistent.host")
      result `shouldSatisfy` isLeft

testCC :: ClusterConfig
testCC = ClusterConfig
  { ccName                   = "main"
  , ccNodes                  = []
  , ccCredentials            = Credentials "user" "/dev/null"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig 3 5 30 60 300 1 1
  , ccFailureDetection       = FailureDetectionConfig 3600 3
  , ccFailover               = FailoverConfig True 1 [] 60 False Nothing []
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

testFC :: FailoverConfig
testFC = FailoverConfig
  { fcAutoFailover                = True
  , fcMinReplicasForFailover      = 1
  , fcCandidatePriority           = []
  , fcWaitRelayLogTimeout         = 60
  , fcAutoFence                   = False
  , fcMaxReplicaLagForCandidate   = Nothing
  , fcNeverPromote                = []
  }

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
