module PureMyHA.CandidateSpec (spec) where

import qualified Data.Map.Strict as Map
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

    it "rejects --to when target is the source node" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate nodes [] (Just "db1") `shouldSatisfy` isLeft

    it "returns Left when only unreachable replicas exist" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db5" 3306, unreachableReplica)
            ]
      selectCandidate nodes [] Nothing `shouldBe` Left "No suitable failover candidate found"

    it "rejects --to when target is unreachable" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db4" 3306, unreachableNode (NodeId "db4" 3306))
            ]
      selectCandidate nodes [] (Just "db4") `shouldSatisfy` isLeft

    it "selects replica with higher GTID score when no priority set" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = NodeId "db3" 3306
            , nsReplicaStatus = Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")
            }
          nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthyReplica)
            , (NodeId "db3" 3306, replicaLongGtid)
            ]
      selectCandidate nodes [] Nothing `shouldBe` Right (NodeId "db3" 3306)

  describe "rankCandidates" $ do
    it "returns empty list for no eligible nodes" $
      rankCandidates [healthySource] [] `shouldBe` []

    it "excludes errant GTID nodes" $
      rankCandidates [healthyReplica, replicaWithErrantGtid] []
        `shouldSatisfy` (\cs -> all (\c -> ciNodeId c /= NodeId "db3" 3306) cs)

    it "returns single-element list for one eligible replica" $
      length (rankCandidates [healthyReplica] []) `shouldBe` 1

    it "excludes unreachable replicas" $ do
      let result = rankCandidates [healthyReplica, unreachableReplica] []
      map ciNodeId result `shouldBe` [NodeId "db2" 3306]

    it "orders by GTID score descending when no priority" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = NodeId "db3" 3306
            , nsReplicaStatus = Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")
            }
      let result = rankCandidates [healthyReplica, replicaLongGtid] []
      ciNodeId (head result) `shouldBe` NodeId "db3" 3306

    it "priority order takes precedence over GTID score" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = NodeId "db3" 3306
            , nsReplicaStatus = Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")
            }
          -- db2 has lower GTID but appears first in priority
          priorities = [CandidatePriority "db2"]
      let result = rankCandidates [healthyReplica, replicaLongGtid] priorities
      ciNodeId (head result) `shouldBe` NodeId "db2" 3306

  describe "isEligibleCandidate" $ do
    it "returns True for a normal replica" $
      isEligibleCandidate healthyReplica `shouldBe` True

    it "returns False for the source node" $
      isEligibleCandidate healthySource `shouldBe` False

    it "returns False for a replica with errant GTIDs" $
      isEligibleCandidate replicaWithErrantGtid `shouldBe` False

    it "returns False for an unreachable node" $
      isEligibleCandidate unreachableReplica `shouldBe` False

  describe "hasErrantGtid" $ do
    it "returns False when errant GTIDs are empty" $
      hasErrantGtid healthyReplica `shouldBe` False

    it "returns True when errant GTIDs are present" $
      hasErrantGtid replicaWithErrantGtid `shouldBe` True

  describe "hasConnectError" $ do
    it "returns False when no connect error" $
      hasConnectError healthyReplica `shouldBe` False

    it "returns True when connect error is present" $
      hasConnectError unreachableReplica `shouldBe` True

  describe "priorityRank" $ do
    it "returns maxBound when host not in priority list" $
      priorityRank [] "db2" `shouldBe` maxBound

    it "returns 0 when host is first in priority list" $
      priorityRank [CandidatePriority "db2"] "db2" `shouldBe` 0

    it "returns 1 when host is second in priority list" $
      priorityRank [CandidatePriority "db1", CandidatePriority "db2"] "db2" `shouldBe` 1

  describe "gtidScore" $ do
    it "returns 0 for empty GTID" $
      gtidScore (CandidateInfo (NodeId "db2" 3306) "" 0) `shouldBe` 0

    it "returns string length for non-empty GTID" $
      gtidScore (CandidateInfo (NodeId "db2" 3306) "uuid1:1-100" 0) `shouldBe` 11

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
