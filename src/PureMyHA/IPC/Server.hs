module PureMyHA.IPC.Server
  ( startIPCServer
  , defaultSocketPath
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket, try, catch, SomeException, finally)
import Data.Aeson (encode, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Network.Socket hiding (recv, send)
import qualified Network.Socket.ByteString as NSB
import PureMyHA.Config
import PureMyHA.Failover.ErrantGtid (runFixErrantGtid)
import PureMyHA.Failover.Switchover (runSwitchover, dryRunSwitchover)
import System.Posix.Files (removeLink)
import PureMyHA.IPC.Protocol
import PureMyHA.Logger (Logger)
import PureMyHA.Topology.State
import PureMyHA.Types

defaultSocketPath :: FilePath
defaultSocketPath = "/run/purermyhad.sock"

type ClusterEntry = (FailoverLock, ClusterConfig, FailoverConfig, FailureDetectionConfig, Text, Maybe HooksConfig)
type ClusterMap   = Map ClusterName ClusterEntry

-- | Start the Unix domain socket IPC server (blocks forever)
startIPCServer
  :: TVarDaemonState
  -> ClusterMap
  -> FilePath
  -> Logger
  -> IO ()
startIPCServer tvar clusterMap socketPath logger =
  bracket (openListenSocket socketPath)
          (\sock -> close sock >> removeLink socketPath `catch` \(_ :: SomeException) -> pure ())
          $ \sock -> do
    listen sock 5
    acceptLoop sock tvar clusterMap logger

openListenSocket :: FilePath -> IO Socket
openListenSocket path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  removeLink path `catch` \(_ :: SomeException) -> pure ()  -- remove stale socket file
  bind sock (SockAddrUnix path)
  pure sock

acceptLoop :: Socket -> TVarDaemonState -> ClusterMap -> Logger -> IO ()
acceptLoop listenSock tvar clusterMap logger = do
  (clientSock, _) <- accept listenSock
  _ <- async $ handleClient clientSock tvar clusterMap logger `finally` close clientSock
  acceptLoop listenSock tvar clusterMap logger

handleClient :: Socket -> TVarDaemonState -> ClusterMap -> Logger -> IO ()
handleClient sock tvar clusterMap logger = do
  result <- try @SomeException $ do
    msg <- recvLine sock
    case eitherDecode (BLC.pack msg) of
      Left err  -> sendResponse sock (RespError (T.pack err))
      Right req -> do
        resp <- handleRequest tvar clusterMap logger req
        sendResponse sock resp
  case result of
    Left _ -> pure ()
    Right () -> pure ()

recvLine :: Socket -> IO String
recvLine sock = go []
  where
    go acc = do
      chunk <- NSB.recv sock 4096
      if BS.null chunk
        then pure (BSC.unpack (BS.concat (reverse acc)))
        else do
          let acc' = chunk : acc
              full = BSC.unpack (BS.concat (reverse acc'))
          if '\n' `elem` full
            then pure (takeWhile (/= '\n') full)
            else go acc'

sendResponse :: Socket -> Response -> IO ()
sendResponse sock resp = do
  let bytes = BL.toStrict (encode resp <> BLC.singleton '\n')
  NSB.sendAll sock bytes

handleRequest :: TVarDaemonState -> ClusterMap -> Logger -> Request -> IO Response
handleRequest tvar clusterMap logger req = case req of
  ReqStatus mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    pure $ RespStatus (map toClusterStatus topos)

  ReqTopology mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    pure $ RespTopology (map toClusterTopologyView topos)

  ReqSwitchover mCluster mToHost dryRun ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just (_, cc, fc, _, password, mHooks) ->
        if dryRun
          then do
            result <- dryRunSwitchover tvar cc fc mToHost
            pure $ RespOperation $ case result of
              Left err  -> OperationFailure err
              Right msg -> OperationSuccess msg
          else do
            result <- runSwitchover tvar cc fc password mToHost mHooks logger
            pure $ RespOperation $ case result of
              Left err -> OperationFailure err
              Right () -> OperationSuccess "Switchover completed"

  ReqAckRecovery mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just (_, cc, _, _, _, _) -> do
        atomically $ clearRecoveryBlock tvar (ccName cc)
        pure $ RespOperation (OperationSuccess "Recovery block cleared")

  ReqErrantGtid mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    let errants = concatMap clusterErrantGtids topos
    pure (RespErrantGtids errants)

  ReqFixErrantGtid mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just (_, cc, _, _, password, _) -> do
        result <- runFixErrantGtid tvar cc password
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess "Errant GTIDs fixed on source"

filterClusters :: Maybe ClusterName -> Map ClusterName ClusterTopology -> [ClusterTopology]
filterClusters Nothing  m = Map.elems m
filterClusters (Just n) m = maybe [] pure (Map.lookup n m)

lookupCluster :: Maybe ClusterName -> ClusterMap -> Maybe ClusterEntry
lookupCluster Nothing  m = case Map.elems m of { [x] -> Just x; _ -> Nothing }
lookupCluster (Just n) m = Map.lookup n m

toClusterStatus :: ClusterTopology -> ClusterStatus
toClusterStatus ct = ClusterStatus
  { csClusterName          = ctClusterName ct
  , csHealth               = ctHealth ct
  , csSourceHost           = fmap nodeHost (ctSourceNodeId ct)
  , csNodeCount            = Map.size (ctNodes ct)
  , csRecoveryBlockedUntil = ctRecoveryBlockedUntil ct
  }

toClusterTopologyView :: ClusterTopology -> ClusterTopologyView
toClusterTopologyView ct = ClusterTopologyView
  { ctvClusterName = ctClusterName ct
  , ctvNodes       = map toNodeStateView (Map.elems (ctNodes ct))
  }

toNodeStateView :: NodeState -> NodeStateView
toNodeStateView ns = NodeStateView
  { nsvHost        = nodeHost (nsNodeId ns)
  , nsvPort        = nodePort (nsNodeId ns)
  , nsvIsSource    = nsIsSource ns
  , nsvHealth      = nsHealth ns
  , nsvLagSeconds  = nsReplicaStatus ns >>= rsSecondsBehindSource
  , nsvErrantGtids = nsErrantGtids ns
  , nsvConnectError = nsConnectError ns
  }

clusterErrantGtids :: ClusterTopology -> [ErrantGtidInfo]
clusterErrantGtids ct =
  [ ErrantGtidInfo (nsNodeId ns) (nsErrantGtids ns)
  | ns <- Map.elems (ctNodes ct)
  , nsErrantGtids ns /= ""
  ]
