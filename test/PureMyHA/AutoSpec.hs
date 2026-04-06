module PureMyHA.AutoSpec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, addUTCTime)
import Test.Hspec
import Fixtures
import PureMyHA.Config
  ( ClusterConfig (..), Credentials (..), FailoverConfig (..)
  , MonitoringConfig (..), FailureDetectionConfig (..), NodeConfig (..)
  , Port (..), PositiveDuration (..), AtLeastOne (..)
  )
import PureMyHA.Env (runApp)
import PureMyHA.Failover.Auto (checkAutoFailoverPreconditions, simulateFailover)
import PureMyHA.Failover.Candidate (selectSurvivor)
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types
import Data.List.NonEmpty (NonEmpty ((:|)))

now :: UTCTime
now = UTCTime (fromGregorian 2024 6 1) 0

deadSourceTopo :: ClusterTopology
deadSourceTopo = ClusterTopology
  { ctClusterName          = "test"
  , ctNodes                = clusterWithDeadSource
  , ctSourceNodeId         = Just (NodeId "db1" 3306)
  , ctHealth               = DeadSource
  , ctObservedHealthy      = True
  , ctRecoveryBlockedUntil = Nothing
  , ctLastFailoverAt       = Nothing
  , ctPaused               = False
  , ctTopologyDrift        = False
  , ctLastEmergencyCheckAt = Nothing
  }

healthyTopo :: ClusterTopology
healthyTopo = deadSourceTopo
  { ctNodes  = clusterHealthy
  , ctHealth = Healthy
  }

spec :: Spec
spec = do

  describe "selectSurvivor" $ do

    it "selects the node with the higher GTID count" $ do
      let sources = [splitBrainSource1, splitBrainSource2]
      selectSurvivor [] [] sources `shouldBe` Just (NodeId "db2" 3306)

    it "selects the only node when given a single source" $ do
      selectSurvivor [] [] [splitBrainSource1] `shouldBe` Just (NodeId "db1" 3306)

    it "returns Nothing for empty list" $
      selectSurvivor [] [] [] `shouldBe` Nothing

  describe "checkAutoFailoverPreconditions" $ do

    it "returns Right () when all conditions are met" $
      checkAutoFailoverPreconditions now deadSourceTopo 1
        `shouldBe` Right ()

    it "returns Left when cluster is not in DeadSource state" $
      checkAutoFailoverPreconditions now healthyTopo 1
        `shouldSatisfy` isLeft

    it "returns Left when recovery block period is active" $ do
      let futureDeadline = addUTCTime 3600 now
          blockedTopo    = deadSourceTopo { ctRecoveryBlockedUntil = Just futureDeadline }
      checkAutoFailoverPreconditions now blockedTopo 1
        `shouldSatisfy` isLeft

    it "returns Right () when recovery block deadline has passed" $ do
      let pastDeadline = addUTCTime (-1) now
          expiredTopo  = deadSourceTopo { ctRecoveryBlockedUntil = Just pastDeadline }
      checkAutoFailoverPreconditions now expiredTopo 1
        `shouldBe` Right ()

    it "returns Left when replica count is below minReplicas" $ do
      let noReplicaTopo = deadSourceTopo
            { ctNodes = Map.fromList
                [ (NodeId "db1" 3306
                  , (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
                ]
            }
      checkAutoFailoverPreconditions now noReplicaTopo 1
        `shouldSatisfy` isLeft

    it "returns Left when minReplicas=2 but only one replica present" $
      checkAutoFailoverPreconditions now deadSourceTopo 2
        `shouldSatisfy` isLeft

    it "returns Left when cluster is paused" $
      checkAutoFailoverPreconditions now (deadSourceTopo { ctPaused = True }) 1
        `shouldSatisfy` isLeft

  describe "simulateFailover" $ do

    it "returns Left when cluster not found" $ do
      tvar <- newDaemonState
      env  <- mkTestEnv tvar testCC testFC
      result <- runApp env simulateFailover
      result `shouldBe` Left "Cluster not found"

    it "returns candidate when cluster is healthy (health check bypassed for simulation)" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env simulateFailover
      case result of
        Right msg -> do
          msg `shouldSatisfy` T.isInfixOf "Would promote"
          msg `shouldSatisfy` T.isInfixOf "db2"
        Left err  -> expectationFailure (show err)

    it "returns candidate host when cluster is in DeadSource state" $ do
      tvar <- newDaemonState
      let topo = deadSourceTopo { ctClusterName = "main" }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env simulateFailover
      case result of
        Right msg -> do
          msg `shouldSatisfy` T.isInfixOf "Would promote"
          msg `shouldSatisfy` T.isInfixOf "db2"
        Left err -> expectationFailure (show err)

    it "reports all eligible candidates" $ do
      tvar <- newDaemonState
      let replica2 = healthyReplica { nsNodeId = NodeId "db3" 3306 }
          nodes = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, healthyReplica)
            , (NodeId "db3" 3306, replica2)
            ]
          topo = deadSourceTopo { ctClusterName = "main", ctNodes = nodes }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env simulateFailover
      case result of
        Right msg -> msg `shouldSatisfy` T.isInfixOf "All eligible candidates"
        Left err  -> expectationFailure (show err)

    it "shows candidate even when failover is paused, with a pause note" $ do
      tvar <- newDaemonState
      let topo = (deadSourceTopo { ctClusterName = "main" }) { ctPaused = True }
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env simulateFailover
      case result of
        Right msg -> do
          msg `shouldSatisfy` T.isInfixOf "Would promote"
          msg `shouldSatisfy` T.isInfixOf "paused"
        Left err -> expectationFailure (show err)

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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

-- | Two source nodes simulating a split-brain scenario
splitBrainSource1 :: NodeState
splitBrainSource1 = healthySource
  { nsNodeId    = NodeId "db1" 3306
  , nsProbeResult = ProbeSuccess fixedTime Nothing (unsafeParseGtidSet "uuid1:1-50")
  }

splitBrainSource2 :: NodeState
splitBrainSource2 = healthySource
  { nsNodeId    = NodeId "db2" 3306
  , nsProbeResult = ProbeSuccess fixedTime Nothing (unsafeParseGtidSet "uuid1:1-100")
  }
