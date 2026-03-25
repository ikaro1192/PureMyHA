module PureMyHA.Failover.Auto
  ( runAutoFailover
  , runAutoFence
  , doUnfence
  , checkAutoFailoverPreconditions
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forM_, when)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Class (lift)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Candidate (selectCandidate, selectSurvivor)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.Logger (logInfo, logError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn, withNodeConnRetry)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

-- | Execute automatic failover for a cluster
runAutoFailover :: App (Either Text ())
runAutoFailover = do
  lock <- asks envLock
  acquired <- liftIO $ atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> pure (Left "Failover already in progress")
    Just () -> do
      result <- doFailover
      liftIO $ atomically $ putTMVar lock ()
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
  let replicas = filter (not . isSource) (Map.elems (ctNodes topo))
  if length replicas < minReplicas
    then Left $ "Not enough replicas for failover (need " <> T.pack (show minReplicas) <> ")"
    else Right ()

doFailover :: App (Either Text ())
doFailover = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Auto-failover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo -> do
      now <- liftIO getCurrentTime
      case checkAutoFailoverPreconditions now topo (fcMinReplicasForFailover fc) of
        Left err -> do
          appLogError $ "[" <> unClusterName (ccName cc) <> "] Auto-failover failed: " <> err
          pure (Left err)
        Right () -> do
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Auto-failover started"
          executeFailover topo

executeFailover :: ClusterTopology -> App (Either Text ())
executeFailover topo = runExceptT $ do
  cc <- lift $ asks envCluster
  fc <- lift $ asks envFailover
  let prefix = "[" <> unClusterName (ccName cc) <> "] "
  candidateId <- ExceptT $ do
    case selectCandidate (ctNodes topo) (fcCandidatePriority fc) Nothing of
      Left err -> do
        appLogError (prefix <> "Auto-failover failed: " <> err)
        pure (Left err)
      Right c -> pure (Right c)
  let oldSourceHost = fmap nodeHost (ctSourceNodeId topo)
      waitTimeout   = truncate (fcWaitRelayLogTimeout fc) :: Int
  ExceptT $ runPreFailoverHook candidateId oldSourceHost
  lift $ appLogInfo $ prefix <> "Waiting for relay log apply on " <> nodeHost candidateId <> "..."
  ExceptT $ promoteWithOnFailureHook candidateId waitTimeout oldSourceHost
  lift $ reconnectOtherReplicas candidateId topo
  now <- liftIO getCurrentTime
  lift $ commitFailoverState candidateId topo now
  ts <- liftIO getCurrentTimestamp
  mHooks <- lift getHooksConfig
  let postEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  liftIO $ runHookFireForget mHooks hcPostFailover postEnv
  lift $ appLogInfo $ prefix <> "Auto-failover completed: new source is " <> nodeHost candidateId

runPreFailoverHook :: NodeId -> Maybe Text -> App (Either Text ())
runPreFailoverHook candidateId oldSourceHost = do
  cc     <- asks envCluster
  mHooks <- getHooksConfig
  ts <- liftIO getCurrentTimestamp
  let preEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  preResult <- liftIO $ runHookOrAbort mHooks hcPreFailover preEnv
  case preResult of
    Left err -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Pre-failover hook aborted failover: " <> err
      pure (Left $ "Pre-failover hook failed: " <> err)
    Right () -> pure (Right ())

promoteWithOnFailureHook :: NodeId -> Int -> Maybe Text -> App (Either Text ())
promoteWithOnFailureHook candidateId waitTimeout oldSourceHost = do
  clusterName <- getClusterName
  promoteResult <- promoteCandidate candidateId waitTimeout
  case promoteResult of
    Left err -> do
      appLogError $ "[" <> unClusterName clusterName <> "] Auto-failover failed: Promote failed: " <> err
      ts <- liftIO getCurrentTimestamp
      mHooks <- getHooksConfig
      let failEnv = HookEnv clusterName (Just (nodeHost candidateId)) oldSourceHost (Just "PromoteFailed") ts
      liftIO $ runHookFireForget mHooks hcPostUnsuccessfulFailover failEnv
      pure (Left $ "Promote failed: " <> err)
    Right () -> pure (Right ())

reconnectOtherReplicas :: NodeId -> ClusterTopology -> App ()
reconnectOtherReplicas candidateId topo = do
  let otherReplicas = filter
        (\ns -> nsNodeId ns /= candidateId && not (isSource ns))
        (Map.elems (ctNodes topo))
  mapM_ (reconnectReplica candidateId) otherReplicas

commitFailoverState :: NodeId -> ClusterTopology -> UTCTime -> App ()
commitFailoverState candidateId topo now = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fdc  <- asks envDetection
  let oldSources = filter isSource (Map.elems (ctNodes topo))
      candidate  = Map.lookup candidateId (ctNodes topo)
  liftIO $ atomically $ do
    recordFailover tvar (ccName cc) now
    setRecoveryBlock tvar (ccName cc) now (fdcRecoveryBlockPeriod fdc)
    mapM_ (\ns -> updateNodeState tvar (ccName cc) (ns { nsRole = Replica })) oldSources
    case candidate of
      Just ns -> updateNodeState tvar (ccName cc) (ns { nsRole = Source })
      Nothing -> pure ()

promoteCandidate :: NodeId -> Int -> App (Either Text ())
promoteCandidate nid waitTimeout = do
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  clusterName <- getClusterName
  logger <- asks envLogger >>= liftIO . readTVarIO
  let ci = makeConnectInfo nid creds
  liftIO $ do
    result <- withNodeConn mTls ci $ \conn -> do
      caughtUp <- waitForRelayLogApply conn waitTimeout
      if caughtUp
        then logInfo logger $ "[" <> unClusterName clusterName <> "] Relay log apply completed on " <> nodeHost nid
        else logError logger $ "[" <> unClusterName clusterName <> "] WARNING: Relay log apply timed out on " <> nodeHost nid <> ", proceeding with promotion"
      stopReplica conn
      resetReplicaAll conn
      setReadWrite conn
    pure $ case result of
      Left err -> Left err
      Right () -> Right ()

reconnectReplica :: NodeId -> NodeState -> App ()
reconnectReplica newSourceId ns = do
  monCreds  <- getMonCredentials
  replCreds <- getReplCredentials
  mTls      <- getTLSConfig
  let ci = makeConnectInfo (nsNodeId ns) monCreds
  liftIO $ do
    _ <- withNodeConn mTls ci $ \conn -> do
      stopReplica conn
      changeReplicationSourceTo conn (nodeHost newSourceId) (nodePort newSourceId) replCreds
      setReadOnly conn
      startReplica conn
    pure ()

-- | Entry point for auto-fence on SplitBrainSuspected.
-- Reuses envLock to prevent concurrent fence/failover operations.
runAutoFence :: App ()
runAutoFence = do
  lock <- asks envLock
  acquired <- liftIO $ atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> appLogInfo "Auto-fence skipped: failover/fence operation already in progress"
    Just () -> do
      doAutoFence
      liftIO $ atomically $ putTMVar lock ()

-- | Fence all source-role nodes except the one with the highest GTID count.
doAutoFence :: App ()
doAutoFence = do
  -- Wait 2 probe cycles for GTID data to settle before comparing.
  -- The probe that triggered the SplitBrainSuspected transition may have captured
  -- GTID counts before recent writes landed; a short wait ensures fresh data.
  mc <- liftIO . readTVarIO =<< asks envMonitoring
  liftIO $ threadDelay (round (mcInterval mc * 2 * 1_000_000))
  clusterName <- getClusterName
  fc          <- asks envFailover
  let prefix = "[" <> unClusterName clusterName <> "] "
  mTopo <- asks envDaemonState >>= \tv -> liftIO (getClusterTopology tv clusterName)
  case mTopo of
    Nothing -> appLogError $ prefix <> "Auto-fence: cluster not found"
    Just topo -> do
      let sources = filter isSource (Map.elems (ctNodes topo))
          unfenced = filter (not . nsFenced) sources
      case unfenced of
        []  -> pure ()  -- all already fenced or no sources
        _   -> do
          let priorities = fcCandidatePriority fc
              mSurvivorId = selectSurvivor priorities sources
          case mSurvivorId of
            Nothing -> appLogError $ prefix <> "Auto-fence: no survivor could be selected"
            Just survivorId -> do
              let toFence = filter (\ns -> nsNodeId ns /= survivorId) unfenced
                  survivorHost = nodeHost survivorId
              appLogInfo $ prefix <> "Auto-fence: split-brain detected, survivor=" <> survivorHost
                        <> ", fencing " <> T.pack (show (length toFence)) <> " node(s)"
              forM_ toFence $ \ns -> fenceNode clusterName survivorHost ns

-- | Apply super_read_only to a single node and record fenced state.
fenceNode :: ClusterName -> Text -> NodeState -> App ()
fenceNode clusterName survivorHost ns = do
  creds  <- getMonCredentials
  mTls   <- getTLSConfig
  tvar   <- asks envDaemonState
  mHooks <- getHooksConfig
  mc     <- liftIO . readTVarIO =<< asks envMonitoring
  let nid    = nsNodeId ns
      ci     = makeConnectInfo nid creds
      prefix = "[" <> unClusterName clusterName <> "] "
      cap    = mcConnectTimeout mc
  result <- liftIO $ withNodeConnRetry 1 0 cap (const (pure ())) mTls ci setSuperReadOnly
  case result of
    Left err ->
      appLogError $ prefix <> "Auto-fence failed on " <> nodeHost nid <> ": " <> err
    Right () -> do
      liftIO $ atomically $ updateNodeState tvar clusterName (ns { nsFenced = True })
      appLogInfo $ prefix <> "Auto-fence: " <> nodeHost nid <> " fenced (super_read_only=ON)"
      ts <- liftIO getCurrentTimestamp
      let hookEnv = HookEnv clusterName (Just survivorHost) (Just (nodeHost nid)) Nothing ts
      liftIO $ runHookFireForget mHooks hcOnFence hookEnv

-- | Unfence a node: clear super_read_only and reset fenced state in STM.
doUnfence :: Text -> App (Either Text ())
doUnfence host = do
  clusterName <- getClusterName
  tvar        <- asks envDaemonState
  mTopo <- liftIO $ getClusterTopology tvar clusterName
  let prefix = "[" <> unClusterName clusterName <> "] "
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case findNodeByHost host (ctNodes topo) of
        Nothing -> pure (Left $ "Host not found in cluster: " <> host)
        Just ns -> do
          creds <- getMonCredentials
          mTls  <- getTLSConfig
          let ci = makeConnectInfo (nsNodeId ns) creds
          result <- liftIO $ withNodeConn mTls ci clearSuperReadOnly
          case result of
            Left err -> do
              appLogError $ prefix <> "Unfence failed on " <> host <> ": " <> err
              pure (Left $ "Unfence failed: " <> err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar clusterName (ns { nsFenced = False })
              appLogInfo $ prefix <> "Unfenced " <> host
                        <> " (super_read_only cleared). WARNING: verify data consistency before resuming writes."
              pure (Right ())
