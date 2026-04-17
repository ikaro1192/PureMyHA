module PureMyHA.SqlEscapeSpec (spec) where

import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import PureMyHA.MySQL.SqlEscape
  ( escapeSqlString
  , quoteSqlString
  , validateIdentifierLike
  , validateGtidRendering
  )

spec :: Spec
spec = do
  describe "escapeSqlString" $ do
    it "doubles a single quote" $
      escapeSqlString "can't" `shouldBe` "can''t"

    it "doubles a backslash" $
      escapeSqlString "a\\b" `shouldBe` "a\\\\b"

    it "leaves safe text untouched" $
      escapeSqlString "hello world" `shouldBe` "hello world"

    it "escapes multiple quotes" $
      escapeSqlString "a'b'c" `shouldBe` "a''b''c"

    it "escapes an empty string to an empty string" $
      escapeSqlString "" `shouldBe` ""

    it "property: every run of quotes has even length" $
      property $ \s ->
        let escaped = escapeSqlString (T.pack s)
            runs = T.split (/= '\'') escaped
        in all ((== 0) . (`mod` 2) . T.length) runs

    it "property: every run of backslashes has even length" $
      property $ \s ->
        let escaped = escapeSqlString (T.pack s)
            runs = T.split (/= '\\') escaped
        in all ((== 0) . (`mod` 2) . T.length) runs

  describe "quoteSqlString" $ do
    it "wraps a plain string in single quotes" $
      quoteSqlString "repl" `shouldBe` "'repl'"

    it "wraps and escapes a single quote" $
      quoteSqlString "p'ass" `shouldBe` "'p''ass'"

    it "wraps an empty string as empty quotes" $
      quoteSqlString "" `shouldBe` "''"

    it "property: starts and ends with a single quote" $
      property $ \s ->
        let q = quoteSqlString (T.pack s)
        in T.head q == '\'' && T.last q == '\''

  describe "validateIdentifierLike" $ do
    it "accepts a DNS hostname" $
      validateIdentifierLike "db1.example.com" `shouldSatisfy` isRight

    it "accepts an IPv4 literal" $
      validateIdentifierLike "10.0.0.1" `shouldSatisfy` isRight

    it "accepts a typical MySQL user name" $
      validateIdentifierLike "puremyha" `shouldSatisfy` isRight

    it "accepts underscore and hyphen" $
      validateIdentifierLike "user_1-a" `shouldSatisfy` isRight

    it "rejects empty input" $
      validateIdentifierLike "" `shouldSatisfy` isLeft

    it "rejects a single quote" $
      validateIdentifierLike "db'; DROP" `shouldSatisfy` isLeft

    it "rejects whitespace" $
      validateIdentifierLike "a b" `shouldSatisfy` isLeft

    it "rejects a semicolon" $
      validateIdentifierLike "a;b" `shouldSatisfy` isLeft

    it "rejects a parenthesis" $
      validateIdentifierLike "a)b" `shouldSatisfy` isLeft

    it "returns the input unchanged on success" $
      validateIdentifierLike "db1" `shouldBe` Right "db1"

  describe "validateGtidRendering" $ do
    it "accepts a well-formed GTID set rendering" $
      validateGtidRendering "aaaa-bbbb:1-5,cccc:7" `shouldSatisfy` isRight

    it "accepts a tagged GTID rendering" $
      validateGtidRendering "3e11fa47-71ca-11e1-9e33-c80aa9429562:myTag:1-5" `shouldSatisfy` isRight

    it "accepts the empty rendering" $
      validateGtidRendering "" `shouldSatisfy` isRight

    it "rejects an input containing a single quote" $
      validateGtidRendering "abc'; DROP" `shouldSatisfy` isLeft

    it "rejects an input containing whitespace" $
      validateGtidRendering "abc def" `shouldSatisfy` isLeft

    it "rejects an input containing a semicolon" $
      validateGtidRendering "abc;def" `shouldSatisfy` isLeft

    it "returns the input unchanged on success" $
      validateGtidRendering "aaaa:1" `shouldBe` Right "aaaa:1"
