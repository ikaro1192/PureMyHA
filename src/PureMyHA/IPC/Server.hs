module PureMyHA.IPC.Server
  ( startIPCServer
  , defaultSocketPath
  , DiscoveryAction
  , toClusterStatus
  , toClusterTopologyView
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM (TVar, atomically, readTVarIO, writeTVar)
import Control.Exception (bracket, try, catch, SomeException, finally)
import Data.Aeson (encode, eitherDecode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Network.Socket
import qualified Network.Socket.ByteString as NSB
import PureMyHA.Config
import PureMyHA.Env (ClusterEnv (..), runApp)
import PureMyHA.Event (EventBuffer, getRecentEvents)
import PureMyHA.Logger (Logger, reopenLogger)
import PureMyHA.Failover.Demote (runDemote)
import PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica)
import PureMyHA.Failover.ErrantGtid (runFixErrantGtid)
import PureMyHA.Failover.Switchover (runSwitchover, dryRunSwitchover)
import System.Posix.Files (removeLink)
import PureMyHA.IPC.Protocol
import PureMyHA.Topology.State
import PureMyHA.Types

defaultSocketPath :: FilePath
defaultSocketPath = "/run/puremyhad.sock"

type ClusterMap   = Map ClusterName ClusterEnv
type DiscoveryAction = IO (Either Text Text)
type DiscoveryMap = Map ClusterName DiscoveryAction

-- | Start the Unix domain socket IPC server (blocks forever)
startIPCServer
  :: TVarDaemonState
  -> ClusterMap
  -> DiscoveryMap
  -> EventBuffer
  -> FilePath       -- ^ socket path
  -> TVar Logger    -- ^ for set-log-level
  -> FilePath       -- ^ log file path
  -> TVar LogLevel  -- ^ current log level
  -> IO ()
startIPCServer tvar clusterMap discoveryMap eventBuf socketPath loggerVar logFile levelVar =
  bracket (openListenSocket socketPath)
          (\sock -> close sock >> removeLink socketPath `catch` \(_ :: SomeException) -> pure ())
          $ \sock -> do
    listen sock 5
    acceptLoop sock tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar

openListenSocket :: FilePath -> IO Socket
openListenSocket path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  removeLink path `catch` \(_ :: SomeException) -> pure ()  -- remove stale socket file
  bind sock (SockAddrUnix path)
  pure sock

acceptLoop :: Socket -> TVarDaemonState -> ClusterMap -> DiscoveryMap -> EventBuffer -> TVar Logger -> FilePath -> TVar LogLevel -> IO ()
acceptLoop listenSock tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar = do
  (clientSock, _) <- accept listenSock
  _ <- async $ handleClient clientSock tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar `finally` close clientSock
  acceptLoop listenSock tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar

handleClient :: Socket -> TVarDaemonState -> ClusterMap -> DiscoveryMap -> EventBuffer -> TVar Logger -> FilePath -> TVar LogLevel -> IO ()
handleClient sock tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar = do
  result <- try @SomeException $ do
    msg <- recvLine sock
    case eitherDecode (BLC.pack msg) of
      Left err  -> sendResponse sock (RespError (T.pack err))
      Right req -> do
        resp <- handleRequest tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar req
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

handleRequest :: TVarDaemonState -> ClusterMap -> DiscoveryMap -> EventBuffer -> TVar Logger -> FilePath -> TVar LogLevel -> Request -> IO Response
handleRequest tvar clusterMap discoveryMap eventBuf loggerVar logFile levelVar req = case req of
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
      Just env ->
        if dryRun
          then do
            result <- runApp env $ dryRunSwitchover mToHost
            pure $ RespOperation $ case result of
              Left err  -> OperationFailure err
              Right msg -> OperationSuccess msg
          else do
            result <- runApp env $ runSwitchover mToHost
            pure $ RespOperation $ case result of
              Left err -> OperationFailure err
              Right () -> OperationSuccess "Switchover completed"

  ReqAckRecovery mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        atomically $ clearRecoveryBlock (envDaemonState env) (ccName (envCluster env))
        pure $ RespOperation (OperationSuccess "Recovery block cleared")

  ReqErrantGtid mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    let errants = concatMap clusterErrantGtids topos
    pure (RespErrantGtids errants)

  ReqFixErrantGtid mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        result <- runApp env runFixErrantGtid
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess "Errant GTIDs fixed on source"

  ReqDemote mCluster host srcHost ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        result <- runApp env $ runDemote host srcHost
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess ("Demote completed: " <> host <> " is now a replica")

  ReqDiscovery mCluster ->
    case lookupDiscovery mCluster discoveryMap of
      Nothing -> pure (RespError "Cluster not found")
      Just action -> do
        result <- action
        pure $ RespOperation $ case result of
          Left err  -> OperationFailure err
          Right msg -> OperationSuccess msg

  ReqPauseReplica mCluster host ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        result <- runApp env $ runPauseReplica host
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess ("Replication paused on " <> host)

  ReqResumeReplica mCluster host ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        result <- runApp env $ runResumeReplica host
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess ("Replication resumed on " <> host)

  ReqPauseFailover mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        atomically $ setClusterPause (envDaemonState env) (ccName (envCluster env))
        pure $ RespOperation (OperationSuccess "Failover paused")

  ReqResumeFailover mCluster ->
    case lookupCluster mCluster clusterMap of
      Nothing -> pure (RespError "Cluster not found")
      Just env -> do
        atomically $ clearClusterPause (envDaemonState env) (ccName (envCluster env))
        pure $ RespOperation (OperationSuccess "Failover resumed")

  ReqEventHistory mCluster mLimit -> do
    evs <- getRecentEvents eventBuf mCluster mLimit
    pure (RespEventHistory evs)

  ReqSetLogLevel lvlText ->
    case parseLogLevel lvlText of
      Nothing  -> pure $ RespError ("Invalid log level: " <> lvlText <> " (expected: debug, info, warn, error)")
      Just lvl -> do
        old <- readTVarIO loggerVar
        new <- reopenLogger logFile lvl old
        atomically $ do
          writeTVar loggerVar new
          writeTVar levelVar lvl
        pure $ RespOperation (OperationSuccess ("Log level set to " <> lvlText))

filterClusters :: Maybe ClusterName -> Map ClusterName ClusterTopology -> [ClusterTopology]
filterClusters Nothing  m = Map.elems m
filterClusters (Just n) m = maybe [] pure (Map.lookup n m)

lookupCluster :: Maybe ClusterName -> ClusterMap -> Maybe ClusterEnv
lookupCluster Nothing  m = case Map.elems m of { [x] -> Just x; _ -> Nothing }
lookupCluster (Just n) m = Map.lookup n m

lookupDiscovery :: Maybe ClusterName -> DiscoveryMap -> Maybe DiscoveryAction
lookupDiscovery Nothing  m = case Map.elems m of { [x] -> Just x; _ -> Nothing }
lookupDiscovery (Just n) m = Map.lookup n m

toClusterStatus :: ClusterTopology -> ClusterStatus
toClusterStatus ct = ClusterStatus
  { csClusterName          = ctClusterName ct
  , csHealth               = ctHealth ct
  , csSourceHost           = fmap nodeHost (ctSourceNodeId ct)
  , csNodeCount            = Map.size (ctNodes ct)
  , csRecoveryBlockedUntil = ctRecoveryBlockedUntil ct
  , csPaused               = ctPaused ct
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
  , nsvPaused      = nsPaused ns
  }

clusterErrantGtids :: ClusterTopology -> [ErrantGtidInfo]
clusterErrantGtids ct =
  [ ErrantGtidInfo (nsNodeId ns) (nsErrantGtids ns)
  | ns <- Map.elems (ctNodes ct)
  , nsErrantGtids ns /= ""
  ]
