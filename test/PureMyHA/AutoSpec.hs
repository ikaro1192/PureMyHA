module PureMyHA.AutoSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, addUTCTime)
import Test.Hspec
import Fixtures
import PureMyHA.Failover.Auto (checkAutoFailoverPreconditions)
import PureMyHA.Types

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
  }

healthyTopo :: ClusterTopology
healthyTopo = deadSourceTopo
  { ctNodes  = clusterHealthy
  , ctHealth = Healthy
  }

spec :: Spec
spec = describe "checkAutoFailoverPreconditions" $ do

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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
