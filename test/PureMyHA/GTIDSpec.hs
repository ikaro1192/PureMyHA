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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
