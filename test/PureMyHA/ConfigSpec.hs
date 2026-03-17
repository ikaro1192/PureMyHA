module PureMyHA.ConfigSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy.Char8 as BLC
import Test.Hspec
import PureMyHA.Config

spec :: Spec
spec = do
  describe "parseDuration" $ do
    it "parses integer seconds" $
      parseDuration "3s" `shouldBe` Right 3

    it "parses large integer seconds" $
      parseDuration "3600s" `shouldBe` Right 3600

    it "parses fractional seconds" $
      parseDuration "0.5s" `shouldBe` Right 0.5

    it "rejects missing suffix" $
      parseDuration "30" `shouldSatisfy` isLeft

    it "rejects non-numeric prefix" $
      parseDuration "xs" `shouldSatisfy` isLeft

    it "rejects empty string" $
      parseDuration "" `shouldSatisfy` isLeft

  describe "MonitoringConfig discovery_interval" $ do
    it "defaults to 300s when field is absent" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 300
        Left err -> expectationFailure err

    it "parses explicit discovery_interval" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\",\"discovery_interval\":\"60s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 60
        Left err -> expectationFailure err

    it "parses discovery_interval of 0s (disabled)" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\",\"discovery_interval\":\"0s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 0
        Left err -> expectationFailure err

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False
