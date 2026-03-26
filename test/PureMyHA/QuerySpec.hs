module PureMyHA.QuerySpec (spec) where

import Test.Hspec
import PureMyHA.Config (TLSConfig (..), TLSMode (..))
import PureMyHA.MySQL.Query (needsPublicKeyRetrieval, ProcessInfo (..), isUserProcess)

spec :: Spec
spec = do
  describe "isUserProcess" $ do
    it "excludes Binlog Dump GTID threads" $
      isUserProcess (ProcessInfo 1 "repl" "Binlog Dump GTID") `shouldBe` False

    it "excludes Binlog Dump threads" $
      isUserProcess (ProcessInfo 2 "repl" "Binlog Dump") `shouldBe` False

    it "excludes Daemon threads" $
      isUserProcess (ProcessInfo 3 "event_scheduler" "Daemon") `shouldBe` False

    it "excludes system user" $
      isUserProcess (ProcessInfo 4 "system user" "Connect") `shouldBe` False

    it "includes normal user Query connections" $
      isUserProcess (ProcessInfo 5 "app" "Query") `shouldBe` True

    it "includes Sleep connections from application pools" $
      isUserProcess (ProcessInfo 6 "app" "Sleep") `shouldBe` True

    it "piId accessor returns the process id" $
      piId (ProcessInfo 42 "app" "Query") `shouldBe` 42

  describe "needsPublicKeyRetrieval" $ do
    it "returns True when TLS is not configured" $
      needsPublicKeyRetrieval Nothing `shouldBe` True

    it "returns True when TLS mode is Disabled" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSDisabled }) `shouldBe` True

    it "returns False when TLS mode is SkipVerify" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSSkipVerify }) `shouldBe` False

    it "returns False when TLS mode is VerifyCA" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSVerifyCA }) `shouldBe` False

    it "returns False when TLS mode is VerifyFull" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSVerifyFull }) `shouldBe` False

  where
    tls = TLSConfig TLSDisabled Nothing Nothing Nothing Nothing
