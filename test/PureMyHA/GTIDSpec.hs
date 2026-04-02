module PureMyHA.GTIDSpec (spec) where

import Data.Aeson (encode, eitherDecode)
import Test.Hspec
import Test.QuickCheck
import PureMyHA.MySQL.GTID

spec :: Spec
spec = do
  describe "isEmptyGtidSet" $ do
    it "returns True for empty GtidSet" $
      isEmptyGtidSet emptyGtidSet `shouldBe` True

    it "returns True for parsed empty string" $
      fmap isEmptyGtidSet (parseGtidSet "") `shouldBe` Right True

    it "returns True for parsed whitespace" $
      fmap isEmptyGtidSet (parseGtidSet "   ") `shouldBe` Right True

    it "returns False for non-empty GTID set" $
      fmap isEmptyGtidSet (parseGtidSet "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5") `shouldBe` Right False

  describe "parseGtidIntervals" $ do
    it "returns empty list for empty input" $
      parseGtidIntervals "" `shouldBe` Right []

    it "parses a single interval" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562") Nothing
            [GtidInterval (TransactionId 1) (TransactionId 5)]
        ]

    it "parses a single transaction number" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562") Nothing
            [GtidInterval (TransactionId 1) (TransactionId 1)]
        ]

    it "parses multiple intervals for same UUID" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5:7-10"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562") Nothing
            [GtidInterval (TransactionId 1) (TransactionId 5), GtidInterval (TransactionId 7) (TransactionId 10)]
        ]

    it "parses multiple UUID entries" $ do
      let gtid = "uuid1:1-5,uuid2:1-3"
          result = parseGtidIntervals gtid
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5)]
        , GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)]
        ]

    it "returns Left for invalid format" $
      parseGtidIntervals ":invalid" `shouldSatisfy` isLeft

  describe "parseGtidSet (tagged)" $ do
    it "parses a tagged GTID entry" $ do
      let result = parseGtidSet "3e11fa47-71ca-11e1-9e33-c80aa9429562:my_tag:1-5"
      result `shouldBe` Right (GtidSet
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562") (Just (GtidTag "my_tag"))
            [GtidInterval (TransactionId 1) (TransactionId 5)]
        ])

    it "parses tagged and untagged entries together" $ do
      let result = parseGtidSet "uuid1:tag1:1-5,uuid2:1-3"
      result `shouldBe` Right (GtidSet
        [ GtidEntry (GtidUUID "uuid1") (Just (GtidTag "tag1"))
            [GtidInterval (TransactionId 1) (TransactionId 5)]
        , GtidEntry (GtidUUID "uuid2") Nothing
            [GtidInterval (TransactionId 1) (TransactionId 3)]
        ])

    it "parses tagged entry with single transaction" $ do
      let result = parseGtidSet "uuid1:_tag:42"
      result `shouldBe` Right (GtidSet
        [ GtidEntry (GtidUUID "uuid1") (Just (GtidTag "_tag"))
            [GtidInterval (TransactionId 42) (TransactionId 42)]
        ])

  describe "mkGtidTag" $ do
    it "accepts valid tag" $
      mkGtidTag "my_tag_1" `shouldBe` Right (GtidTag "my_tag_1")

    it "accepts tag starting with underscore" $
      mkGtidTag "_tag" `shouldBe` Right (GtidTag "_tag")

    it "rejects empty tag" $
      mkGtidTag "" `shouldSatisfy` isLeft

    it "rejects tag starting with digit" $
      mkGtidTag "1tag" `shouldSatisfy` isLeft

    it "rejects tag with special characters" $
      mkGtidTag "tag-name" `shouldSatisfy` isLeft

    it "rejects tag longer than 32 chars" $
      mkGtidTag "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" `shouldSatisfy` isLeft

  describe "gtidTransactionCount" $ do
    it "returns 0 for empty GtidSet" $
      gtidTransactionCount emptyGtidSet `shouldBe` 0

    it "returns 1 for single transaction" $
      gtidTransactionCount (GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 5) (TransactionId 5)]]) `shouldBe` 1

    it "returns 5 for range 1-5" $
      gtidTransactionCount (GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5)]]) `shouldBe` 5

    it "sums multiple intervals for same UUID" $
      gtidTransactionCount (GtidSet [GtidEntry (GtidUUID "uuid1") Nothing
        [GtidInterval (TransactionId 1) (TransactionId 5), GtidInterval (TransactionId 7) (TransactionId 10)]]) `shouldBe` 9

    it "sums across multiple UUIDs" $
      gtidTransactionCount (GtidSet
        [ GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 100)]
        , GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)]
        ]) `shouldBe` 103

  describe "mkGtidInterval" $ do
    it "returns Right for valid start <= end" $
      mkGtidInterval 1 5
        `shouldBe` Right (GtidInterval (TransactionId 1) (TransactionId 5))

    it "returns Right for equal start and end (point transaction)" $
      mkGtidInterval 3 3
        `shouldBe` Right (GtidInterval (TransactionId 3) (TransactionId 3))

    it "returns Left for start > end" $
      mkGtidInterval 5 1 `shouldSatisfy` isLeft

  describe "mkSingleGtid" $ do
    it "creates a GtidEntry with single point interval" $
      mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 5)
        `shouldBe` GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 5) (TransactionId 5)]

    it "creates a tagged GtidEntry" $
      mkSingleGtid (GtidUUID "uuid1") (Just (GtidTag "tag1")) (TransactionId 5)
        `shouldBe` GtidEntry (GtidUUID "uuid1") (Just (GtidTag "tag1")) [GtidInterval (TransactionId 5) (TransactionId 5)]

  describe "renderGtidEntry" $ do
    it "renders a single interval" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5)])
        `shouldBe` "uuid1:1-5"

    it "renders a point transaction as a single number" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 3) (TransactionId 3)])
        `shouldBe` "uuid1:3"

    it "renders multiple intervals" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5), GtidInterval (TransactionId 7) (TransactionId 10)])
        `shouldBe` "uuid1:1-5:7-10"

    it "renders a tagged entry" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") (Just (GtidTag "my_tag")) [GtidInterval (TransactionId 1) (TransactionId 5)])
        `shouldBe` "uuid1:my_tag:1-5"

  describe "renderGtidSet" $ do
    it "renders an empty GtidSet as empty string" $
      renderGtidSet emptyGtidSet `shouldBe` ""

    it "renders multiple entries" $
      renderGtidSet (GtidSet
        [ GtidEntry (GtidUUID "u1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5)]
        , GtidEntry (GtidUUID "u2") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)]
        ])
        `shouldBe` "u1:1-5,u2:1-3"

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

    it "preserves tag during expansion" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") (Just (GtidTag "t")) [GtidInterval (TransactionId 1) (TransactionId 2)])
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") (Just (GtidTag "t")) (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") (Just (GtidTag "t")) (TransactionId 2)
                    ]

  describe "JSON roundtrip" $ do
    it "GtidSet ToJSON/FromJSON roundtrips" $ do
      let gs = GtidSet
            [ GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 5)]
            , GtidEntry (GtidUUID "uuid2") (Just (GtidTag "tag1")) [GtidInterval (TransactionId 1) (TransactionId 3)]
            ]
      -- JSON encodes to text, decodes back
      (eitherDecode . encode) gs `shouldBe` Right gs

  describe "roundtrip" $ do
    it "parse . renderGtidSet == Right for arbitrary entries" $
      property $ \entries ->
        parseGtidSet (renderGtidSet (GtidSet entries)) === Right (GtidSet entries)

instance Arbitrary TransactionId where
  arbitrary = TransactionId . getPositive <$> arbitrary

instance Arbitrary GtidUUID where
  arbitrary = GtidUUID <$> elements ["uuid1", "uuid2", "3e11fa47-71ca-11e1-9e33-c80aa9429562"]

instance Arbitrary GtidTag where
  arbitrary = GtidTag <$> elements ["tag1", "my_tag", "_test"]

instance Arbitrary GtidInterval where
  arbitrary = do
    s <- arbitrary
    e <- TransactionId . (getTransactionId s +) . getNonNegative <$> arbitrary
    pure (GtidInterval s e)

instance Arbitrary GtidEntry where
  arbitrary = GtidEntry <$> arbitrary <*> arbitrary <*> listOf1 arbitrary

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
