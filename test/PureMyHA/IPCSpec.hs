module PureMyHA.IPCSpec (spec) where

import Data.Aeson (encode, decode)
import qualified Data.ByteString.Lazy.Char8 as BLC
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

    it "round-trips Lagging" $
      roundTripHealth (Lagging 42) `shouldBe` Just (Lagging 42)

    it "round-trips Lagging with large lag value" $
      roundTripHealth (Lagging 3600) `shouldBe` Just (Lagging 3600)

  describe "Request FromJSON error paths" $ do
    it "rejects unknown request type" $
      (decode (BLC.pack "{\"type\":\"foobar\"}") :: Maybe Request) `shouldBe` Nothing

    it "rejects missing type field" $
      (decode (BLC.pack "{\"cluster\":\"x\"}") :: Maybe Request) `shouldBe` Nothing

    it "round-trips ReqDemote" $
      roundTrip (ReqDemote (Just "main") "db2" "db1")
        `shouldBe` Just (ReqDemote (Just "main") "db2" "db1")

    it "round-trips ReqDiscovery" $
      roundTrip (ReqDiscovery (Just "main")) `shouldBe` Just (ReqDiscovery (Just "main"))

    it "round-trips ReqSetLogLevel" $
      roundTrip (ReqSetLogLevel "debug") `shouldBe` Just (ReqSetLogLevel "debug")

    it "round-trips ReqUnfence" $
      roundTrip (ReqUnfence (Just "main") "db2")
        `shouldBe` Just (ReqUnfence (Just "main") "db2")

    it "round-trips ReqUnfence without cluster" $
      roundTrip (ReqUnfence Nothing "db2")
        `shouldBe` Just (ReqUnfence Nothing "db2")

    it "round-trips ReqClone with explicit donor" $
      roundTrip (ReqClone (Just "main") "db3" (Just "db2"))
        `shouldBe` Just (ReqClone (Just "main") "db3" (Just "db2"))

    it "round-trips ReqClone without donor (auto-select)" $
      roundTrip (ReqClone (Just "main") "db3" Nothing)
        `shouldBe` Just (ReqClone (Just "main") "db3" Nothing)

    it "round-trips ReqClone without cluster" $
      roundTrip (ReqClone Nothing "db3" (Just "db2"))
        `shouldBe` Just (ReqClone Nothing "db3" (Just "db2"))

  describe "Response FromJSON error paths" $ do
    it "rejects unknown response type" $
      (decode (BLC.pack "{\"type\":\"foobar\",\"data\":[]}") :: Maybe Response) `shouldBe` Nothing

    it "round-trips RespTopology" $ do
      let view = ClusterTopologyView "test" [NodeStateView "db1" 3306 True Healthy (Just 0) "" Nothing False False]
      roundTripResp (RespTopology [view]) `shouldBe` Just (RespTopology [view])

  describe "NodeStateView fenced field" $ do
    it "round-trips NodeStateView with fenced=True" $ do
      let view = ClusterTopologyView "test" [NodeStateView "db1" 3306 True Healthy (Just 0) "" Nothing False True]
      roundTripResp (RespTopology [view]) `shouldBe` Just (RespTopology [view])

    it "defaults fenced to False when field is absent" $ do
      let json = BLC.pack
            "{\"type\":\"topology\",\"data\":[{\"clusterName\":\"test\",\"nodes\":[{\"host\":\"db1\",\"port\":3306,\"isSource\":true,\"health\":\"Healthy\",\"lagSeconds\":0,\"errantGtids\":\"\",\"connectError\":null,\"paused\":false}]}]}"
      let expected = RespTopology [ClusterTopologyView "test"
                       [NodeStateView "db1" 3306 True Healthy (Just 0) "" Nothing False False]]
      (decode json :: Maybe Response) `shouldBe` Just expected

  describe "NodeHealth FromJSON edge cases" $ do
    it "round-trips UnreachableSource" $
      roundTripHealth UnreachableSource `shouldBe` Just UnreachableSource

    it "round-trips DeadSourceAndAllReplicas" $
      roundTripHealth DeadSourceAndAllReplicas `shouldBe` Just DeadSourceAndAllReplicas

    it "round-trips SplitBrainSuspected" $
      roundTripHealth SplitBrainSuspected `shouldBe` Just SplitBrainSuspected

    it "rejects invalid NodeHealth (Number)" $
      (decode (BLC.pack "42") :: Maybe NodeHealth) `shouldBe` Nothing

  describe "OperationResult FromJSON error path" $
    it "rejects object with neither success nor failure" $
      (decode (BLC.pack "{\"other\":\"x\"}") :: Maybe OperationResult) `shouldBe` Nothing

roundTrip :: Request -> Maybe Request
roundTrip = decode . encode

roundTripResp :: Response -> Maybe Response
roundTripResp = decode . encode

roundTripHealth :: NodeHealth -> Maybe NodeHealth
roundTripHealth = decode . encode
