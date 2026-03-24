module PureMyHA.ErrantGtidSpec (spec) where

import Test.Hspec
import PureMyHA.Failover.ErrantGtid (expandGtidEntry, collectErrantGtids)
import PureMyHA.MySQL.GTID (GtidEntry (..), GtidInterval (..), GtidUUID (..), TransactionId (..))

spec :: Spec
spec = do
  describe "expandGtidEntry" $ do
    it "expands a single GTID" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 5) (TransactionId 5)])
        `shouldBe` ["uuid1:5"]

    it "expands a range interval" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 3)])
        `shouldBe` ["uuid1:1", "uuid1:2", "uuid1:3"]

    it "expands multiple intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 2), GtidInterval (TransactionId 5) (TransactionId 6)])
        `shouldBe` ["uuid1:1", "uuid1:2", "uuid1:5", "uuid1:6"]

    it "returns empty list for no intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") [])
        `shouldBe` []

  describe "collectErrantGtids" $ do
    it "returns empty list for empty input" $
      collectErrantGtids [] `shouldBe` []

    it "collects GTIDs from a single entry" $
      collectErrantGtids [[GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 1)]]]
        `shouldBe` ["uuid1:1"]

    it "expands range across single replica" $
      collectErrantGtids [[GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 3)]]]
        `shouldBe` ["uuid1:1", "uuid1:2", "uuid1:3"]

    it "deduplicates identical GTIDs from two replicas" $
      collectErrantGtids
        [ [GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , [GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 1)]]
        ]
        `shouldBe` ["uuid1:1"]

    it "collects GTIDs from multiple UUIDs" $
      collectErrantGtids
        [ [GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , [GtidEntry (GtidUUID "uuid2") [GtidInterval (TransactionId 2) (TransactionId 2)]]
        ]
        `shouldBe` ["uuid1:1", "uuid2:2"]

    it "deduplicates partial overlap across replicas" $
      collectErrantGtids
        [ [GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 2)]]
        , [GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 2) (TransactionId 3)]]
        ]
        `shouldBe` ["uuid1:1", "uuid1:2", "uuid1:3"]

    it "handles one replica with multiple UUIDs" $
      collectErrantGtids
        [ [ GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 1)]
          , GtidEntry (GtidUUID "uuid2") [GtidInterval (TransactionId 1) (TransactionId 1)]
          ]
        ]
        `shouldBe` ["uuid1:1", "uuid2:1"]
