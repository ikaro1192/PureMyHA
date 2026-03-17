module PureMyHA.GTIDSpec (spec) where

import Test.Hspec
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
        [ GtidEntry "3e11fa47-71ca-11e1-9e33-c80aa9429562"
            [GtidInterval 1 5]
        ]

    it "parses a single transaction number" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1"
      result `shouldBe` Right
        [ GtidEntry "3e11fa47-71ca-11e1-9e33-c80aa9429562"
            [GtidInterval 1 1]
        ]

    it "parses multiple intervals for same UUID" $ do
      let result = parseGtidIntervals "3e11fa47-71ca-11e1-9e33-c80aa9429562:1-5:7-10"
      result `shouldBe` Right
        [ GtidEntry "3e11fa47-71ca-11e1-9e33-c80aa9429562"
            [GtidInterval 1 5, GtidInterval 7 10]
        ]

    it "parses multiple UUID entries" $ do
      let gtid = "uuid1:1-5,uuid2:1-3"
          result = parseGtidIntervals gtid
      result `shouldBe` Right
        [ GtidEntry "uuid1" [GtidInterval 1 5]
        , GtidEntry "uuid2" [GtidInterval 1 3]
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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
