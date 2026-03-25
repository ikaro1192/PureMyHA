module PureMyHA.QuerySpec (spec) where

import Test.Hspec
import PureMyHA.Config (TLSConfig (..), TLSMode (..))
import PureMyHA.MySQL.Query (needsPublicKeyRetrieval)

spec :: Spec
spec = describe "needsPublicKeyRetrieval" $ do
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
