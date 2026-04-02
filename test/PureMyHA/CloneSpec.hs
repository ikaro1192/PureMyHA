module PureMyHA.CloneSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Either (isLeft)
import Test.Hspec
import Fixtures
import PureMyHA.Clone
import PureMyHA.MySQL.GTID (GtidSet)
import PureMyHA.Types

spec :: Spec
spec = do
  describe "parseHostPort" $ do
    it "host only defaults to port 3306" $
      parseHostPort "db1" `shouldBe` ("db1", 3306)

    it "host:port extracts port correctly" $
      parseHostPort "db1:3307" `shouldBe` ("db1", 3307)

    it "host with invalid port treats whole spec as host with default port" $
      parseHostPort "db1:abc" `shouldBe` ("db1:abc", 3306)

    it "IPv4 address with port" $
      parseHostPort "192.168.1.1:3307" `shouldBe` ("192.168.1.1", 3307)

  describe "selectDonorAuto" $ do
    let replica2 = healthyReplica
          { nsProbeResult = ProbeSuccess fixedTime
              (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-50"))
              (unsafeParseGtidSet "uuid1:1-50")
          }
        replica3 = mkNodeState (NodeId "db3" 3306) Replica
            (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100"))
            Healthy
          `withGtid` unsafeParseGtidSet "uuid1:1-100"

    it "auto-selects the replica with the highest GTID transaction count" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, replica2)
            , (NodeId "db3" 3306, replica3)
            ]
      selectDonorAuto nodes (NodeId "db1" 3306) `shouldBe` Right (NodeId "db3" 3306)

    it "excludes the recipient node from donor candidates" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, replica2)
            , (NodeId "db3" 3306, replica3)
            ]
      -- When db3 is the recipient, db2 (lower GTID) becomes the only option
      selectDonorAuto nodes (NodeId "db3" 3306) `shouldBe` Right (NodeId "db2" 3306)

    it "returns Left when no reachable replica exists other than recipient" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, replica2)
            ]
      -- db2 is the recipient: no other replica available
      selectDonorAuto nodes (NodeId "db2" 3306) `shouldSatisfy` isLeft

    it "excludes unreachable replicas from donor selection" $ do
      let unreachableDb3 = unreachableNode (NodeId "db3" 3306)
          nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, replica2)
            , (NodeId "db3" 3306, unreachableDb3)
            ]
      -- db2 is recipient; db3 is unreachable → no viable donor
      selectDonorAuto nodes (NodeId "db2" 3306) `shouldSatisfy` isLeft

    it "excludes the source node from donor candidates" $ do
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db2" 3306, replica2)
            ]
      -- db2 is recipient; db1 is source, not eligible as donor
      selectDonorAuto nodes (NodeId "db2" 3306) `shouldSatisfy` isLeft

-- | Helper to set prGtidExecuted on a NodeState
withGtid :: NodeState -> GtidSet -> NodeState
withGtid ns g = ns { nsProbeResult = setGtid (nsProbeResult ns) }
  where
    setGtid (ProbeSuccess t rs _) = ProbeSuccess t rs g
    setGtid p                     = p
