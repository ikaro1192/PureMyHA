module PureMyHA.PauseReplicaSpec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
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
import PureMyHA.Types (ClusterTopology (..), NodeState (..), NodeRole (..), nsNodeId)
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

  -- Race scenario: ctSourceNodeId has already been restored to point at db1
  -- (via identifySource's fallback, which scans replicas' source refs) but
  -- db1's own nsRole is still stale Replica from a prior failover demote.
  -- CLI status reports sourceHost=db1, so wait_for_source succeeds — yet a
  -- check based solely on nsRole would erroneously accept pause/resume on
  -- the cluster source.
  describe "cluster-source rejection when nsRole is stale but ctSourceNodeId matches" $ do
    it "runPauseReplica rejects" $ do
      env <- setupRaceEnv
      result <- runApp env $ runPauseReplica "db1"
      result `shouldSatisfy` isSourceRejection

    it "runResumeReplica rejects" $ do
      env <- setupRaceEnv
      result <- runApp env $ runResumeReplica "db1"
      result `shouldSatisfy` isSourceRejection

    it "runStopReplication rejects" $ do
      env <- setupRaceEnv
      result <- runApp env $ runStopReplication "db1"
      result `shouldSatisfy` isSourceRejection

    it "runStartReplication rejects" $ do
      env <- setupRaceEnv
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

-- | Build a topology that reproduces the race: ctSourceNodeId points at db1
-- (as identifySource's fallback would restore after a reset), but db1's own
-- nsRole is stale Replica because its NodeProbed event has not yet been
-- applied.
setupRaceEnv :: IO ClusterEnv
setupRaceEnv = do
  tvar <- newDaemonState
  let base   = buildClusterTopology 1 "main" clusterHealthy
      db1Id  = nsNodeId healthySource
      topo   = base
        { ctNodes = Map.adjust (\ns -> ns { nsRole = Replica }) db1Id (ctNodes base) }
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
