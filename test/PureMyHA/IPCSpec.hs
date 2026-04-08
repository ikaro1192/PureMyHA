module PureMyHA.IPCSpec (spec) where

import Control.Concurrent.Async (async, wait)
import Data.Aeson (encode, decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BLC
import Network.Socket (socketPair, Family (..), SocketType (..), close)
import qualified Network.Socket.ByteString as NSB
import Test.Hspec
import PureMyHA.IPC.Protocol
import PureMyHA.IPC.Socket (recvLine, maxLineLength)
import Data.Text (Text)
import PureMyHA.MySQL.GTID (GtidSet, emptyGtidSet, parseGtidSet)
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
      roundTrip (ReqSwitchover (Just "main") (ExplicitTarget "db2" Nothing) Live)
        `shouldBe` Just (ReqSwitchover (Just "main") (ExplicitTarget "db2" Nothing) Live)

    it "round-trips ReqSwitchover with dryRun=true" $
      roundTrip (ReqSwitchover (Just "main") (ExplicitTarget "db2" Nothing) DryRun)
        `shouldBe` Just (ReqSwitchover (Just "main") (ExplicitTarget "db2" Nothing) DryRun)

    it "round-trips ReqSwitchover with drain-timeout" $
      roundTrip (ReqSwitchover (Just "main") (ExplicitTarget "db2" (Just 30)) Live)
        `shouldBe` Just (ReqSwitchover (Just "main") (ExplicitTarget "db2" (Just 30)) Live)

    it "round-trips ReqSwitchover with auto-select target" $
      roundTrip (ReqSwitchover (Just "main") AutoSelectTarget Live)
        `shouldBe` Just (ReqSwitchover (Just "main") AutoSelectTarget Live)

    it "round-trips ReqAckRecovery" $
      roundTrip (ReqAckRecovery Nothing) `shouldBe` Just (ReqAckRecovery Nothing)

    it "round-trips ReqErrantGtid" $
      roundTrip (ReqErrantGtid (Just "main")) `shouldBe` Just (ReqErrantGtid (Just "main"))

    it "round-trips ReqFixErrantGtid" $
      roundTrip (ReqFixErrantGtid Nothing Live) `shouldBe` Just (ReqFixErrantGtid Nothing Live)

    it "round-trips ReqPauseReplica" $
      roundTrip (ReqPauseReplica (Just "main") "db2") `shouldBe` Just (ReqPauseReplica (Just "main") "db2")

    it "round-trips ReqResumeReplica" $
      roundTrip (ReqResumeReplica Nothing "db3") `shouldBe` Just (ReqResumeReplica Nothing "db3")

    it "round-trips ReqPauseFailover" $
      roundTrip (ReqPauseFailover (Just "main")) `shouldBe` Just (ReqPauseFailover (Just "main"))

    it "round-trips ReqResumeFailover" $
      roundTrip (ReqResumeFailover Nothing) `shouldBe` Just (ReqResumeFailover Nothing)

  describe "ReqSwitchover field accessors" $ do
    let req = ReqSwitchover (Just "main") (ExplicitTarget "db2" (Just 30)) DryRun
    it "reqCluster returns the cluster" $
      reqCluster req `shouldBe` Just "main"
    it "reqSwitchoverTarget returns the explicit target" $
      reqSwitchoverTarget req `shouldBe` ExplicitTarget "db2" (Just 30)
    it "reqDryRun returns the dry-run flag" $
      reqDryRun req `shouldBe` DryRun

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
      let info = ErrantGtidInfo (unsafeNodeId "db3" 3306) (unsafeParseGtidSet' "uuid3:1")
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

    it "round-trips NodeUnreachable" $
      roundTripHealth (NodeUnreachable "conn refused")
        `shouldBe` Just (NodeUnreachable "conn refused")

    it "round-trips ReplicaIOStopped with error" $
      roundTripHealth (ReplicaIOStopped "Access denied")
        `shouldBe` Just (ReplicaIOStopped "Access denied")

    it "round-trips ReplicaIOStopped with empty text" $
      roundTripHealth (ReplicaIOStopped "")
        `shouldBe` Just (ReplicaIOStopped "")

    it "round-trips ReplicaIOConnecting" $
      roundTripHealth ReplicaIOConnecting
        `shouldBe` Just ReplicaIOConnecting

    it "round-trips ReplicaSQLStopped" $
      roundTripHealth (ReplicaSQLStopped "duplicate key")
        `shouldBe` Just (ReplicaSQLStopped "duplicate key")

    it "round-trips ErrantGtidDetected" $
      let gs = unsafeParseGtidSet' "uuid3:1"
      in roundTripHealth (ErrantGtidDetected gs)
        `shouldBe` Just (ErrantGtidDetected gs)

    it "round-trips NoSourceDetected" $
      roundTripHealth NoSourceDetected
        `shouldBe` Just NoSourceDetected

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
      roundTrip (ReqDemote (Just "main") "db2" "db1" Live)
        `shouldBe` Just (ReqDemote (Just "main") "db2" "db1" Live)

    it "round-trips ReqFixErrantGtid with dryRun=false" $
      roundTrip (ReqFixErrantGtid Nothing Live)
        `shouldBe` Just (ReqFixErrantGtid Nothing Live)

    it "round-trips ReqFixErrantGtid with dryRun=true" $
      roundTrip (ReqFixErrantGtid (Just "main") DryRun)
        `shouldBe` Just (ReqFixErrantGtid (Just "main") DryRun)

    it "round-trips ReqDemote with dryRun=true" $
      roundTrip (ReqDemote (Just "main") "db2" "db1" DryRun)
        `shouldBe` Just (ReqDemote (Just "main") "db2" "db1" DryRun)

    it "round-trips ReqSimulateFailover" $
      roundTrip (ReqSimulateFailover (Just "main"))
        `shouldBe` Just (ReqSimulateFailover (Just "main"))

    it "round-trips ReqSimulateFailover without cluster" $
      roundTrip (ReqSimulateFailover Nothing)
        `shouldBe` Just (ReqSimulateFailover Nothing)

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

    it "round-trips ReqStopReplication" $
      roundTrip (ReqStopReplication (Just "main") "db2")
        `shouldBe` Just (ReqStopReplication (Just "main") "db2")

    it "round-trips ReqStartReplication" $
      roundTrip (ReqStartReplication Nothing "db3")
        `shouldBe` Just (ReqStartReplication Nothing "db3")

  describe "Response FromJSON error paths" $ do
    it "rejects unknown response type" $
      (decode (BLC.pack "{\"type\":\"foobar\",\"data\":[]}") :: Maybe Response) `shouldBe` Nothing

    it "round-trips RespTopology" $ do
      let view = ClusterTopologyView "test" [NodeStateView "db1" 3306 Source Healthy (Just 0) emptyGtidSet Nothing Running Unfenced]
      roundTripResp (RespTopology [view]) `shouldBe` Just (RespTopology [view])

  describe "NodeStateView fenced field" $ do
    it "round-trips NodeStateView with fenced=True" $ do
      let view = ClusterTopologyView "test" [NodeStateView "db1" 3306 Source Healthy (Just 0) emptyGtidSet Nothing Running Fenced]
      roundTripResp (RespTopology [view]) `shouldBe` Just (RespTopology [view])

    it "defaults fenced to False when field is absent" $ do
      let json = BLC.pack
            "{\"type\":\"topology\",\"data\":[{\"clusterName\":\"test\",\"nodes\":[{\"host\":\"db1\",\"port\":3306,\"isSource\":true,\"health\":\"Healthy\",\"lagSeconds\":0,\"errantGtids\":\"\",\"connectError\":null,\"paused\":false}]}]}"
      let expected = RespTopology [ClusterTopologyView "test"
                       [NodeStateView "db1" 3306 Source Healthy (Just 0) emptyGtidSet Nothing Running Unfenced]]
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

  describe "recvLine" $ do
    it "returns Right for normal data with newline" $ do
      (s1, s2) <- socketPair AF_UNIX Stream 0
      _ <- async $ do
        NSB.sendAll s2 (BSC.pack "hello world\n")
        close s2
      result <- recvLine s1
      close s1
      result `shouldBe` Right (BSC.pack "hello world")

    it "returns Left when connection closes without newline" $ do
      (s1, s2) <- socketPair AF_UNIX Stream 0
      _ <- async $ do
        NSB.sendAll s2 (BSC.pack "no newline here")
        close s2
      result <- recvLine s1
      close s1
      result `shouldBe` Left "Connection closed before newline"

    it "returns Left when data exceeds maxLineLength" $ do
      (s1, s2) <- socketPair AF_UNIX Stream 0
      -- Sender and receiver must run concurrently: sendAll blocks when
      -- the kernel buffer is full, and recvLine drains it.
      sender <- async $ do
        let chunk = BS.replicate 65536 0x41  -- 64KB of 'A'
            totalChunks = (maxLineLength `div` 65536) + 2
        mapM_ (\_ -> NSB.sendAll s2 chunk) [1 :: Int .. totalChunks]
        close s2
      result <- recvLine s1
      -- Close receiver first so sender gets EPIPE and unblocks
      close s1
      _ <- async (wait sender) -- don't block on sender if it already errored
      case result of
        Left msg -> msg `shouldBe` "Line too long (exceeds 1 MiB)"
        Right _  -> expectationFailure "expected Left but got Right"

roundTrip :: Request -> Maybe Request
roundTrip = decode . encode

roundTripResp :: Response -> Maybe Response
roundTripResp = decode . encode

roundTripHealth :: NodeHealth -> Maybe NodeHealth
roundTripHealth = decode . encode

unsafeParseGtidSet' :: Text -> GtidSet
unsafeParseGtidSet' t = case parseGtidSet t of
  Right gs -> gs
  Left err -> error $ "unsafeParseGtidSet': " <> err
