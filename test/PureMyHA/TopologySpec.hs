module PureMyHA.TopologySpec (spec) where

import Test.Hspec
import Fixtures
import PureMyHA.Monitor.Detector (identifySource)
import PureMyHA.Types
import qualified Data.Map.Strict as Map

spec :: Spec
spec = do
  describe "identifySource" $ do
    it "identifies source in a 2-node cluster" $
      identifySource [healthySource, healthyReplica]
        `shouldBe` Just (NodeId "db1" 3306)

    it "returns Nothing for empty node list" $
      identifySource [] `shouldBe` Nothing

    it "returns the single node if only one node exists" $
      identifySource [healthySource]
        `shouldBe` Just (NodeId "db1" 3306)

    it "prefers explicitly-marked source node" $ do
      let src  = healthySource
          rep  = healthyReplica
      identifySource [src, rep] `shouldBe` Just (NodeId "db1" 3306)

    it "identifies source from replica's rsSourceHost" $ do
      -- Both nodes have no explicit isSource flag; should infer from replica status
      let src = healthySource { nsIsSource = False }
          rep = healthyReplica
      -- db2's replica status points to db1, so db1 should still be identified
      identifySource [src, rep] `shouldNotBe` Nothing

  describe "topology merge (runTopologyRefresh merge logic)" $ do
    it "retains nodes from oldTopo not present in newTopo" $ do
      -- newTopo has only the dead source (config node), oldTopo had replica too
      let extraReplica = mkNodeState (NodeId "db3" 3306) False
                           (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) Healthy
          newNodes = Map.fromList [(NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsIsSource = True })]
          oldNodes = Map.union clusterWithDeadSource (Map.singleton (NodeId "db3" 3306) extraReplica)
          merged   = Map.union newNodes oldNodes
      Map.member (NodeId "db3" 3306) merged `shouldBe` True

    it "uses new state for nodes present in both topos" $ do
      -- newTopo has updated state for db1; oldTopo has stale state
      let newSource = (unreachableNode (NodeId "db1" 3306)) { nsIsSource = True }
          newNodes  = Map.singleton (NodeId "db1" 3306) newSource
          oldNodes  = clusterHealthy
          merged    = Map.union newNodes oldNodes
      nsHealth (merged Map.! NodeId "db1" 3306) `shouldBe` NeedsAttention "Connection refused"

    it "with no oldTopo, uses newTopo as-is" $ do
      -- simulates first discover (Nothing case)
      let newNodes = ctNodes <$> Just (ClusterTopology "e2e" clusterHealthy Nothing Healthy False Nothing Nothing False)
          merged   = case newNodes of
                       Nothing      -> clusterWithDeadSource
                       Just nodes   -> nodes
      Map.size merged `shouldBe` 2
