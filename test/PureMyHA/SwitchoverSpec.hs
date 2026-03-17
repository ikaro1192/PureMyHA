module PureMyHA.SwitchoverSpec (spec) where

import qualified Data.Map.Strict as Map
import Test.Hspec
import Fixtures
import PureMyHA.Failover.Switchover (switchoverReconnectTargets)
import PureMyHA.Types

spec :: Spec
spec = describe "switchoverReconnectTargets" $ do

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
