module PureMyHA.Failover.Switchover
  ( runSwitchover
  , dryRunSwitchover
  , switchoverReconnectTargets
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, writeTBQueue)
import Control.Exception (try, SomeException)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Class (lift)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Database.MySQL.Base (ConnectInfo)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.Monitor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (GtidSet)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

maxWaitSeconds :: Int
maxWaitSeconds = 60

-- | Nodes to reconnect after switchover: all nodes except the new source (pure)
switchoverReconnectTargets
  :: Map NodeId NodeState
  -> NodeId             -- ^ candidateId (promoted, excluded from result)
  -> [NodeState]
switchoverReconnectTargets nodes candidateId =
  filter (\ns -> nsNodeId ns /= candidateId) (Map.elems nodes)

-- | Execute a manual switchover
runSwitchover
  :: Maybe HostName    -- ^ --to host
  -> Maybe Int         -- ^ --drain-timeout seconds (Nothing = no drain)
  -> App (Either Text ())
runSwitchover mToHost mDrainTimeout = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo ->
      case selectCandidate (fcNeverPromote fc) (fmap unPositiveInt (fcMaxReplicaLagForCandidate fc)) (ctNodes topo) (fcCandidatePriority fc) mToHost of
        Left err -> do
          appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: " <> err
          pure (Left err)
        Right candidateId -> do
          let oldSourceId   = ctSourceNodeId topo
              oldSourceHost = fmap nodeHostInfo oldSourceId

          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Switchover started"

          -- Pre-switchover hook (blocking: non-zero exit aborts)
          mHooks <- getHooksConfig
          ts <- liftIO getCurrentTimestamp
          let preEnv = HookEnv { hookClusterName  = ccName cc
                               , hookNewSource    = Just (nodeHostInfo candidateId)
                               , hookOldSource    = oldSourceHost
                               , hookFailureType  = Nothing
                               , hookTimestamp    = ts
                               , hookLagSeconds   = Nothing
                               , hookNode         = Nothing
                               , hookDriftType    = Nothing
                               , hookDriftDetails = Nothing
                               }
          preResult <- liftIO $ runHookOrAbort mHooks hcPreSwitchover preEnv
          case preResult of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] Pre-switchover hook aborted: " <> err
              pure (Left $ "Pre-switchover hook failed: " <> err)
            Right () ->
              doSwitchover candidateId oldSourceId oldSourceHost topo mDrainTimeout

doSwitchover
  :: NodeId
  -> Maybe NodeId
  -> Maybe HostInfo
  -> ClusterTopology
  -> Maybe Int         -- ^ drain timeout seconds
  -> App (Either Text ())
doSwitchover candidateId oldSourceId oldSourceHost topo mDrainTimeout = runExceptT $ do
  cc    <- lift $ asks envCluster
  creds <- lift getMonCredentials
  mTls  <- lift getTLSConfig
  let clName = ccName cc

  ExceptT $ freezeOldSource oldSourceId mDrainTimeout mTls creds clName
  mOldGtid <- lift $ getSourceGtid oldSourceId mTls creds
  ExceptT $ promoteCandidate candidateId mOldGtid mTls creds clName
  lift $ finalizeSwitchover candidateId oldSourceId oldSourceHost topo

-- | Set old source to read_only and drain user connections
freezeOldSource
  :: Maybe NodeId -> Maybe Int -> Maybe TLSConfig -> DbCredentials
  -> ClusterName -> App (Either Text ())
freezeOldSource Nothing _ _ _ _ = pure (Right ())
freezeOldSource (Just srcId) mDrainTimeout mTls creds clName = do
  let srcCi = makeConnectInfo srcId creds
  readOnlyResult <- liftIO $ withNodeConn mTls srcCi setReadOnly
  case readOnlyResult of
    Left err -> do
      appLogError $ "[" <> unClusterName clName <> "] Switchover aborted: cannot set old source read_only: " <> err
      pure (Left $ "Cannot set old source read_only: " <> err)
    Right () -> do
      case mDrainTimeout of
        Just secs | secs > 0 -> waitThenKill mTls srcCi clName secs
        _                    -> pure ()
      pure (Right ())

-- | Get GTID executed set from old source (returns Nothing on failure)
getSourceGtid
  :: Maybe NodeId -> Maybe TLSConfig -> DbCredentials
  -> App (Maybe GtidSet)
getSourceGtid Nothing _ _ = pure Nothing
getSourceGtid (Just srcId) mTls creds = do
  let srcCi = makeConnectInfo srcId creds
  result <- liftIO $ withNodeConn mTls srcCi getGtidExecuted
  pure $ case result of
    Right gtid -> Just gtid
    Left _     -> Nothing

-- | Wait for candidate to catch up, then promote it
promoteCandidate
  :: NodeId -> Maybe GtidSet -> Maybe TLSConfig -> DbCredentials
  -> ClusterName -> App (Either Text ())
promoteCandidate candidateId mOldGtid mTls creds clName = do
  let candidateCi = makeConnectInfo candidateId creds
  caught <- liftIO $ waitForCatchup mTls candidateCi mOldGtid maxWaitSeconds
  if not caught
    then do
      appLogError $ "[" <> unClusterName clName <> "] Switchover failed: Candidate did not catch up within timeout"
      pure (Left "Candidate did not catch up within timeout")
    else do
      promoteResult <- liftIO $ withNodeConn mTls candidateCi $ \conn -> do
        stopReplica conn
        resetReplicaAll conn
        setReadWrite conn
      case promoteResult of
        Left err -> do
          appLogError $ "[" <> unClusterName clName <> "] Switchover failed: Promote failed: " <> err
          pure (Left $ "Promote failed: " <> err)
        Right () -> pure (Right ())

-- | Update topology roles, reconnect replicas, and fire post-switchover hook
finalizeSwitchover
  :: NodeId -> Maybe NodeId -> Maybe HostInfo -> ClusterTopology
  -> App ()
finalizeSwitchover candidateId oldSourceId oldSourceHost topo = do
  cc    <- asks envCluster
  queue <- asks envEventQueue
  let clName = ccName cc

  -- Emit switchover event — reducer handles the role swap atomically
  liftIO $ atomically $ writeTBQueue queue (SwitchoverCommitted candidateId oldSourceId)

  -- Reconnect remaining replicas (including old source)
  let others = switchoverReconnectTargets (ctNodes topo) candidateId
  mapM_ (reconnectToNew candidateId) others

  -- Post-switchover hook (fire-and-forget)
  mHooks <- getHooksConfig
  ts <- liftIO getCurrentTimestamp
  let postEnv = HookEnv { hookClusterName  = clName
                        , hookNewSource    = Just (nodeHostInfo candidateId)
                        , hookOldSource    = oldSourceHost
                        , hookFailureType  = Nothing
                        , hookTimestamp    = ts
                        , hookLagSeconds   = Nothing
                        , hookNode         = Nothing
                        , hookDriftType    = Nothing
                        , hookDriftDetails = Nothing
                        }
  liftIO $ runHookFireForget mHooks hcPostSwitchover postEnv

  appLogInfo $ "[" <> unClusterName clName <> "] Switchover completed: new source is " <> unHostName (nodeHost candidateId)

waitForCatchup :: Maybe TLSConfig -> ConnectInfo -> Maybe GtidSet -> Int -> IO Bool
waitForCatchup _ _ Nothing _ = pure True
waitForCatchup mTls ci (Just targetGtid) secondsLeft
  | secondsLeft <= 0 = pure False
  | otherwise = do
      result <- withNodeConn mTls ci $ \conn -> do
        mRs <- showReplicaStatus conn
        case mRs of
          Nothing -> pure True
          Just rs -> gtidSubset conn targetGtid (rsExecutedGtidSet rs)
      case result of
        Left _      -> do
          threadDelay 1_000_000
          waitForCatchup mTls ci (Just targetGtid) (secondsLeft - 1)
        Right True  -> pure True
        Right False -> do
          threadDelay 1_000_000
          waitForCatchup mTls ci (Just targetGtid) (secondsLeft - 1)

reconnectToNew :: NodeId -> NodeState -> App ()
reconnectToNew newSourceId ns = do
  monCreds  <- getMonCredentials
  replCreds <- getReplCredentials
  mTls      <- getTLSConfig
  let ci = makeConnectInfo (nsNodeId ns) monCreds
  liftIO $ do
    _ <- withNodeConn mTls ci $ \conn -> do
      _ <- try @SomeException (stopReplica conn)
      changeReplicationSourceTo conn (unHostName (nodeHost newSourceId)) (nodePort newSourceId) replCreds mTls
      setReadOnly conn
      startReplica conn
    pure ()

-- | Wait up to timeoutSecs for user connections to close, then KILL remaining ones.
-- Polls SHOW PROCESSLIST every second. If connection to old source is lost, proceeds silently.
waitThenKill
  :: Maybe TLSConfig
  -> ConnectInfo
  -> ClusterName
  -> Int            -- ^ timeout seconds (>0)
  -> App ()
waitThenKill mTls srcCi clusterName timeoutSecs = go timeoutSecs
  where
    go secsLeft = do
      result <- liftIO $ withNodeConn mTls srcCi showProcessList
      case result of
        Left _ -> pure ()  -- can't connect to old source; proceed
        Right procs -> do
          let userProcs = filter isUserProcess procs
          if null userProcs
            then pure ()
            else if secsLeft <= 0
              then do
                appLogInfo $ "[" <> unClusterName clusterName <> "] Killing "
                  <> T.pack (show (length userProcs)) <> " remaining connection(s)"
                _ <- liftIO $ withNodeConn mTls srcCi $ \conn ->
                  mapM_ (killConnection conn . piId) userProcs
                pure ()
              else do
                appLogInfo $ "[" <> unClusterName clusterName <> "] Draining connections: "
                  <> T.pack (show (length userProcs)) <> " remaining"
                liftIO $ threadDelay 1_000_000
                go (secsLeft - 1)

-- | Dry-run switchover: validate and select candidate without executing SQL
dryRunSwitchover
  :: Maybe HostName      -- ^ --to host
  -> App (Either Text Text)
dryRunSwitchover mToHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing   -> pure (Left "Cluster not found")
    Just topo ->
      case selectCandidate (fcNeverPromote fc) (fmap unPositiveInt (fcMaxReplicaLagForCandidate fc)) (ctNodes topo) (fcCandidatePriority fc) mToHost of
        Left  err         -> pure (Left err)
        Right candidateId ->
          pure (Right ("Dry run: would promote " <> unHostName (nodeHost candidateId) <> " to source"))
