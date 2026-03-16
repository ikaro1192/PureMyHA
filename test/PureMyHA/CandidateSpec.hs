module PureMyHA.CandidateSpec (spec) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Test.Hspec
import Fixtures
import PureMyHA.Config (CandidatePriority (..))
import PureMyHA.Failover.Candidate
import PureMyHA.Types

spec :: Spec
spec = do
  describe "selectCandidate" $ do
    it "selects the only available replica" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate nodes [] Nothing `shouldBe` Right (NodeId "db2" 3306)

    it "excludes replicas with errant GTIDs" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            , (NodeId "db3" 3306, replicaWithErrantGtid)
            ]
      selectCandidate nodes [] Nothing `shouldBe` Right (NodeId "db2" 3306)

    it "respects candidate_priority order" $ do
      let replica3 = healthyReplica { nsNodeId = NodeId "db3" 3306 }
          nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            , (NodeId "db3" 3306, replica3)
            ]
          priorities = [CandidatePriority "db3"]
      selectCandidate nodes priorities Nothing `shouldBe` Right (NodeId "db3" 3306)

    it "validates explicit --to host" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate nodes [] (Just "db2") `shouldBe` Right (NodeId "db2" 3306)

    it "rejects --to host not found" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate nodes [] (Just "db99") `shouldSatisfy` isLeft

    it "rejects --to host with errant GTIDs" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db3" 3306, replicaWithErrantGtid)
            ]
      selectCandidate nodes [] (Just "db3") `shouldSatisfy` isLeft

    it "returns Left when no eligible candidates" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            ]
      selectCandidate nodes [] Nothing `shouldSatisfy` isLeft

  describe "rankCandidates" $ do
    it "returns empty list for no eligible nodes" $
      rankCandidates [healthySource] [] `shouldBe` []

    it "excludes errant GTID nodes" $
      rankCandidates [healthyReplica, replicaWithErrantGtid] []
        `shouldSatisfy` (\cs -> all (\c -> ciNodeId c /= NodeId "db3" 3306) cs)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
