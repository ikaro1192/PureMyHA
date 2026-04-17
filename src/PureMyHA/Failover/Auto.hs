module PureMyHA.Failover.Auto
  ( runAutoFailover
  , runAutoFence
  , doUnfence
  , checkAutoFailoverPreconditions
  , simulateFailover
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forM_, void)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks, runReaderT)
import Control.Monad.Trans.Class (lift)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Candidate (selectCandidate, selectSurvivor, rankCandidates, CandidateInfo (..))
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..), SourceChange (..) )
import PureMyHA.Logger (logInfo, logError)
import PureMyHA.Supervisor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn, withNodeConnRetry)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

-- | Local helper: build a SourceChange from an optional old host and a new host.
mkSourceChangeAuto :: Maybe HostInfo -> HostInfo -> SourceChange
mkSourceChangeAuto Nothing     newH = InitialSourcePromotion newH
mkSourceChangeAuto (Just oldH) newH = SourceChanged oldH newH

-- | Simulate failover: report what would happen if the source died right now.
-- The pause flag is an operational constraint shown as a note; structural
-- preconditions (health state, recovery block, replica count) are always checked.
simulateFailover :: App (Either Text Text)
simulateFailover = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      now <- liftIO getCurrentTime
      let healthDesc    = "Current health: " <> T.pack (show (ctHealth topo))
          pauseNote     = case ctPaused topo of
                            Paused  -> ["Note: auto-failover is currently paused by operator"]
                            Running -> []
          -- Check structural preconditions, bypassing the pause flag and health
          -- state since simulate-failover asks "what if the source died now?"
          precondResult = checkAutoFailoverPreconditions now
                            (topo { ctPaused = Running, ctHealth = DeadSource })
                            (fcMinReplicasForFailover fc)
          mCandidates   = rankCandidates (fcNeverPromote fc)
                            (fmap unPositiveInt (fcMaxReplicaLagForCandidate fc))
                            (Map.elems (ctNodes topo))
                            (fcCandidatePriority fc)
      case precondResult of
        Left err -> pure . Right . T.unlines $
          [healthDesc] ++ pauseNote ++ ["Preconditions: FAIL \x2014 " <> err]
        Right () ->
          case mCandidates of
            Nothing -> pure . Right . T.unlines $
              [healthDesc] ++ pauseNote ++ ["Preconditions: OK", "No suitable failover candidate found"]
            Just cs ->
              let candLines = map (\ci -> "  - " <> unHostName (nodeHost (ciNodeId ci))) (NE.toList cs)
              in pure . Right . T.unlines $
                [ healthDesc] ++ pauseNote ++
                [ "Preconditions: OK"
                , "Would promote: " <> unHostName (nodeHost (ciNodeId (NE.head cs)))
                , "All eligible candidates (ranked):"
                ] ++ candLines

-- | Execute automatic failover for a cluster. The failover lock is released
-- on every exit path from 'doFailover' (including synchronous and asynchronous
-- exceptions) via 'withFailoverLock'.
runAutoFailover :: App (Either Text ())
runAutoFailover = do
  env  <- ask
  lock <- asks envLock
  mResult <- liftIO $ withFailoverLock lock (runReaderT doFailover env)
  pure $ case mResult of
    Nothing -> Left "Failover already in progress"
    Just r  -> r

-- | Check preconditions for auto failover (pure)
checkAutoFailoverPreconditions
  :: UTCTime
  -> ClusterTopology
  -> Int               -- ^ fcMinReplicasForFailover
  -> Either Text ()
checkAutoFailoverPreconditions now topo minReplicas = do
  case ctPaused topo of
    Paused  -> Left "Failover paused by operator (pause-failover)"
    Running -> Right ()
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
    case selectCandidate (fcNeverPromote fc) (fmap unPositiveInt (fcMaxReplicaLagForCandidate fc)) (ctNodes topo) (fcCandidatePriority fc) Nothing of
      Left err -> do
        appLogError (prefix <> "Auto-failover failed: " <> err)
        pure (Left err)
      Right c -> pure (Right c)
  let oldSourceHost = fmap nodeHostInfo (ctSourceNodeId topo)
      waitTimeout   = truncate (fcWaitRelayLogTimeout fc) :: Int
  ExceptT $ runPreFailoverHook candidateId oldSourceHost
  lift $ appLogInfo $ prefix <> "Waiting for relay log apply on " <> unHostName (nodeHost candidateId) <> "..."
  ExceptT $ promoteWithOnFailureHook candidateId waitTimeout oldSourceHost
  lift $ reconnectOtherReplicas candidateId topo
  now <- liftIO getCurrentTime
  lift $ commitFailoverState candidateId topo now
  ts <- liftIO getCurrentTimestamp
  mHooks <- lift getHooksConfig
  let postEnv = HookEnv { hookClusterName  = ccName cc
                        , hookSourceChange = mkSourceChangeAuto oldSourceHost (nodeHostInfo candidateId)
                        , hookFailureType  = Just "DeadSource"
                        , hookTimestamp    = ts
                        , hookLagSeconds   = Nothing
                        , hookNode         = Nothing
                        , hookDriftType    = Nothing
                        , hookDriftDetails = Nothing
                        }
  liftIO $ runHookFireForget mHooks hcPostFailover postEnv
  lift $ appLogInfo $ prefix <> "Auto-failover completed: new source is " <> unHostName (nodeHost candidateId)

runPreFailoverHook :: NodeId -> Maybe HostInfo -> App (Either Text ())
runPreFailoverHook candidateId oldSourceHost = do
  cc     <- asks envCluster
  mHooks <- getHooksConfig
  ts <- liftIO getCurrentTimestamp
  let preEnv = HookEnv { hookClusterName  = ccName cc
                       , hookSourceChange = mkSourceChangeAuto oldSourceHost (nodeHostInfo candidateId)
                       , hookFailureType  = Just "DeadSource"
                       , hookTimestamp    = ts
                       , hookLagSeconds   = Nothing
                       , hookNode         = Nothing
                       , hookDriftType    = Nothing
                       , hookDriftDetails = Nothing
                       }
  preResult <- liftIO $ runHookOrAbort mHooks hcPreFailover preEnv
  case preResult of
    Left err -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Pre-failover hook aborted failover: " <> err
      pure (Left $ "Pre-failover hook failed: " <> err)
    Right () -> pure (Right ())

promoteWithOnFailureHook :: NodeId -> Int -> Maybe HostInfo -> App (Either Text ())
promoteWithOnFailureHook candidateId waitTimeout oldSourceHost = do
  clusterName <- getClusterName
  promoteResult <- promoteCandidate candidateId waitTimeout
  case promoteResult of
    Left err -> do
      appLogError $ "[" <> unClusterName clusterName <> "] Auto-failover failed: Promote failed: " <> err
      ts <- liftIO getCurrentTimestamp
      mHooks <- getHooksConfig
      let failEnv = HookEnv { hookClusterName  = clusterName
                             , hookSourceChange = mkSourceChangeAuto oldSourceHost (nodeHostInfo candidateId)
                             , hookFailureType  = Just "PromoteFailed"
                             , hookTimestamp    = ts
                             , hookLagSeconds   = Nothing
                             , hookNode         = Nothing
                             , hookDriftType    = Nothing
                             , hookDriftDetails = Nothing
                             }
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
  fdc  <- asks envDetection
  queue <- asks envEventQueue
  let oldSources = filter isSource (Map.elems (ctNodes topo))
      recoveryDeadline = addUTCTime (fdcRecoveryBlockPeriod fdc) now
  liftIO $ atomically $ writeTBQueue queue $
    FailoverCommitted candidateId (map nsNodeId oldSources) now recoveryDeadline

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
        then logInfo logger $ "[" <> unClusterName clusterName <> "] Relay log apply completed on " <> unHostName (nodeHost nid)
        else logError logger $ "[" <> unClusterName clusterName <> "] WARNING: Relay log apply timed out on " <> unHostName (nodeHost nid) <> ", proceeding with promotion"
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
  liftIO $ void $ withNodeConn mTls ci $ \conn -> do
    stopReplica conn
    changeReplicationSourceTo conn (unHostName (nodeHost newSourceId)) (unPort (nodePort newSourceId)) replCreds mTls
    setReadOnly conn
    startReplica conn

-- | Entry point for auto-fence on SplitBrainSuspected.
-- Reuses envLock to prevent concurrent fence/failover operations. The lock is
-- released on every exit path from 'doAutoFence' via 'withFailoverLock'.
runAutoFence :: App ()
runAutoFence = do
  env  <- ask
  lock <- asks envLock
  mResult <- liftIO $ withFailoverLock lock (runReaderT doAutoFence env)
  case mResult of
    Nothing -> appLogInfo "Auto-fence skipped: failover/fence operation already in progress"
    Just () -> pure ()

-- | Fence all source-role nodes except the one with the highest GTID count.
doAutoFence :: App ()
doAutoFence = do
  -- Wait 2 probe cycles for GTID data to settle before comparing.
  -- The probe that triggered the SplitBrainSuspected transition may have captured
  -- GTID counts before recent writes landed; a short wait ensures fresh data.
  mc <- liftIO . readTVarIO =<< asks envMonitoring
  liftIO $ threadDelay (round (unPositiveDuration (mcInterval mc) * 2 * 1_000_000))
  clusterName <- getClusterName
  fc          <- asks envFailover
  let prefix = "[" <> unClusterName clusterName <> "] "
  tv    <- asks envDaemonState
  mTopo <- liftIO (getClusterTopology tv clusterName)
  case mTopo of
    Nothing -> appLogError $ prefix <> "Auto-fence: cluster not found"
    Just topo -> do
      let sources = filter isSource (Map.elems (ctNodes topo))
          unfenced = filter (\ns -> case nsFenced ns of Unfenced -> True; Fenced -> False) sources
      case unfenced of
        []  -> pure ()  -- all already fenced or no sources
        _   -> do
          let priorities = fcCandidatePriority fc
              mSurvivorId = selectSurvivor (fcNeverPromote fc) priorities sources
          case mSurvivorId of
            Nothing -> appLogError $ prefix <> "Auto-fence: no survivor could be selected"
            Just survivorId -> do
              let toFence = filter (\ns -> nsNodeId ns /= survivorId) unfenced
                  survivorHI = nodeHostInfo survivorId
              appLogInfo $ prefix <> "Auto-fence: split-brain detected, survivor=" <> unHostName (hiHostName survivorHI)
                        <> ", fencing " <> T.pack (show (length toFence)) <> " node(s)"
              forM_ toFence $ \ns -> fenceNode clusterName survivorHI ns

-- | Apply super_read_only to a single node and record fenced state.
fenceNode :: ClusterName -> HostInfo -> NodeState -> App ()
fenceNode clusterName survivorHost ns = do
  creds  <- getMonCredentials
  mTls   <- getTLSConfig
  mHooks <- getHooksConfig
  mc     <- liftIO . readTVarIO =<< asks envMonitoring
  let nid    = nsNodeId ns
      ci     = makeConnectInfo nid creds
      prefix = "[" <> unClusterName clusterName <> "] "
      cap    = unPositiveDuration (mcConnectTimeout mc)
  queue  <- asks envEventQueue
  result <- liftIO $ withNodeConnRetry 1 0 cap (const (pure ())) mTls ci setSuperReadOnly
  case result of
    Left err ->
      appLogError $ prefix <> "Auto-fence failed on " <> unHostName (nodeHost nid) <> ": " <> err
    Right () -> do
      liftIO $ atomically $ writeTBQueue queue (NodeFenced nid)
      appLogInfo $ prefix <> "Auto-fence: " <> unHostName (nodeHost nid) <> " fenced (super_read_only=ON)"
      ts <- liftIO getCurrentTimestamp
      let hookEnv = HookEnv { hookClusterName  = clusterName
                             , hookSourceChange = SourceChanged (nodeHostInfo nid) survivorHost
                             , hookFailureType  = Nothing
                             , hookTimestamp    = ts
                             , hookLagSeconds   = Nothing
                             , hookNode         = Nothing
                             , hookDriftType    = Nothing
                             , hookDriftDetails = Nothing
                             }
      liftIO $ runHookFireForget mHooks hcOnFence hookEnv

-- | Unfence a node: clear super_read_only and reset fenced state in STM.
doUnfence :: HostName -> App (Either Text ())
doUnfence host = do
  clusterName <- getClusterName
  tvar        <- asks envDaemonState
  queue       <- asks envEventQueue
  mTopo <- liftIO $ getClusterTopology tvar clusterName
  let prefix = "[" <> unClusterName clusterName <> "] "
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case findNodeByHost host (ctNodes topo) of
        Nothing -> pure (Left $ "Host not found in cluster: " <> unHostName host)
        Just ns -> do
          creds <- getMonCredentials
          mTls  <- getTLSConfig
          let ci = makeConnectInfo (nsNodeId ns) creds
          result <- liftIO $ withNodeConn mTls ci clearSuperReadOnly
          case result of
            Left err -> do
              appLogError $ prefix <> "Unfence failed on " <> unHostName host <> ": " <> err
              pure (Left $ "Unfence failed: " <> err)
            Right () -> do
              liftIO $ atomically $ writeTBQueue queue (NodeUnfenced (nsNodeId ns))
              appLogInfo $ prefix <> "Unfenced " <> unHostName host
                        <> " (super_read_only cleared). WARNING: verify data consistency before resuming writes."
              pure (Right ())
