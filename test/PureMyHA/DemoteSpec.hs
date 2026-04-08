module PureMyHA.DemoteSpec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Text as T
import Test.Hspec
import Fixtures
import PureMyHA.Config
  ( ClusterConfig (..), Credentials (..), FailoverConfig (..)
  , MonitoringConfig (..), FailureDetectionConfig (..), NodeConfig (..)
  , Port (..), PositiveDuration (..), AtLeastOne (..)
  , AutoFailoverMode (..), FenceMode (..), ObservedHealthyRequirement (..)
  )
import PureMyHA.Env (runApp)
import PureMyHA.Failover.Demote (dryRunDemote)
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import Data.List.NonEmpty (NonEmpty ((:|)))

spec :: Spec
spec = do
  describe "dryRunDemote" $ do

    it "returns Left when cluster not found" $ do
      tvar <- newDaemonState
      env  <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunDemote "db2" "db1"
      result `shouldBe` Left "Cluster not found"

    it "returns Left when demote host not found" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunDemote "nonexistent" "db1"
      result `shouldBe` Left "Node not found: nonexistent"

    it "returns Left when source host not found" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunDemote "db2" "nonexistent"
      result `shouldBe` Left "Node not found: nonexistent"

    it "returns SQL preview containing STOP REPLICA when both nodes exist" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunDemote "db2" "db1"
      case result of
        Right msg -> do
          msg `shouldSatisfy` T.isInfixOf "STOP REPLICA"
          msg `shouldSatisfy` T.isInfixOf "SET GLOBAL read_only = ON"
          msg `shouldSatisfy` T.isInfixOf "CHANGE REPLICATION SOURCE TO"
          msg `shouldSatisfy` T.isInfixOf "START REPLICA"
          msg `shouldSatisfy` T.isInfixOf "db1"
        Left err -> expectationFailure (show err)

    it "returns Dry run prefix in the output" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env $ dryRunDemote "db2" "db1"
      case result of
        Right msg -> msg `shouldSatisfy` T.isPrefixOf "Dry run:"
        Left err  -> expectationFailure (show err)

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
