module PureMyHA.DetectorSpec (spec) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Test.Hspec
import Fixtures
import PureMyHA.Monitor.Detector
import PureMyHA.Types

spec :: Spec
spec = do
  describe "detectClusterHealth" $ do
    it "returns Healthy for a healthy cluster" $
      detectClusterHealth clusterHealthy `shouldBe` Healthy

    it "returns DeadSource when source is down and replicas show IO=No" $
      detectClusterHealth clusterWithDeadSource `shouldBe` DeadSource

    it "returns DeadSourceAndAllReplicas when all nodes are unreachable" $ do
      let allDead = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsIsSource = True })
            , (NodeId "db2" 3306, unreachableNode (NodeId "db2" 3306))
            ]
      detectClusterHealth allDead `shouldBe` DeadSourceAndAllReplicas

    it "returns SplitBrainSuspected with multiple sources" $ do
      let twoSources = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthySource { nsNodeId = NodeId "db2" 3306 })
            ]
      detectClusterHealth twoSources `shouldBe` SplitBrainSuspected

    it "returns NeedsAttention for empty cluster" $
      detectClusterHealth Map.empty `shouldSatisfy` isNeedsAttention

  describe "identifySource" $ do
    it "identifies the source node" $
      identifySource [healthySource, healthyReplica] `shouldBe` Just (NodeId "db1" 3306)

    it "returns Nothing for empty list" $
      identifySource [] `shouldBe` Nothing

isNeedsAttention :: NodeHealth -> Bool
isNeedsAttention (NeedsAttention _) = True
isNeedsAttention _                  = False
