module PureMyHA.TopologySpec (spec) where

import Test.Hspec
import Fixtures
import PureMyHA.Monitor.Detector (identifySource)
import PureMyHA.Types

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
