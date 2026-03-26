module PureMyHA.WorkerSpec (spec) where

import Control.Concurrent.STM (atomically)
import Test.Hspec
import Fixtures
import PureMyHA.Config (ClusterConfig (..), Credentials (..), FailoverConfig (..), MonitoringConfig (..), FailureDetectionConfig (..))
import PureMyHA.Env (runApp)
import PureMyHA.Monitor.Worker (suppressBelowThreshold, enrichErrantGtids)
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types

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
  { fcAutoFailover              = True
  , fcMinReplicasForFailover    = 1
  , fcCandidatePriority         = []
  , fcWaitRelayLogTimeout       = 60
  , fcAutoFence                 = False
  , fcMaxReplicaLagForCandidate = Nothing
  , fcNeverPromote              = []
  }

spec :: Spec
spec = do

  describe "enrichErrantGtids" $ do

    it "returns ns unchanged when source is unreachable (skips TCP connect)" $ do
      tvar <- newDaemonState
      let topo = (buildClusterTopology "main" clusterWithDeadSource)
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
      let topo = (buildClusterTopology "main" clusterWithDeadSource)
                   { ctSourceNodeId = Nothing }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env (enrichErrantGtids healthyReplica)
      nsErrantGtids result `shouldBe` nsErrantGtids healthyReplica

  describe "suppressBelowThreshold" $ do
    let threshold = 3
        errNs     = healthySource
                      { nsHealth              = NeedsAttention "refused"
                      , nsProbeResult         = ProbeFailure "refused"
                      , nsConsecutiveFailures = 1
                      }

    it "keeps previous health when failCount is below threshold" $
      suppressBelowThreshold threshold 1 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = Healthy }

    it "applies NeedsAttention when failCount equals threshold" $
      suppressBelowThreshold threshold 3 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = NeedsAttention "refused" }

    it "applies NeedsAttention when failCount exceeds threshold" $
      suppressBelowThreshold threshold 5 (Just healthySource) errNs
        `shouldBe` errNs { nsHealth = NeedsAttention "refused" }

    it "uses Healthy as fallback when no previous state (first probe)" $
      suppressBelowThreshold threshold 1 Nothing errNs
        `shouldBe` errNs { nsHealth = Healthy }

    it "does not suppress when failCount is 0 (success case)" $
      suppressBelowThreshold threshold 0 (Just healthySource) healthySource
        `shouldBe` healthySource

    it "resets to Healthy on success after previous NeedsAttention" $ do
      let prev = healthySource { nsHealth = NeedsAttention "err", nsConsecutiveFailures = 2 }
          curr = healthySource { nsConsecutiveFailures = 0 }
      suppressBelowThreshold threshold 0 (Just prev) curr `shouldBe` curr

    it "preserves NeedsAttention from previous state when below threshold" $ do
      let prev = healthySource { nsHealth = NeedsAttention "prior err", nsConsecutiveFailures = 2 }
      suppressBelowThreshold threshold 2 (Just prev) errNs
        `shouldBe` errNs { nsHealth = NeedsAttention "prior err" }
