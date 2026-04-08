module PureMyHA.CandidateSpec (spec) where

import Data.Either (isLeft)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Test.Hspec
import Fixtures
import PureMyHA.Config (CandidatePriority (..))
import PureMyHA.Failover.Candidate
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.Types

spec :: Spec
spec = do
  describe "selectCandidate" $ do
    it "selects the only available replica" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "excludes replicas with errant GTIDs" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, replicaWithErrantGtid)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "respects candidate_priority order" $ do
      let replica3 = healthyReplica { nsNodeId = unsafeNodeId "db3" 3306 }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, replica3)
            ]
          priorities = [CandidatePriority "db3"]
      selectCandidate [] Nothing nodes priorities Nothing `shouldBe` Right (unsafeNodeId "db3" 3306)

    it "validates explicit --to host" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate [] Nothing nodes [] (Just "db2") `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "rejects --to host not found" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate [] Nothing nodes [] (Just "db99") `shouldSatisfy` isLeft

    it "rejects --to host with errant GTIDs" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db3" 3306, replicaWithErrantGtid)
            ]
      selectCandidate [] Nothing nodes [] (Just "db3") `shouldSatisfy` isLeft

    it "returns Left when no eligible candidates" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldSatisfy` isLeft

    it "rejects --to when target is the source node" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate [] Nothing nodes [] (Just "db1") `shouldSatisfy` isLeft

    it "returns Left when only unreachable replicas exist" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db5" 3306, unreachableReplica)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Left "No suitable failover candidate found"

    it "rejects --to when target is unreachable" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db4" 3306, unreachableNode (unsafeNodeId "db4" 3306))
            ]
      selectCandidate [] Nothing nodes [] (Just "db4") `shouldSatisfy` isLeft

    it "selects replica with higher GTID score when no priority set" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = unsafeNodeId "db3" 3306
            , nsProbeResult = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")) emptyGtidSet
            }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, replicaLongGtid)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db3" 3306)

    it "excludes Lagging replica from auto-select" $ do
      let laggingReplica = healthyReplica
            { nsNodeId = unsafeNodeId "db3" 3306
            , nsHealth  = Lagging 60
            }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, laggingReplica)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "excludes replica exceeding maxLag from auto-select" $ do
      let slowReplica = healthyReplica
            { nsNodeId     = unsafeNodeId "db3" 3306
            , nsProbeResult = ProbeSuccess fixedTime
                (Just (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 60 }) emptyGtidSet
            }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, slowReplica)
            ]
      selectCandidate [] (Just 30) nodes [] Nothing `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "excludes paused replica from auto-select" $ do
      let pausedReplica = healthyReplica { nsPaused = Paused }
          replica3 = healthyReplica { nsNodeId = unsafeNodeId "db3" 3306 }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, pausedReplica)
            , (unsafeNodeId "db3" 3306, replica3)
            ]
      selectCandidate [] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db3" 3306)

    it "rejects --to for paused replica" $ do
      let pausedReplica = healthyReplica { nsPaused = Paused }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, pausedReplica)
            ]
      selectCandidate [] Nothing nodes [] (Just "db2") `shouldBe` Left "Cannot promote: node is paused: db2"

    it "returns Left when all replicas exceed maxLag" $ do
      let slowReplica = healthyReplica
            { nsProbeResult = ProbeSuccess fixedTime
                (Just (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 60 }) emptyGtidSet
            }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, slowReplica)
            ]
      selectCandidate [] (Just 30) nodes [] Nothing `shouldSatisfy` isLeft

  describe "rankCandidates" $ do
    it "returns Nothing for no eligible nodes" $
      rankCandidates [] Nothing [healthySource] [] `shouldBe` Nothing

    it "excludes errant GTID nodes" $
      fmap NE.toList (rankCandidates [] Nothing [healthyReplica, replicaWithErrantGtid] [])
        `shouldSatisfy` maybe False (all (\c -> ciNodeId c /= unsafeNodeId "db3" 3306))

    it "returns single-element list for one eligible replica" $
      fmap NE.length (rankCandidates [] Nothing [healthyReplica] []) `shouldBe` Just 1

    it "excludes unreachable replicas" $ do
      let result = rankCandidates [] Nothing [healthyReplica, unreachableReplica] []
      fmap (NE.toList . NE.map ciNodeId) result `shouldBe` Just [unsafeNodeId "db2" 3306]

    it "orders by GTID score descending when no priority" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = unsafeNodeId "db3" 3306
            , nsProbeResult = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")) emptyGtidSet
            }
      let result = rankCandidates [] Nothing [healthyReplica, replicaLongGtid] []
      fmap (ciNodeId . NE.head) result `shouldBe` Just (unsafeNodeId "db3" 3306)

    it "priority order takes precedence over GTID score" $ do
      let replicaLongGtid = healthyReplica
            { nsNodeId = unsafeNodeId "db3" 3306
            , nsProbeResult = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-1,uuid2:1-200,uuid3:1-50")) emptyGtidSet
            }
          -- db2 has lower GTID but appears first in priority
          priorities = [CandidatePriority "db2"]
      let result = rankCandidates [] Nothing [healthyReplica, replicaLongGtid] priorities
      fmap (ciNodeId . NE.head) result `shouldBe` Just (unsafeNodeId "db2" 3306)

    it "excludes Lagging nodes from candidates" $ do
      let laggingReplica = healthyReplica
            { nsNodeId = unsafeNodeId "db3" 3306
            , nsHealth  = Lagging 90
            }
      let result = rankCandidates [] Nothing [healthyReplica, laggingReplica] []
      fmap (NE.toList . NE.map ciNodeId) result `shouldBe` Just [unsafeNodeId "db2" 3306]

  describe "isEligibleCandidate" $ do
    it "returns True for a normal replica" $
      isEligibleCandidate [] Nothing healthyReplica `shouldBe` True

    it "returns False for the source node" $
      isEligibleCandidate [] Nothing healthySource `shouldBe` False

    it "returns False for a replica with errant GTIDs" $
      isEligibleCandidate [] Nothing replicaWithErrantGtid `shouldBe` False

    it "returns False for an unreachable node" $
      isEligibleCandidate [] Nothing unreachableReplica `shouldBe` False

    it "returns False for a Lagging replica" $ do
      let lagging = healthyReplica { nsHealth = Lagging 45 }
      isEligibleCandidate [] Nothing lagging `shouldBe` False

    it "returns False for a paused replica" $ do
      let paused = healthyReplica { nsPaused = Paused }
      isEligibleCandidate [] Nothing paused `shouldBe` False

    it "returns False when lag exceeds maxLag" $ do
      let slowReplica = healthyReplica
            { nsProbeResult = ProbeSuccess fixedTime
                (Just (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 60 }) emptyGtidSet
            }
      isEligibleCandidate [] (Just 30) slowReplica `shouldBe` False

    it "returns True when lag is exactly at maxLag" $ do
      let replicaAtLimit = healthyReplica
            { nsProbeResult = ProbeSuccess fixedTime
                (Just (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 30 }) emptyGtidSet
            }
      isEligibleCandidate [] (Just 30) replicaAtLimit `shouldBe` True

  describe "never_promote" $ do
    it "excludes never_promote host from auto-select" $ do
      let analyticsReplica = healthyReplica { nsNodeId = unsafeNodeId "db3" 3306 }
          nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            , (unsafeNodeId "db3" 3306, analyticsReplica)
            ]
      selectCandidate ["db3"] Nothing nodes [] Nothing `shouldBe` Right (unsafeNodeId "db2" 3306)

    it "rejects --to for never_promote host" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate ["db2"] Nothing nodes [] (Just "db2") `shouldSatisfy` isLeft

    it "returns Left when all replicas are in never_promote" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
      selectCandidate ["db2"] Nothing nodes [] Nothing `shouldSatisfy` isLeft

    it "never_promote error message contains host name" $ do
      let nodes = Map.fromList
            [ (unsafeNodeId "db1" 3306, healthySource)
            , (unsafeNodeId "db2" 3306, healthyReplica)
            ]
          result = selectCandidate ["db2"] Nothing nodes [] (Just "db2")
      result `shouldBe` Left "Cannot promote: host is in never_promote list: db2"

  describe "isNeverPromote" $ do
    it "returns True when host is in never_promote list" $
      isNeverPromote ["db2"] healthyReplica `shouldBe` True

    it "returns False when host is not in never_promote list" $
      isNeverPromote ["db3"] healthyReplica `shouldBe` False

    it "returns False for empty never_promote list" $
      isNeverPromote [] healthyReplica `shouldBe` False

  describe "isEligibleCandidate (never_promote)" $ do
    it "returns False for never_promote host" $
      isEligibleCandidate ["db2"] Nothing healthyReplica `shouldBe` False

    it "returns True when never_promote list is empty" $
      isEligibleCandidate [] Nothing healthyReplica `shouldBe` True

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
      gtidScore (CandidateInfo (unsafeNodeId "db2" 3306) emptyGtidSet 0) `shouldBe` 0

    it "returns transaction count for a range" $
      gtidScore (CandidateInfo (unsafeNodeId "db2" 3306) (unsafeParseGtidSet "uuid1:1-100") 0) `shouldBe` 100

    it "returns 1 for a single transaction" $
      gtidScore (CandidateInfo (unsafeNodeId "db2" 3306) (unsafeParseGtidSet "uuid1:5") 0) `shouldBe` 1

    it "sums transactions across multiple UUIDs" $
      gtidScore (CandidateInfo (unsafeNodeId "db2" 3306) (unsafeParseGtidSet "uuid1:1-100,uuid2:1-3") 0) `shouldBe` 103

