module PureMyHA.IPC.Server
  ( startIPCServer
  , defaultSocketPath
  , DiscoveryAction (..)
  , ClusterMap (..)
  , DiscoveryMap (..)
  , toClusterStatus
  , toClusterTopologyView
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM (TVar, atomically, readTVarIO, writeTBQueue)
import Control.Exception (bracket, try, catch, SomeException, finally)
import Control.Monad (void)
import Data.Aeson (encode, eitherDecode)
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
import PureMyHA.Logger (Logger, setLogLevel)
import PureMyHA.Supervisor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Clone (runClone)
import PureMyHA.Failover.Auto (doUnfence, simulateFailover)
import PureMyHA.Failover.Demote (runDemote, dryRunDemote)
import PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica, runStopReplication, runStartReplication)
import PureMyHA.Failover.ErrantGtid (runFixErrantGtid, dryRunFixErrantGtid)
import PureMyHA.Failover.Switchover (runSwitchover, dryRunSwitchover)
import System.Posix.Files (removeLink)
import PureMyHA.IPC.Protocol
import PureMyHA.MySQL.GTID (isEmptyGtidSet)
import qualified PureMyHA.IPC.Socket as IPCSocket
import PureMyHA.Topology.State
import PureMyHA.Types

defaultSocketPath :: FilePath
defaultSocketPath = "/run/puremyhad.sock"

newtype ClusterMap = ClusterMap { unClusterMap :: Map ClusterName ClusterEnv }
newtype DiscoveryAction = DiscoveryAction { runDiscoveryAction :: IO (Either Text Text) }
newtype DiscoveryMap = DiscoveryMap { unDiscoveryMap :: Map ClusterName DiscoveryAction }

-- | Start the Unix domain socket IPC server (blocks forever)
startIPCServer
  :: TVarDaemonState
  -> ClusterMap
  -> DiscoveryMap
  -> FilePath    -- ^ socket path
  -> TVar Logger -- ^ for set-log-level
  -> IO ()
startIPCServer tvar clusterMap discoveryMap socketPath loggerVar =
  bracket (openListenSocket socketPath)
          (\sock -> close sock >> removeLink socketPath `catch` \(_ :: SomeException) -> pure ())
          $ \sock -> do
    listen sock 5
    acceptLoop sock tvar clusterMap discoveryMap loggerVar

openListenSocket :: FilePath -> IO Socket
openListenSocket path = do
  sock <- socket AF_UNIX Stream defaultProtocol
  removeLink path `catch` \(_ :: SomeException) -> pure ()  -- remove stale socket file
  bind sock (SockAddrUnix path)
  pure sock

acceptLoop :: Socket -> TVarDaemonState -> ClusterMap -> DiscoveryMap -> TVar Logger -> IO ()
acceptLoop listenSock tvar clusterMap discoveryMap loggerVar = do
  (clientSock, _) <- accept listenSock
  void $ async $ handleClient clientSock tvar clusterMap discoveryMap loggerVar `finally` close clientSock
  acceptLoop listenSock tvar clusterMap discoveryMap loggerVar

handleClient :: Socket -> TVarDaemonState -> ClusterMap -> DiscoveryMap -> TVar Logger -> IO ()
handleClient sock tvar clusterMap discoveryMap loggerVar = do
  result <- try @SomeException $ do
    msg <- recvLine sock
    case eitherDecode (BLC.pack msg) of
      Left err  -> sendResponse sock (RespError (T.pack err))
      Right req -> do
        resp <- handleRequest tvar clusterMap discoveryMap loggerVar req
        sendResponse sock resp
  case result of
    Left _ -> pure ()
    Right () -> pure ()

recvLine :: Socket -> IO String
recvLine sock = do
  result <- IPCSocket.recvLine sock
  pure $ case result of
    Left _   -> ""
    Right bs -> BSC.unpack bs

sendResponse :: Socket -> Response -> IO ()
sendResponse sock resp = do
  let bytes = BL.toStrict (encode resp <> BLC.singleton '\n')
  NSB.sendAll sock bytes

handleRequest :: TVarDaemonState -> ClusterMap -> DiscoveryMap -> TVar Logger -> Request -> IO Response
handleRequest tvar clusterMap discoveryMap loggerVar req = case req of
  ReqStatus mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    pure $ RespStatus (map toClusterStatus topos)

  ReqTopology mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    pure $ RespTopology (map toClusterTopologyView topos)

  ReqSwitchover mCluster target dryRun ->
    withClusterEnv mCluster clusterMap $ \env -> case dryRun of
      DryRun -> do
        result <- runApp env $ dryRunSwitchover target
        pure $ RespOperation $ case result of
          Left err  -> OperationFailure err
          Right msg -> OperationSuccess msg
      Live -> do
        result <- runApp env $ runSwitchover target
        pure $ RespOperation $ case result of
          Left err -> OperationFailure err
          Right () -> OperationSuccess "Switchover completed"

  ReqAckRecovery mCluster ->
    withClusterEnv mCluster clusterMap $ \env -> do
      atomically $ writeTBQueue (envEventQueue env) RecoveryBlockCleared
      pure $ RespOperation (OperationSuccess "Recovery block cleared")

  ReqErrantGtid mCluster -> do
    ds <- readDaemonState tvar
    let topos = filterClusters mCluster (dsClusters ds)
    let errants = concatMap clusterErrantGtids topos
    pure (RespErrantGtids errants)

  ReqFixErrantGtid mCluster dryRun -> case dryRun of
    DryRun ->
      withClusterEnv mCluster clusterMap $ \env -> do
        result <- runApp env dryRunFixErrantGtid
        pure $ RespOperation $ case result of
          Left err  -> OperationFailure err
          Right msg -> OperationSuccess msg
    Live ->
      runClusterOp mCluster clusterMap
        (\env -> runApp env runFixErrantGtid) "Errant GTIDs fixed on source"

  ReqDemote mCluster host srcHost dryRun -> case dryRun of
    DryRun ->
      withClusterEnv mCluster clusterMap $ \env -> do
        result <- runApp env (dryRunDemote host srcHost)
        pure $ RespOperation $ case result of
          Left err  -> OperationFailure err
          Right msg -> OperationSuccess msg
    Live ->
      runClusterOp mCluster clusterMap
        (\env -> runApp env $ runDemote host srcHost) ("Demote completed: " <> unHostName host <> " is now a replica")

  ReqSimulateFailover mCluster ->
    withClusterEnv mCluster clusterMap $ \env -> do
      result <- runApp env simulateFailover
      pure $ RespOperation $ case result of
        Left err  -> OperationFailure err
        Right msg -> OperationSuccess msg

  ReqDiscovery mCluster ->
    case lookupByCluster mCluster (unDiscoveryMap discoveryMap) of
      Nothing -> pure (RespError "Cluster not found")
      Just action -> do
        result <- runDiscoveryAction action
        pure $ RespOperation $ case result of
          Left err  -> OperationFailure err
          Right msg -> OperationSuccess msg

  ReqPauseReplica mCluster host ->
    runClusterOp mCluster clusterMap
      (\env -> runApp env $ runPauseReplica host) ("Replica paused (excluded from failover) on " <> unHostName host)

  ReqResumeReplica mCluster host ->
    runClusterOp mCluster clusterMap
      (\env -> runApp env $ runResumeReplica host) ("Replica resumed (included in failover) on " <> unHostName host)

  ReqStopReplication mCluster host ->
    runClusterOp mCluster clusterMap
      (\env -> runApp env $ runStopReplication host) ("Replication stopped on " <> unHostName host)

  ReqStartReplication mCluster host ->
    runClusterOp mCluster clusterMap
      (\env -> runApp env $ runStartReplication host) ("Replication started on " <> unHostName host)

  ReqPauseFailover mCluster ->
    withClusterEnv mCluster clusterMap $ \env -> do
      atomically $ writeTBQueue (envEventQueue env) FailoverPaused
      pure $ RespOperation (OperationSuccess "Failover paused")

  ReqResumeFailover mCluster ->
    withClusterEnv mCluster clusterMap $ \env -> do
      atomically $ writeTBQueue (envEventQueue env) FailoverResumed
      pure $ RespOperation (OperationSuccess "Failover resumed")

  ReqSetLogLevel lvlText ->
    case parseLogLevel lvlText of
      Nothing  -> pure $ RespError ("Invalid log level: " <> lvlText <> " (expected: debug, info, warn, error)")
      Just lvl -> do
        logger <- readTVarIO loggerVar
        setLogLevel logger lvl
        pure $ RespOperation (OperationSuccess ("Log level set to " <> logLevelToText lvl))

  ReqUnfence mCluster host ->
    withClusterEnv mCluster clusterMap $ \env -> do
      result <- runApp env (doUnfence host)
      pure $ RespOperation $ case result of
        Left err -> OperationFailure err
        Right () -> OperationSuccess ("Node unfenced: " <> unHostName host)

  ReqClone mCluster recipient mDonor ->
    withClusterEnv mCluster clusterMap $ \env -> do
      result <- runApp env (runClone recipient mDonor)
      pure $ RespOperation $ case result of
        Left err -> OperationFailure err
        Right () -> OperationSuccess ("Clone completed: " <> unHostName recipient <> " re-seeded successfully")

filterClusters :: Maybe ClusterName -> Map ClusterName ClusterTopology -> [ClusterTopology]
filterClusters Nothing  m = Map.elems m
filterClusters (Just n) m = maybe [] pure (Map.lookup n m)

lookupByCluster :: Maybe ClusterName -> Map ClusterName a -> Maybe a
lookupByCluster Nothing  m = case Map.elems m of { [x] -> Just x; _ -> Nothing }
lookupByCluster (Just n) m = Map.lookup n m

withClusterEnv :: Maybe ClusterName -> ClusterMap -> (ClusterEnv -> IO Response) -> IO Response
withClusterEnv mc (ClusterMap cm) action =
  case lookupByCluster mc cm of
    Nothing  -> pure (RespError "Cluster not found")
    Just env -> action env

runClusterOp :: Maybe ClusterName -> ClusterMap -> (ClusterEnv -> IO (Either Text ())) -> Text -> IO Response
runClusterOp mc cm action successMsg =
  withClusterEnv mc cm $ \env -> do
    result <- action env
    pure $ RespOperation $ case result of
      Left err -> OperationFailure err
      Right () -> OperationSuccess successMsg

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
  , nsvRole        = nsRole ns
  , nsvHealth      = nsHealth ns
  , nsvLagSeconds  = case nsProbeResult ns of
      ProbeSuccess{prReplicaStatus = Just rs} -> rsSecondsBehindSource rs
      _ -> Nothing
  , nsvErrantGtids = nsErrantGtids ns
  , nsvConnectError = case nsProbeResult ns of
      ProbeFailure{prConnectError = e} -> Just e
      ProbeSuccess{}                   -> Nothing
  , nsvPaused      = nsPaused ns
  , nsvFenced      = nsFenced ns
  }

clusterErrantGtids :: ClusterTopology -> [ErrantGtidInfo]
clusterErrantGtids ct =
  [ ErrantGtidInfo (nsNodeId ns) (nsErrantGtids ns)
  | ns <- Map.elems (ctNodes ct)
  , not (isEmptyGtidSet (nsErrantGtids ns))
  ]
