module PureMyHA.ErrantGtidSpec (spec) where

import Test.Hspec
import PureMyHA.Failover.ErrantGtid (collectErrantGtids)
import PureMyHA.MySQL.GTID

spec :: Spec
spec = do
  describe "expandGtidEntry" $ do
    it "expands a single GTID" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 5) (TransactionId 5)])
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 5)]

    it "expands a range interval" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)])
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "expands multiple intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 2), GtidInterval (TransactionId 5) (TransactionId 6)])
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 5)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 6)
                    ]

    it "returns empty list for no intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [])
        `shouldBe` []

  describe "collectErrantGtids" $ do
    it "returns empty list for empty input" $
      collectErrantGtids [] `shouldBe` []

    it "collects GTIDs from a single entry" $
      collectErrantGtids [GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]]
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)]

    it "expands range across single replica" $
      collectErrantGtids [GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)]]]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "deduplicates identical GTIDs from two replicas" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        ]
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)]

    it "collects GTIDs from multiple UUIDs" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , GtidSet [GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 2) (TransactionId 2)]]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid2") Nothing (TransactionId 2)
                    ]

    it "deduplicates partial overlap across replicas" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 2)]]
        , GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 2) (TransactionId 3)]]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "handles one replica with multiple UUIDs" $
      collectErrantGtids
        [ GtidSet
          [ GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]
          , GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]
          ]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid2") Nothing (TransactionId 1)
                    ]
