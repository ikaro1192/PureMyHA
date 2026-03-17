module PureMyHA.DetectorSpec (spec) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
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

    it "returns UnreachableSource when source is unreachable but replica IO is Connecting" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsIsSource = True })
            , (NodeId "db2" 3306, NodeState
                { nsNodeId        = NodeId "db2" 3306
                , nsReplicaStatus = Just (mkReplicaStatus "db1" 3306 IOConnecting "")
                , nsGtidExecuted  = ""
                , nsIsSource      = False
                , nsHealth        = Healthy
                , nsLastSeen      = Just fixedTime
                , nsConnectError  = Nothing
                , nsErrantGtids   = ""
                })
            ]
      detectClusterHealth cluster `shouldBe` UnreachableSource

    it "returns NeedsAttention 'No source node detected' when no node is marked as source" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, healthySource { nsIsSource = False })
            ]
      detectClusterHealth cluster `shouldBe` NeedsAttention "No source node detected"

  describe "detectNodeHealth" $ do
    it "returns NeedsAttention when connect error is present" $ do
      let ns = healthySource { nsConnectError = Just "refused" }
      detectNodeHealth ns `shouldBe` NeedsAttention "refused"

    it "returns NeedsAttention when errant GTIDs are present" $ do
      let ns = healthySource { nsErrantGtids = "uuid3:1" }
      detectNodeHealth ns `shouldBe` NeedsAttention "Errant GTIDs: uuid3:1"

    it "returns Healthy for a source node with no errors" $
      detectNodeHealth healthySource `shouldBe` Healthy

    it "returns NeedsAttention IO error when replica IO=No with error message" $ do
      let rs = (mkReplicaStatus "db1" 3306 IONo "") { rsLastIOError = "Access denied" }
          ns = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
      detectNodeHealth ns `shouldBe` NeedsAttention "IO error: Access denied"

    it "returns NeedsAttention 'Replica IO not running' when IO=No with no error" $ do
      let rs = mkReplicaStatus "db1" 3306 IONo ""
          ns = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
      detectNodeHealth ns `shouldBe` NeedsAttention "Replica IO not running"

    it "returns NeedsAttention SQL error when SQL thread is stopped" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsReplicaSQLRunning = False, rsLastSQLError = "err" }
          ns = mkNodeState (NodeId "db2" 3306) False (Just rs) Healthy
      detectNodeHealth ns `shouldBe` NeedsAttention "SQL error: err"

    it "returns Healthy for a normal replica" $
      detectNodeHealth healthyReplica `shouldBe` Healthy

  describe "detectReplicaHealth" $ do
    it "returns NeedsAttention IO error when IO=No with error message" $ do
      let rs = (mkReplicaStatus "db1" 3306 IONo "") { rsLastIOError = "Access denied" }
      detectReplicaHealth rs `shouldBe` NeedsAttention "IO error: Access denied"

    it "returns NeedsAttention 'Replica IO not running' when IO=No with no error" $ do
      let rs = mkReplicaStatus "db1" 3306 IONo ""
      detectReplicaHealth rs `shouldBe` NeedsAttention "Replica IO not running"

    it "returns NeedsAttention SQL error when SQL thread is stopped" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsReplicaSQLRunning = False, rsLastSQLError = "sql-err" }
      detectReplicaHealth rs `shouldBe` NeedsAttention "SQL error: sql-err"

    it "returns Healthy for a healthy replica status" $ do
      let rs = mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100"
      detectReplicaHealth rs `shouldBe` Healthy

  describe "identifySource" $ do
    it "identifies the source node" $
      identifySource [healthySource, healthyReplica] `shouldBe` Just (NodeId "db1" 3306)

    it "returns Nothing for empty list" $
      identifySource [] `shouldBe` Nothing

    it "returns Just for a single node marked as source" $
      identifySource [healthySource] `shouldBe` Just (NodeId "db1" 3306)

    it "prefers the explicitly marked source node" $ do
      let explicit = mkNodeState (NodeId "db2" 3306) True Nothing Healthy
          other    = mkNodeState (NodeId "db1" 3306) False Nothing Healthy
      identifySource [other, explicit] `shouldBe` Just (NodeId "db2" 3306)

    it "returns Nothing when both nodes are replicas pointing to a third (ambiguous)" $ do
      let r1 = mkNodeState (NodeId "db1" 3306) False
                 (Just (mkReplicaStatus "db3" 3306 IOYes "")) Healthy
          r2 = mkNodeState (NodeId "db2" 3306) False
                 (Just (mkReplicaStatus "db3" 3306 IOYes "")) Healthy
      identifySource [r1, r2] `shouldBe` Nothing

isNeedsAttention :: NodeHealth -> Bool
isNeedsAttention (NeedsAttention _) = True
isNeedsAttention _                  = False
