module PureMyHA.IPCSpec (spec) where

import Data.Aeson (encode, decode, eitherDecode)
import Data.Maybe (isJust)
import Test.Hspec
import PureMyHA.IPC.Protocol
import PureMyHA.Types

spec :: Spec
spec = do
  describe "Request JSON round-trip" $ do
    it "round-trips ReqStatus" $
      roundTrip (ReqStatus Nothing) `shouldBe` Just (ReqStatus Nothing)

    it "round-trips ReqStatus with cluster" $
      roundTrip (ReqStatus (Just "main")) `shouldBe` Just (ReqStatus (Just "main"))

    it "round-trips ReqTopology" $
      roundTrip (ReqTopology (Just "main")) `shouldBe` Just (ReqTopology (Just "main"))

    it "round-trips ReqSwitchover with dryRun=false" $
      roundTrip (ReqSwitchover (Just "main") (Just "db2") False)
        `shouldBe` Just (ReqSwitchover (Just "main") (Just "db2") False)

    it "round-trips ReqSwitchover with dryRun=true" $
      roundTrip (ReqSwitchover (Just "main") (Just "db2") True)
        `shouldBe` Just (ReqSwitchover (Just "main") (Just "db2") True)

    it "round-trips ReqAckRecovery" $
      roundTrip (ReqAckRecovery Nothing) `shouldBe` Just (ReqAckRecovery Nothing)

    it "round-trips ReqErrantGtid" $
      roundTrip (ReqErrantGtid (Just "main")) `shouldBe` Just (ReqErrantGtid (Just "main"))

    it "round-trips ReqFixErrantGtid" $
      roundTrip (ReqFixErrantGtid Nothing) `shouldBe` Just (ReqFixErrantGtid Nothing)

    it "round-trips ReqPauseReplica" $
      roundTrip (ReqPauseReplica (Just "main") "db2") `shouldBe` Just (ReqPauseReplica (Just "main") "db2")

    it "round-trips ReqResumeReplica" $
      roundTrip (ReqResumeReplica Nothing "db3") `shouldBe` Just (ReqResumeReplica Nothing "db3")

    it "round-trips ReqPauseFailover" $
      roundTrip (ReqPauseFailover (Just "main")) `shouldBe` Just (ReqPauseFailover (Just "main"))

    it "round-trips ReqResumeFailover" $
      roundTrip (ReqResumeFailover Nothing) `shouldBe` Just (ReqResumeFailover Nothing)

  describe "Response JSON round-trip" $ do
    it "round-trips RespError" $
      roundTripResp (RespError "something went wrong")
        `shouldBe` Just (RespError "something went wrong")

    it "round-trips RespOperation success" $
      roundTripResp (RespOperation (OperationSuccess "done"))
        `shouldBe` Just (RespOperation (OperationSuccess "done"))

    it "round-trips RespOperation failure" $
      roundTripResp (RespOperation (OperationFailure "error"))
        `shouldBe` Just (RespOperation (OperationFailure "error"))

    it "round-trips RespErrantGtids" $ do
      let info = ErrantGtidInfo (NodeId "db3" 3306) "uuid3:1"
      roundTripResp (RespErrantGtids [info])
        `shouldBe` Just (RespErrantGtids [info])

    it "round-trips RespStatus empty" $
      roundTripResp (RespStatus []) `shouldBe` Just (RespStatus [])

  describe "NodeHealth JSON" $ do
    it "round-trips Healthy" $
      roundTripHealth Healthy `shouldBe` Just Healthy

    it "round-trips DeadSource" $
      roundTripHealth DeadSource `shouldBe` Just DeadSource

    it "round-trips NeedsAttention" $
      roundTripHealth (NeedsAttention "test msg")
        `shouldBe` Just (NeedsAttention "test msg")

roundTrip :: Request -> Maybe Request
roundTrip = decode . encode

roundTripResp :: Response -> Maybe Response
roundTripResp = decode . encode

roundTripHealth :: NodeHealth -> Maybe NodeHealth
roundTripHealth = decode . encode
