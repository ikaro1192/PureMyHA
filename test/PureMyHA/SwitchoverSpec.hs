module PureMyHA.SwitchoverSpec (spec) where

import Control.Concurrent.STM (atomically)
import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Test.Hspec
import Fixtures
import Data.List.NonEmpty (NonEmpty ((:|)))
import PureMyHA.Config (ClusterConfig (..), Credentials (..), FailoverConfig (..), MonitoringConfig (..), FailureDetectionConfig (..), NodeConfig (..), PositiveDuration (..), AtLeastOne (..), AutoFailoverMode (..), FenceMode (..), ObservedHealthyRequirement (..))
import PureMyHA.Env (runApp)
import PureMyHA.Failover.Switchover (switchoverReconnectTargets, dryRunSwitchover)
import PureMyHA.IPC.Protocol (SwitchoverTarget (..))
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types

spec :: Spec
spec = do
  describe "switchoverReconnectTargets" $ do

    it "excludes the candidate node from the result" $ do
      let candidateId = unsafeNodeId "db2" 3306
          result      = switchoverReconnectTargets clusterHealthy candidateId
      all (\ns -> nsNodeId ns /= candidateId) result `shouldBe` True

    it "includes all non-candidate nodes" $ do
      let candidateId = unsafeNodeId "db2" 3306
          result      = switchoverReconnectTargets clusterHealthy candidateId
      length result `shouldBe` 1

    it "returns empty list when only the candidate is present" $ do
      let candidateId = unsafeNodeId "db1" 3306
          singleNode  = Map.fromList [(candidateId, healthySource)]
          result      = switchoverReconnectTargets singleNode candidateId
      result `shouldBe` []

    it "returns two nodes when candidate is excluded from three-node cluster" $ do
      let replica3    = healthyReplica { nsNodeId = unsafeNodeId "db3" 3306 }
          candidateId = unsafeNodeId "db2" 3306
          threeNodes  = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, replica3)
            ]
          result      = switchoverReconnectTargets threeNodes candidateId
      length result `shouldBe` 2

  describe "dryRunSwitchover" $ do

    it "result contains 'Dry run: would promote'" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover AutoSelectTarget
      case result of
        Right msg -> msg `shouldSatisfy` T.isPrefixOf "Dry run: would promote"
        Left err  -> expectationFailure (show err)

    it "returns Left when cluster is not found" $ do
      tvar <- newDaemonState
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover AutoSelectTarget
      result `shouldBe` Left "Cluster not found"

    it "returns Left when specified host does not exist" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunSwitchover (ExplicitTarget "nonexistent.host" Nothing)
      result `shouldSatisfy` isLeft

testCC :: ClusterConfig
testCC = ClusterConfig
  { ccName                   = "main"
  , ccNodes                  = NodeConfig "db1" (Port 3306) :| []
  , ccCredentials            = Credentials "user" "/dev/null"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1
  , ccFailureDetection       = FailureDetectionConfig 3600 (AtLeastOne 3)
  , ccFailover               = FailoverConfig AutoFailoverOn 1 [] 60 FenceManual Nothing [] AllowUnobserved
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

testFC :: FailoverConfig
testFC = FailoverConfig
  { fcAutoFailover                   = AutoFailoverOn
  , fcMinReplicasForFailover         = 1
  , fcCandidatePriority              = []
  , fcWaitRelayLogTimeout            = 60
  , fcAutoFence                      = FenceManual
  , fcMaxReplicaLagForCandidate      = Nothing
  , fcNeverPromote                   = []
  , fcFailoverWithoutObservedHealthy = RequireObservedHealthy
  }

