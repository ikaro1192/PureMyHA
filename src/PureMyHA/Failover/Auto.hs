module PureMyHA.Failover.Auto
  ( runAutoFailover
  , checkAutoFailoverPreconditions
  ) where

import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.Trans.Class (lift)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import PureMyHA.Config
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.Logger (Logger, logInfo, logError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

-- | Execute automatic failover for a cluster
runAutoFailover
  :: TVarDaemonState
  -> FailoverLock
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Maybe HooksConfig
  -> Logger
  -> IO (Either Text ())
runAutoFailover tvar lock cc fc fdc pws mHooks logger = do
  -- Try to acquire failover lock (prevent concurrent failovers)
  acquired <- atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> pure (Left "Failover already in progress")
    Just () -> do
      result <- doFailover tvar cc fc fdc pws mHooks logger
      atomically $ putTMVar lock ()
      pure result

-- | Check preconditions for auto failover (pure)
checkAutoFailoverPreconditions
  :: UTCTime
  -> ClusterTopology
  -> Int               -- ^ fcMinReplicasForFailover
  -> Either Text ()
checkAutoFailoverPreconditions now topo minReplicas = do
  when (ctPaused topo) $ Left "Failover paused by operator (pause-failover)"
  case ctRecoveryBlockedUntil topo of
    Just deadline | now < deadline ->
      Left "Failover blocked by anti-flap period"
    _ -> Right ()
  case ctHealth topo of
    DeadSource -> Right ()
    h          -> Left $ "Cluster not in DeadSource state: " <> T.pack (show h)
  let replicas = filter (not . nsIsSource) (Map.elems (ctNodes topo))
  if length replicas < minReplicas
    then Left $ "Not enough replicas for failover (need " <> T.pack (show minReplicas) <> ")"
    else Right ()

doFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Maybe HooksConfig
  -> Logger
  -> IO (Either Text ())
doFailover tvar cc fc fdc pws mHooks logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      logError logger $ "[" <> ccName cc <> "] Auto-failover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo -> do
      now <- getCurrentTime
      case checkAutoFailoverPreconditions now topo (fcMinReplicasForFailover fc) of
        Left err -> do
          logError logger $ "[" <> ccName cc <> "] Auto-failover failed: " <> err
          pure (Left err)
        Right () -> do
          logInfo logger $ "[" <> ccName cc <> "] Auto-failover started"
          executeFailover tvar cc fc fdc pws mHooks logger topo

executeFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Maybe HooksConfig
  -> Logger
  -> ClusterTopology
  -> IO (Either Text ())
executeFailover tvar cc fc fdc pws mHooks logger topo = runExceptT $ do
  candidateId <- ExceptT $ case selectCandidate (ctNodes topo) (fcCandidatePriority fc) Nothing of
    Left err -> logError logger (prefix <> "Auto-failover failed: " <> err) >> pure (Left err)
    Right c  -> pure (Right c)
  let oldSourceHost = fmap nodeHost (ctSourceNodeId topo)
      user          = credUser (ccCredentials cc)
      waitTimeout   = truncate (fcWaitRelayLogTimeout fc) :: Int
  ExceptT $ runPreFailoverHook mHooks cc candidateId oldSourceHost logger
  lift $ logInfo logger $ prefix <> "Waiting for relay log apply on " <> nodeHost candidateId <> "..."
  ExceptT $ promoteWithOnFailureHook user pws candidateId waitTimeout logger (ccName cc) mHooks oldSourceHost
  lift $ reconnectOtherReplicas user pws candidateId topo
  now <- lift getCurrentTime
  lift $ commitFailoverState tvar cc fdc topo now
  ts <- lift getCurrentTimestamp
  let postEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  lift $ runHookFireForget mHooks hcPostFailover postEnv
  lift $ logInfo logger $ prefix <> "Auto-failover completed: new source is " <> nodeHost candidateId
  where
    prefix = "[" <> ccName cc <> "] "

runPreFailoverHook
  :: Maybe HooksConfig -> ClusterConfig -> NodeId -> Maybe Text -> Logger
  -> IO (Either Text ())
runPreFailoverHook mHooks cc candidateId oldSourceHost logger = do
  ts <- getCurrentTimestamp
  let preEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  preResult <- runHookOrAbort mHooks hcPreFailover preEnv
  case preResult of
    Left err -> do
      logError logger $ "[" <> ccName cc <> "] Pre-failover hook aborted failover: " <> err
      pure (Left $ "Pre-failover hook failed: " <> err)
    Right () -> pure (Right ())

promoteWithOnFailureHook
  :: Text -> ClusterPasswords -> NodeId -> Int -> Logger -> Text
  -> Maybe HooksConfig -> Maybe Text
  -> IO (Either Text ())
promoteWithOnFailureHook user pws candidateId waitTimeout logger clusterName mHooks oldSourceHost = do
  promoteResult <- promoteCandidate user (cpPassword pws) candidateId waitTimeout logger clusterName
  case promoteResult of
    Left err -> do
      logError logger $ "[" <> clusterName <> "] Auto-failover failed: Promote failed: " <> err
      ts <- getCurrentTimestamp
      let failEnv = HookEnv clusterName (Just (nodeHost candidateId)) oldSourceHost (Just "PromoteFailed") ts
      runHookFireForget mHooks hcPostUnsuccessfulFailover failEnv
      pure (Left $ "Promote failed: " <> err)
    Right () -> pure (Right ())

reconnectOtherReplicas
  :: Text -> ClusterPasswords -> NodeId -> ClusterTopology -> IO ()
reconnectOtherReplicas user pws candidateId topo = do
  let otherReplicas = filter
        (\ns -> nsNodeId ns /= candidateId && not (nsIsSource ns))
        (Map.elems (ctNodes topo))
  mapM_ (reconnectReplica user (cpPassword pws) (cpReplUser pws) (cpReplPassword pws) candidateId) otherReplicas

commitFailoverState
  :: TVarDaemonState -> ClusterConfig -> FailureDetectionConfig
  -> ClusterTopology -> UTCTime -> IO ()
commitFailoverState tvar cc fdc topo now = do
  let oldSources = filter nsIsSource (Map.elems (ctNodes topo))
  atomically $ do
    recordFailover tvar (ccName cc) now
    setRecoveryBlock tvar (ccName cc) now (fdcRecoveryBlockPeriod fdc)
    mapM_ (\ns -> updateNodeState tvar (ccName cc) (ns { nsIsSource = False })) oldSources

promoteCandidate :: Text -> Text -> NodeId -> Int -> Logger -> Text -> IO (Either Text ())
promoteCandidate user password nid waitTimeout logger clusterName = do
  let ci = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    caughtUp <- waitForRelayLogApply conn waitTimeout
    if caughtUp
      then logInfo logger $ "[" <> clusterName <> "] Relay log apply completed on " <> nodeHost nid
      else logError logger $ "[" <> clusterName <> "] WARNING: Relay log apply timed out on " <> nodeHost nid <> ", proceeding with promotion"
    stopReplica conn
    resetReplicaAll conn
    setReadWrite conn
  pure $ case result of
    Left err -> Left err
    Right () -> Right ()

reconnectReplica :: Text -> Text -> Text -> Text -> NodeId -> NodeState -> IO ()
reconnectReplica user monPassword replUser replPassword newSourceId ns = do
  let ci = makeConnectInfo (nsNodeId ns) user monPassword
  _ <- withNodeConn ci $ \conn -> do
    stopReplica conn
    changeReplicationSourceTo conn (nodeHost newSourceId) (nodePort newSourceId) replUser replPassword
    setReadOnly conn
    startReplica conn
  pure ()


