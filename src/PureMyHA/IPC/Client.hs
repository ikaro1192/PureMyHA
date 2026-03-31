module PureMyHA.IPC.Client
  ( sendRequest
  , printStatus
  , printTopology
  , printOperationResult
  , printErrantGtids
  ) where

import Control.Exception (bracket, try, SomeException)
import Data.Aeson (encode, eitherDecode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, formatTime, defaultTimeLocale)
import Network.Socket
import qualified Network.Socket.ByteString as NSB
import PureMyHA.IPC.Protocol
import qualified PureMyHA.IPC.Socket as IPCSocket
import PureMyHA.Types

-- | Send a request to the daemon and return the response
sendRequest :: FilePath -> Request -> IO (Either Text Response)
sendRequest socketPath req = do
  result <- try @SomeException $
    bracket (connectSocket socketPath) close $ \sock -> do
      let bytes = BL.toStrict (encode req <> BLC.singleton '\n')
      NSB.sendAll sock bytes
      recvResponse sock
  pure $ case result of
    Left err  -> Left (T.pack (show err))
    Right resp -> resp

connectSocket :: FilePath -> IO Socket
connectSocket path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  pure sock

recvResponse :: Socket -> IO (Either Text Response)
recvResponse sock = do
  result <- IPCSocket.recvLine sock
  pure $ result >>= \bs ->
    case eitherDecode (BL.fromStrict bs) of
      Left err   -> Left (T.pack err)
      Right resp -> Right resp

-- | Print cluster status in tabular format
printStatus :: Bool -> [ClusterStatus] -> IO ()
printStatus True  statuses = BLC.putStrLn (encode statuses)
printStatus False statuses = do
  putStrLn $ padR 20 "CLUSTER" <> padR 25 "HEALTH" <> padR 20 "SOURCE" <> padR 6 "NODES" <> padR 8 "PAUSED" <> "RECOVERY BLOCKED"
  putStrLn (replicate 88 '-')
  mapM_ printClusterStatus statuses

printClusterStatus :: ClusterStatus -> IO ()
printClusterStatus cs = do
  let health      = showHealth (csHealth cs)
      source      = maybe "-" (T.unpack . unHostName) (csSourceHost cs)
      nodes       = show (csNodeCount cs)
      paused      = if csPaused cs then "yes" else "no"
      blocked     = maybe "-" showTime (csRecoveryBlockedUntil cs)
  putStrLn $ padR 20 (T.unpack (unClusterName (csClusterName cs)))
           <> padR 25 health
           <> padR 20 source
           <> padR 6  nodes
           <> padR 8  paused
           <> blocked

-- | Print topology in tree format
printTopology :: Bool -> [ClusterTopologyView] -> IO ()
printTopology True  views = BLC.putStrLn (encode views)
printTopology False views = mapM_ printClusterTopology views

printClusterTopology :: ClusterTopologyView -> IO ()
printClusterTopology ctv = do
  TIO.putStrLn $ "Cluster: " <> unClusterName (ctvClusterName ctv)
  let nodes = ctvNodes ctv
      source = filter nsvIsSource nodes
      replicas = filter (not . nsvIsSource) nodes
  mapM_ (printNode True) source
  mapM_ (printNode False) replicas
  putStrLn ""

printNode :: Bool -> NodeStateView -> IO ()
printNode isSrc nsv = do
  let prefix = if isSrc then "[SOURCE] " else "  [REPLICA] "
      host   = T.unpack (unHostName (nsvHost nsv)) <> ":" <> show (nsvPort nsv)
      status = if nsvPaused nsv
                 then "[PAUSED]"
                 else "[" <> showHealth (nsvHealth nsv) <> "]"
      lag    = case nsvLagSeconds nsv of
        Nothing -> ""
        Just s  -> " lag=" <> show s <> "s"
      errant = if nsvErrantGtids nsv == "" then "" else " ERRANT_GTID"
      fenced = if nsvFenced nsv then " FENCED" else ""
  putStrLn $ prefix <> host <> " " <> status <> lag <> errant <> fenced

-- | Print an operation result
printOperationResult :: Bool -> OperationResult -> IO ()
printOperationResult True  result = BLC.putStrLn (encode result)
printOperationResult False (OperationSuccess msg) = TIO.putStrLn $ "OK: " <> msg
printOperationResult False (OperationFailure msg) = TIO.putStrLn $ "ERROR: " <> msg

-- | Print errant GTID info
printErrantGtids :: Bool -> [ErrantGtidInfo] -> IO ()
printErrantGtids True  infos = BLC.putStrLn (encode infos)
printErrantGtids False [] = putStrLn "No errant GTIDs detected."
printErrantGtids False infos = do
  putStrLn "Errant GTIDs:"
  mapM_ printErrantGtidInfo infos

printErrantGtidInfo :: ErrantGtidInfo -> IO ()
printErrantGtidInfo eg =
  TIO.putStrLn $ "  " <> unHostName (nodeHost (egiNodeId eg)) <> ":" <>
    T.pack (show (nodePort (egiNodeId eg))) <> " -> " <> egiErrantGtid eg

showHealth :: NodeHealth -> String
showHealth Healthy                  = "Healthy"
showHealth DeadSource               = "DeadSource"
showHealth UnreachableSource        = "UnreachableSource"
showHealth DeadSourceAndAllReplicas = "DeadSourceAndAllReplicas"
showHealth SplitBrainSuspected      = "SplitBrainSuspected"
showHealth (NodeUnreachable msg)    = "NodeUnreachable: " <> T.unpack msg
showHealth (ReplicaIOStopped msg)   = "ReplicaIOStopped" <> if T.null msg then "" else ": " <> T.unpack msg
showHealth ReplicaIOConnecting      = "ReplicaIOConnecting"
showHealth (ReplicaSQLStopped msg)  = "ReplicaSQLStopped: " <> T.unpack msg
showHealth (ErrantGtidDetected g)   = "ErrantGtidDetected: " <> T.unpack g
showHealth NoSourceDetected         = "NoSourceDetected"
showHealth (NeedsAttention msg)     = "NeedsAttention: " <> T.unpack msg
showHealth (Lagging n)              = "Lagging: " <> show n <> "s"

showTime :: UTCTime -> String
showTime = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

padR :: Int -> String -> String
padR n s = take n (s <> repeat ' ')
