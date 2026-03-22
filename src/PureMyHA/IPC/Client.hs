module PureMyHA.IPC.Client
  ( sendRequest
  , printStatus
  , printTopology
  , printOperationResult
  , printErrantGtids
  , printEventHistory
  ) where

import Control.Exception (bracket, try, SomeException)
import Data.Aeson (encode, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, formatTime, defaultTimeLocale)
import Network.Socket
import qualified Network.Socket.ByteString as NSB
import PureMyHA.IPC.Protocol
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
recvResponse sock = go []
  where
    go acc = do
      chunk <- NSB.recv sock 4096
      if BS.null chunk
        then pure (Left "Connection closed before response")
        else do
          let acc' = chunk : acc
              full = BS.concat (reverse acc')
          if BSC.elem '\n' full
            then
              let line = BSC.takeWhile (/= '\n') full
              in pure $ case eitherDecode (BL.fromStrict line) of
                Left err   -> Left (T.pack err)
                Right resp -> Right resp
            else go acc'

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
      source      = maybe "-" T.unpack (csSourceHost cs)
      nodes       = show (csNodeCount cs)
      paused      = if csPaused cs then "yes" else "no"
      blocked     = maybe "-" showTime (csRecoveryBlockedUntil cs)
  putStrLn $ padR 20 (T.unpack (csClusterName cs))
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
  TIO.putStrLn $ "Cluster: " <> ctvClusterName ctv
  let nodes = ctvNodes ctv
      source = filter nsvIsSource nodes
      replicas = filter (not . nsvIsSource) nodes
  mapM_ (printNode True) source
  mapM_ (printNode False) replicas
  putStrLn ""

printNode :: Bool -> NodeStateView -> IO ()
printNode isSource nsv = do
  let prefix = if isSource then "[SOURCE] " else "  [REPLICA] "
      host   = T.unpack (nsvHost nsv) <> ":" <> show (nsvPort nsv)
      status = if nsvPaused nsv
                 then "[PAUSED]"
                 else "[" <> showHealth (nsvHealth nsv) <> "]"
      lag    = case nsvLagSeconds nsv of
        Nothing -> ""
        Just s  -> " lag=" <> show s <> "s"
      errant = if nsvErrantGtids nsv == "" then "" else " ERRANT_GTID"
  putStrLn $ prefix <> host <> " " <> status <> lag <> errant

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
  TIO.putStrLn $ "  " <> nodeHost (egiNodeId eg) <> ":" <>
    T.pack (show (nodePort (egiNodeId eg))) <> " -> " <> egiErrantGtid eg

-- | Print event history in tabular or JSON format
printEventHistory :: Bool -> [Event] -> IO ()
printEventHistory True  evs = BLC.putStrLn (encode evs)
printEventHistory False [] = putStrLn "No events recorded."
printEventHistory False evs = do
  putStrLn $ padR 22 "TIME" <> padR 16 "CLUSTER" <> padR 22 "TYPE" <> padR 16 "NODE" <> "DETAILS"
  putStrLn (replicate 88 '-')
  mapM_ printEvent evs

printEvent :: Event -> IO ()
printEvent ev =
  putStrLn $ padR 22 (showTime (evTimestamp ev))
           <> padR 16 (T.unpack (evCluster ev))
           <> padR 22 (showEventType (evType ev))
           <> padR 16 (maybe "-" T.unpack (evNode ev))
           <> T.unpack (evDetails ev)

showEventType :: EventType -> String
showEventType EvHealthChange      = "HealthChange"
showEventType EvClusterHealth     = "ClusterHealth"
showEventType EvFailoverStarted   = "FailoverStarted"
showEventType EvFailoverCompleted = "FailoverCompleted"
showEventType EvFailoverFailed    = "FailoverFailed"
showEventType EvSwitchoverCompleted = "SwitchoverCompleted"
showEventType EvConfigReloaded    = "ConfigReloaded"
showEventType EvPauseChanged      = "PauseChanged"

showHealth :: NodeHealth -> String
showHealth Healthy                  = "Healthy"
showHealth DeadSource               = "DeadSource"
showHealth UnreachableSource        = "UnreachableSource"
showHealth DeadSourceAndAllReplicas = "DeadSourceAndAllReplicas"
showHealth SplitBrainSuspected      = "SplitBrainSuspected"
showHealth (NeedsAttention msg)     = "NeedsAttention: " <> T.unpack msg

showTime :: UTCTime -> String
showTime = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

padR :: Int -> String -> String
padR n s = take n (s <> repeat ' ')
