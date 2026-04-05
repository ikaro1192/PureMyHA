module PureMyHA.DetectorSpec (spec) where

import qualified Data.Map.Strict as Map
import Test.Hspec
import Fixtures
import PureMyHA.Monitor.Detector
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.Types

spec :: Spec
spec = do
  describe "detectClusterHealth" $ do
    it "returns Healthy for a healthy cluster" $
      detectClusterHealth 1 clusterHealthy `shouldBe` Healthy

    it "returns DeadSource when source is down and replicas show IO=No" $
      detectClusterHealth 1 clusterWithDeadSource `shouldBe` DeadSource

    it "returns DeadSourceAndAllReplicas when all nodes are unreachable" $ do
      let allDead = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, unreachableNode (NodeId "db2" 3306))
            ]
      detectClusterHealth 1 allDead `shouldBe` DeadSourceAndAllReplicas

    it "returns SplitBrainSuspected with multiple sources" $ do
      let twoSources = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, healthySource { nsNodeId = NodeId "db2" 3306 })
            ]
      detectClusterHealth 1 twoSources `shouldBe` SplitBrainSuspected

    it "returns NeedsAttention for empty cluster" $
      detectClusterHealth 1 Map.empty `shouldSatisfy` isNeedsAttention

    it "returns DeadSource when source is unreachable and replica IO is Connecting" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, NodeState
                { nsNodeId              = NodeId "db2" 3306
                , nsRole                = Replica
                , nsHealth              = Healthy
                , nsProbeResult         = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOConnecting "")) emptyGtidSet
                , nsErrantGtids         = emptyGtidSet
                , nsPaused              = False
                , nsConsecutiveFailures = 0
                , nsFenced              = False
                })
            ]
      detectClusterHealth 1 cluster `shouldBe` DeadSource

    it "returns UnreachableSource when source is unreachable but replica IO is still Yes" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, NodeState
                { nsNodeId              = NodeId "db2" 3306
                , nsRole                = Replica
                , nsHealth              = Healthy
                , nsProbeResult         = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IOYes "")) emptyGtidSet
                , nsErrantGtids         = emptyGtidSet
                , nsPaused              = False
                , nsConsecutiveFailures = 0
                , nsFenced              = False
                })
            ]
      detectClusterHealth 1 cluster `shouldBe` UnreachableSource

    it "returns NoSourceDetected when no node is marked as source and replicas have no source info" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, healthySource { nsRole = Replica })
            ]
      detectClusterHealth 1 cluster `shouldBe` NoSourceDetected

    it "returns DeadSource when source has nsRole=Replica (startup race) but replicas point to it with IO=No" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, unreachableNode (NodeId "db1" 3306))  -- nsRole=Replica by default
            , (NodeId "db2" 3306, mkNodeState (NodeId "db2" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            , (NodeId "db3" 3306, mkNodeState (NodeId "db3" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            ]
      detectClusterHealth 1 cluster `shouldBe` DeadSource

  describe "detectClusterHealth quorum" $ do
    it "returns InsufficientQuorum when unanimous IO=No but only 1 witness and minReplicas=2" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, mkNodeState (NodeId "db2" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            ]
      detectClusterHealth 2 cluster `shouldBe` InsufficientQuorum

    it "returns DeadSource when 2 witnesses meet minReplicas=2 and all IO=No" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, mkNodeState (NodeId "db2" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            , (NodeId "db3" 3306, mkNodeState (NodeId "db3" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            ]
      detectClusterHealth 2 cluster `shouldBe` DeadSource

    it "returns UnreachableSource when not unanimous (1 of 3 replicas with IO=No, minReplicas=1)" $ do
      let cluster = Map.fromList
            [ (NodeId "db1" 3306, (unreachableNode (NodeId "db1" 3306)) { nsRole = Source })
            , (NodeId "db2" 3306, mkNodeState (NodeId "db2" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IONo "")) Healthy)
            , (NodeId "db3" 3306, mkNodeState (NodeId "db3" 3306) Replica (Just (mkReplicaStatus "db1" 3306 IOYes "")) Healthy)
            ]
      detectClusterHealth 1 cluster `shouldBe` UnreachableSource

    it "returns DeadSource with minReplicas=1 (default backward-compatible behavior)" $
      detectClusterHealth 1 clusterWithDeadSource `shouldBe` DeadSource

  describe "detectNodeHealth" $ do
    it "returns NodeUnreachable when connect error is present" $ do
      let ns = healthySource { nsProbeResult = ProbeFailure "refused" }
      detectNodeHealth Nothing ns `shouldBe` NodeUnreachable "refused"

    it "returns ErrantGtidDetected when errant GTIDs are present" $ do
      let gs = unsafeParseGtidSet "uuid3:1"
          ns = healthySource { nsErrantGtids = gs }
      detectNodeHealth Nothing ns `shouldBe` ErrantGtidDetected gs

    it "returns Healthy for a source node with no errors" $
      detectNodeHealth Nothing healthySource `shouldBe` Healthy

    it "returns ReplicaIOStopped when replica IO=No with error message" $ do
      let rs = (mkReplicaStatus "db1" 3306 IONo "") { rsLastIOError = "Access denied" }
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth Nothing ns `shouldBe` ReplicaIOStopped "Access denied"

    it "returns ReplicaIOStopped with empty text when IO=No with no error" $ do
      let rs = mkReplicaStatus "db1" 3306 IONo ""
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth Nothing ns `shouldBe` ReplicaIOStopped ""

    it "returns ReplicaSQLStopped when SQL thread is stopped" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsReplicaSQLRunning = SQLStopped, rsLastSQLError = "err" }
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth Nothing ns `shouldBe` ReplicaSQLStopped "err"

    it "returns Healthy for a normal replica" $
      detectNodeHealth Nothing healthyReplica `shouldBe` Healthy

    it "returns NotReplicating for a Replica-role node with no replica status" $ do
      let ns = mkNodeState (NodeId "db3" 3306) Replica Nothing Healthy
      detectNodeHealth Nothing ns `shouldBe` NotReplicating

    it "returns Healthy for Source node with residual replica status" $ do
      let rs = mkReplicaStatus "db1" 3306 IOConnecting ""
          ns = mkNodeState (NodeId "db2" 3306) Source (Just rs) Healthy
      detectNodeHealth Nothing ns `shouldBe` Healthy

    it "returns Lagging when lag meets threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 30 }
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth (Just 30) ns `shouldBe` Lagging 30

    it "returns Healthy when lag is below threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 29 }
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth (Just 30) ns `shouldBe` Healthy

    it "returns Healthy when no lag threshold is set" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 3600 }
          ns = mkNodeState (NodeId "db2" 3306) Replica (Just rs) Healthy
      detectNodeHealth Nothing ns `shouldBe` Healthy

  -- detectReplicaHealth basic cases are covered by detectNodeHealth tests above
  -- (detectNodeHealth delegates to detectReplicaHealth internally)

  describe "detectReplicaHealth lag threshold" $ do
    it "returns Lagging when lag equals threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 30 }
      detectReplicaHealth (Just 30) rs `shouldBe` Lagging 30

    it "returns Lagging when lag exceeds threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 31 }
      detectReplicaHealth (Just 30) rs `shouldBe` Lagging 31

    it "returns Healthy when lag is one below threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 29 }
      detectReplicaHealth (Just 30) rs `shouldBe` Healthy

    it "returns Healthy when lag is zero and threshold is set" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 0 }
      detectReplicaHealth (Just 30) rs `shouldBe` Healthy

    it "returns Healthy when no threshold is set regardless of lag" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Just 3600 }
      detectReplicaHealth Nothing rs `shouldBe` Healthy

    it "returns Healthy when lag is unknown (Nothing) even with threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "") { rsSecondsBehindSource = Nothing }
      detectReplicaHealth (Just 30) rs `shouldBe` Healthy

    it "IO error takes precedence over lag threshold" $ do
      let rs = (mkReplicaStatus "db1" 3306 IONo "") { rsLastIOError = "err", rsSecondsBehindSource = Just 100 }
      detectReplicaHealth (Just 30) rs `shouldBe` ReplicaIOStopped "err"

  describe "identifySource" $ do
    it "identifies the source node" $
      identifySource [healthySource, healthyReplica] `shouldBe` Just (NodeId "db1" 3306)

    it "returns Nothing for empty list" $
      identifySource [] `shouldBe` Nothing

    it "returns Just for a single node marked as source" $
      identifySource [healthySource] `shouldBe` Just (NodeId "db1" 3306)

    it "prefers the explicitly marked source node" $ do
      let explicit = mkNodeState (NodeId "db2" 3306) Source Nothing Healthy
          other    = mkNodeState (NodeId "db1" 3306) Replica Nothing Healthy
      identifySource [other, explicit] `shouldBe` Just (NodeId "db2" 3306)

    it "returns Nothing when both nodes are replicas pointing to a third (ambiguous)" $ do
      let r1 = mkNodeState (NodeId "db1" 3306) Replica
                 (Just (mkReplicaStatus "db3" 3306 IOYes "")) Healthy
          r2 = mkNodeState (NodeId "db2" 3306) Replica
                 (Just (mkReplicaStatus "db3" 3306 IOYes "")) Healthy
      identifySource [r1, r2] `shouldBe` Nothing

    it "identifies source from replica's rsSourceHost when no explicit Source role" $ do
      let src = healthySource { nsRole = Replica }
          rep = healthyReplica
      -- db2's replica status points to db1, so db1 should be identified as source
      identifySource [src, rep] `shouldBe` Just (NodeId "db1" 3306)

isNeedsAttention :: NodeHealth -> Bool
isNeedsAttention (NeedsAttention _) = True
isNeedsAttention _                  = False
