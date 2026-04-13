module PureMyHA.PauseReplicaSpec (spec) where

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
import PureMyHA.Env (runApp, ClusterEnv)
import PureMyHA.Failover.PauseReplica
  ( runPauseReplica, runResumeReplica
  , runStopReplication, runStartReplication
  )
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import Data.List.NonEmpty (NonEmpty ((:|)))

spec :: Spec
spec = do
  describe "runPauseReplica" $ do
    it "rejects source node" $ do
      env <- setupEnv
      result <- runApp env $ runPauseReplica "db1"
      result `shouldSatisfy` isSourceRejection

    it "accepts replica node" $ do
      env <- setupEnv
      result <- runApp env $ runPauseReplica "db2"
      result `shouldBe` Right ()

    it "returns Left when node not found" $ do
      env <- setupEnv
      result <- runApp env $ runPauseReplica "nonexistent"
      result `shouldBe` Left "Node not found: nonexistent"

  describe "runResumeReplica" $ do
    it "rejects source node" $ do
      env <- setupEnv
      result <- runApp env $ runResumeReplica "db1"
      result `shouldSatisfy` isSourceRejection

    it "accepts replica node" $ do
      env <- setupEnv
      result <- runApp env $ runResumeReplica "db2"
      result `shouldBe` Right ()

  describe "runStopReplication" $ do
    it "rejects source node" $ do
      env <- setupEnv
      result <- runApp env $ runStopReplication "db1"
      result `shouldSatisfy` isSourceRejection

  describe "runStartReplication" $ do
    it "rejects source node" $ do
      env <- setupEnv
      result <- runApp env $ runStartReplication "db1"
      result `shouldSatisfy` isSourceRejection

-- | Check that the result is a Left containing source rejection message
isSourceRejection :: Either T.Text () -> Bool
isSourceRejection (Left msg) = "source" `T.isInfixOf` T.toLower msg
isSourceRejection _          = False

setupEnv :: IO ClusterEnv
setupEnv = do
  tvar <- newDaemonState
  let topo = buildClusterTopology 1 "main" clusterHealthy
  atomically $ updateClusterTopology tvar topo
  mkTestEnv tvar testCC testFC

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
