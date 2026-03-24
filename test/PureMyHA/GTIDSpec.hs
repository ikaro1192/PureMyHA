module PureMyHA.GTIDSpec (spec) where

import Test.Hspec
import Test.QuickCheck
import PureMyHA.MySQL.GTID

spec :: Spec
spec = do
  describe "isEmptyGtidSet" $ do
    it "returns True for empty string" $
      isEmptyGtidSet "" `shouldBe` True

    it "returns True for whitespace" $
      isEmptyGtidSet "   " `shouldBe` True

    it "returns False for non-empty GTID set" $
      isEmptyGtidSet "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5" `shouldBe` False

  describe "parseGtidIntervals" $ do
    it "returns empty list for empty input" $
      parseGtidIntervals "" `shouldBe` Right []

    it "parses a single interval" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562")
            [GtidInterval (TransactionId 1) (TransactionId 5)]
        ]

    it "parses a single transaction number" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562")
            [GtidInterval (TransactionId 1) (TransactionId 1)]
        ]

    it "parses multiple intervals for same UUID" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5:7-10"
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "3e11fa47-71ca-11e1-9e33-c80aa9429562")
            [GtidInterval (TransactionId 1) (TransactionId 5), GtidInterval (TransactionId 7) (TransactionId 10)]
        ]

    it "parses multiple UUID entries" $ do
      let gtid = "uuid1:1-5,uuid2:1-3"
          result = parseGtidIntervals gtid
      result `shouldBe` Right
        [ GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 5)]
        , GtidEntry (GtidUUID "uuid2") [GtidInterval (TransactionId 1) (TransactionId 3)]
        ]

    it "returns Left for invalid format" $
      parseGtidIntervals ":invalid" `shouldSatisfy` isLeft

  describe "gtidTransactionCount" $ do
    it "returns 0 for empty string" $
      gtidTransactionCount "" `shouldBe` 0

    it "returns 0 for invalid format" $
      gtidTransactionCount ":invalid" `shouldBe` 0

    it "returns 1 for single transaction" $
      gtidTransactionCount "uuid1:5" `shouldBe` 1

    it "returns 5 for range 1-5" $
      gtidTransactionCount "uuid1:1-5" `shouldBe` 5

    it "returns 5 for non-1-based range 3-7" $
      gtidTransactionCount "uuid1:3-7" `shouldBe` 5

    it "sums multiple intervals for same UUID" $
      gtidTransactionCount "uuid1:1-5:7-10" `shouldBe` 9

    it "sums across multiple UUIDs" $
      gtidTransactionCount "uuid1:1-100,uuid2:1-3" `shouldBe` 103

    it "handles fixture GTID from CandidateSpec" $
      gtidTransactionCount "uuid1:1-1,uuid2:1-200,uuid3:1-50" `shouldBe` 251

  describe "mkGtidInterval" $ do
    it "returns Right for valid start <= end" $
      mkGtidInterval 1 5
        `shouldBe` Right (GtidInterval (TransactionId 1) (TransactionId 5))

    it "returns Right for equal start and end (point transaction)" $
      mkGtidInterval 3 3
        `shouldBe` Right (GtidInterval (TransactionId 3) (TransactionId 3))

    it "returns Left for start > end" $
      mkGtidInterval 5 1 `shouldSatisfy` isLeft

  describe "renderGtidEntry" $ do
    it "renders a single interval" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 5)])
        `shouldBe` "uuid1:1-5"

    it "renders a point transaction as a single number" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 3) (TransactionId 3)])
        `shouldBe` "uuid1:3"

    it "renders multiple intervals" $
      renderGtidEntry (GtidEntry (GtidUUID "uuid1") [GtidInterval (TransactionId 1) (TransactionId 5), GtidInterval (TransactionId 7) (TransactionId 10)])
        `shouldBe` "uuid1:1-5:7-10"

  describe "renderGtidSet" $ do
    it "renders an empty list as empty string" $
      renderGtidSet [] `shouldBe` ""

    it "renders multiple entries" $
      renderGtidSet
        [ GtidEntry (GtidUUID "u1") [GtidInterval (TransactionId 1) (TransactionId 5)]
        , GtidEntry (GtidUUID "u2") [GtidInterval (TransactionId 1) (TransactionId 3)]
        ]
        `shouldBe` "u1:1-5,u2:1-3"

  describe "roundtrip" $ do
    it "parse . renderGtidSet == Right for arbitrary entries" $
      property $ \entries ->
        parseGtidIntervals (renderGtidSet entries) === Right entries

instance Arbitrary TransactionId where
  arbitrary = TransactionId . getPositive <$> arbitrary

instance Arbitrary GtidUUID where
  arbitrary = GtidUUID <$> elements ["uuid1", "uuid2", "3e11fa47-71ca-11e1-9e33-c80aa9429562"]

instance Arbitrary GtidInterval where
  arbitrary = do
    s <- arbitrary
    e <- TransactionId . (getTransactionId s +) . getNonNegative <$> arbitrary
    pure (GtidInterval s e)

instance Arbitrary GtidEntry where
  arbitrary = GtidEntry <$> arbitrary <*> listOf1 arbitrary

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
