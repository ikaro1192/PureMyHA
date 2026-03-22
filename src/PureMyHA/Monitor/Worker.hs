module PureMyHA.Monitor.Worker
  ( startMonitorWorkers
  , startTopologyRefreshWorker
  , WorkerRegistry
  , monitorNode
  , runWorker
  , suppressBelowThreshold
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait, Async)
import Control.Concurrent.STM (atomically, TVar, newTVarIO, modifyTVar', readTVarIO)
import Control.Exception (SomeException, catch)
import Control.Monad (when, forM, forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Auto (runAutoFailover)
import PureMyHA.Hook (runHookFireForget, getCurrentTimestamp, HookEnv (..))
import PureMyHA.Logger (logDebug, logInfo, logWarn)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn, withNodeConnRetry)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.Discovery (discoverTopology)
import PureMyHA.Topology.State
import PureMyHA.Types
import PureMyHA.Monitor.Detector (detectClusterHealth, detectNodeHealth, identifySource)

type WorkerRegistry = TVar (Map.Map NodeId (Async ()))

-- | Start one async monitor worker per node in a cluster; also returns registry
startMonitorWorkers :: App (WorkerRegistry, [Async ()])
startMonitorWorkers = do
  env <- ask
  let nodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes (envCluster env))
  liftIO $ do
    reg <- newTVarIO Map.empty
    asyncs <- forM nodes $ \nid -> do
      a <- async (runApp env (runWorker nid))
      atomically $ modifyTVar' reg (Map.insert nid a)
      pure a
    pure (reg, asyncs)

runWorker :: NodeId -> App ()
runWorker nid = do
  env <- ask
  liftIO $ loop env
  where
    loop env = do
      mc <- readTVarIO (envMonitoring env)
      let intervalMicros = round (mcInterval mc * 1_000_000) :: Int
      runApp env (monitorNode nid)
        `catch` (\(_ :: SomeException) -> pure ())
      threadDelay intervalMicros
      loop env

-- | Start the topology refresh worker for a cluster
startTopologyRefreshWorker :: WorkerRegistry -> App (Async ())
startTopologyRefreshWorker reg = do
  env <- ask
  liftIO $ async (runApp env (topologyRefreshLoop reg))

topologyRefreshLoop :: WorkerRegistry -> App ()
topologyRefreshLoop reg = do
  env <- ask
  liftIO $ loop env
  where
    loop env = do
      mc <- readTVarIO (envMonitoring env)
      let interval = mcDiscoveryInterval mc
      if interval <= 0
        then threadDelay 60_000_000  -- disabled: check every 60s in case config reloads
        else do
          threadDelay (round (interval * 1_000_000) :: Int)
          runApp env (runTopologyRefresh reg)
            `catch` (\(_ :: SomeException) -> pure ())
      loop env

runTopologyRefresh :: WorkerRegistry -> App ()
runTopologyRefresh reg = do
  env <- ask
  let cc   = envCluster env
      tvar = envDaemonState env
  newTopo <- discoverTopology
  mOldTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  let mergedTopo = case mOldTopo of
        Nothing      -> newTopo
        Just oldTopo ->
          newTopo { ctNodes = Map.union (ctNodes newTopo) (ctNodes oldTopo) }
  liftIO $ atomically $ updateClusterTopology tvar mergedTopo
  knownNodes <- liftIO $ Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes mergedTopo)
      newNodes   = Set.toList (Set.difference discovered knownNodes)
  unless (null newNodes) $
    appLogInfo $ "[" <> ccName cc <> "] Topology refresh: "
      <> T.pack (show (length newNodes)) <> " new node(s) found"
  liftIO $ forM_ newNodes $ \nid -> do
    a <- async (runApp env (runWorker nid))
    atomically $ modifyTVar' reg (Map.insert nid a)

-- | Suppress NeedsAttention health state when consecutive failure count is below
-- the configured threshold. Falls back to previous health (or Healthy if no prior state).
suppressBelowThreshold :: Int -> Int -> Maybe NodeState -> NodeState -> NodeState
suppressBelowThreshold threshold failCount mOldNs ns
  | failCount > 0 && failCount < threshold =
      ns { nsHealth = maybe Healthy nsHealth mOldNs }
  | otherwise = ns

-- | Perform a single monitoring cycle for a node
monitorNode :: NodeId -> App ()
monitorNode nid = do
  env  <- ask
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  pws  <- asks envPasswords
  fdc  <- asks envDetection
  now  <- liftIO getCurrentTime
  mc <- liftIO $ readTVarIO (envMonitoring env)
  let user      = credUser (ccCredentials cc)
      ci        = makeConnectInfo nid user (cpPassword pws)
      threshold = fdcConsecutiveFailuresForDead fdc
      retries   = mcConnectRetries mc
      backoff   = mcConnectRetryBackoff mc
      cap       = mcConnectTimeout mc
      logRetry msg = readTVarIO (envLogger env) >>= \l ->
        logDebug l ("[" <> ccName cc <> "] Node " <> nodeHost nid <> ": " <> msg)
  -- Read old state before connecting, so we can preserve nsIsSource on error
  mOldNs <- liftIO $ do
    mTopo <- getClusterTopology tvar (ccName cc)
    pure $ mTopo >>= \t -> Map.lookup nid (ctNodes t)
  let prevFailures = maybe 0 nsConsecutiveFailures mOldNs
  result <- liftIO $ withNodeConnRetry retries backoff cap logRetry ci $ \conn -> do
    mRs      <- showReplicaStatus conn
    gtidExec <- getGtidExecuted conn
    pure (mRs, gtidExec)
  let newFailures = case result of { Left _ -> prevFailures + 1; Right _ -> 0 }
  let ns = case result of
        Left err ->
          NodeState
            { nsNodeId               = nid
            , nsReplicaStatus        = Nothing
            , nsGtidExecuted         = ""
            , nsIsSource             = maybe False nsIsSource mOldNs
            , nsHealth               = NeedsAttention err
            , nsLastSeen             = Nothing
            , nsConnectError         = Just err
            , nsErrantGtids          = ""
            , nsPaused               = maybe False nsPaused mOldNs
            , nsConsecutiveFailures  = newFailures
            }
        Right (mRs, gtidExec) ->
          NodeState
            { nsNodeId               = nid
            , nsReplicaStatus        = mRs
            , nsGtidExecuted         = gtidExec
            , nsIsSource             = mRs == Nothing
            , nsHealth               = Healthy
            , nsLastSeen             = Just now
            , nsConnectError         = Nothing
            , nsErrantGtids          = ""
            , nsPaused               = maybe False nsPaused mOldNs
            , nsConsecutiveFailures  = 0
            }
  -- Update errant GTIDs by querying MySQL
  ns' <- enrichErrantGtids ns
  let ns''  = ns' { nsHealth = detectNodeHealth ns' }
  -- Apply consecutive failure threshold: suppress NeedsAttention until N consecutive failures
  let ns''' = suppressBelowThreshold threshold newFailures mOldNs ns''
  -- Log below-threshold failures for observability
  liftIO $ when (newFailures > 0 && newFailures < threshold) $ do
    logger <- readTVarIO (envLogger env)
    case result of
      Left err -> logInfo logger $ "[" <> ccName cc <> "] Node " <> nodeHost nid
                    <> " probe failed (" <> T.pack (show newFailures) <> "/"
                    <> T.pack (show threshold) <> "): " <> err
      Right _  -> pure ()
  logHealthChange nid mOldNs ns'''
  liftIO $ atomically $ updateNodeState tvar (ccName cc) ns'''
  -- Recompute cluster-level health
  recomputeClusterHealth

logHealthChange :: NodeId -> Maybe NodeState -> NodeState -> App ()
logHealthChange nid mOld new = do
  clusterName <- getClusterName
  logger <- asks envLogger >>= liftIO . readTVarIO
  if nsPaused new
    then pure ()
    else case (fmap nsHealth mOld, nsHealth new) of
      (Just Healthy, NeedsAttention err) -> do
        liftIO $ logWarn logger $ "[" <> clusterName <> "] Node " <> host <> " unreachable: " <> err
        recordAppEvent EvHealthChange (Just host) $ "Node " <> host <> " unreachable: " <> err
      (Just (NeedsAttention _), Healthy) -> do
        liftIO $ logInfo logger $ "[" <> clusterName <> "] Node " <> host <> " recovered"
        recordAppEvent EvHealthChange (Just host) $ "Node " <> host <> " recovered"
      (Nothing, NeedsAttention err) -> do
        liftIO $ logWarn logger $ "[" <> clusterName <> "] Node " <> host <> " initial connect failed: " <> err
        recordAppEvent EvHealthChange (Just host) $ "Node " <> host <> " initial connect failed: " <> err
      _ -> pure ()
  where
    host = nodeHost nid

enrichErrantGtids :: NodeState -> App NodeState
enrichErrantGtids ns = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  pws  <- asks envPasswords
  let user = credUser (ccCredentials cc)
  liftIO $ do
    mTopo <- getClusterTopology tvar (ccName cc)
    case mTopo of
      Nothing -> pure ns
      Just topo -> case ctSourceNodeId topo of
        Nothing -> pure ns
        Just srcId -> do
          let srcNodes = Map.lookup srcId (ctNodes topo)
          case srcNodes of
            Nothing -> pure ns
            Just srcNs -> do
              let replicaGtid = maybe "" rsExecutedGtidSet (nsReplicaStatus ns)
                  sourceGtid  = nsGtidExecuted srcNs
                  ci = makeConnectInfo srcId user (cpPassword pws)
              result <- withNodeConn ci $ \conn ->
                gtidSubtract conn replicaGtid sourceGtid
              case result of
                Left _         -> pure ns
                Right errant   -> pure ns { nsErrantGtids = errant }

recomputeClusterHealth :: App ()
recomputeClusterHealth = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  env  <- ask
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure ()
    Just topo -> do
      let newHealth = detectClusterHealth (ctNodes topo)
          newSrcId  = identifySource (Map.elems (ctNodes topo))
          topo' = topo
            { ctHealth          = newHealth
            , ctSourceNodeId    = newSrcId
            , ctObservedHealthy = newHealth == Healthy
            }
      let transitioned     = ctHealth topo /= newHealth
          observedHealthy  = ctObservedHealthy topo || newHealth == Healthy
      -- Fire on_failure_detection hook on transition to a dead state
      liftIO $ when transitioned $
        case newHealth of
          DeadSource -> do
            mHooks <- readTVarIO (envHooks env)
            ts <- getCurrentTimestamp
            let hookEnv = HookEnv (ccName cc) Nothing Nothing (Just "DeadSource") ts
            runHookFireForget mHooks hcOnFailureDetection hookEnv
          DeadSourceAndAllReplicas -> do
            mHooks <- readTVarIO (envHooks env)
            ts <- getCurrentTimestamp
            let hookEnv = HookEnv (ccName cc) Nothing Nothing (Just "DeadSourceAndAllReplicas") ts
            runHookFireForget mHooks hcOnFailureDetection hookEnv
          _ -> pure ()
      -- Log all health transitions for observability
      when transitioned $ do
        liftIO $ do
          logger <- readTVarIO (envLogger env)
          logInfo logger $ "[" <> ccName cc <> "] Cluster health: "
            <> T.pack (show (ctHealth topo)) <> " \x2192 " <> T.pack (show newHealth)
        recordAppEvent EvClusterHealth Nothing $
          T.pack (show (ctHealth topo)) <> " \x2192 " <> T.pack (show newHealth)
      liftIO $ atomically $ updateClusterTopology tvar topo'
      -- Trigger auto-failover when DeadSource (not just on transition, so resume-failover works)
      -- The failover lock prevents concurrent execution; anti-flap block prevents repeated failovers
      liftIO $ when (newHealth == DeadSource && fcAutoFailover fc && observedHealthy) $ do
        _ <- async (runApp env runAutoFailover)
        pure ()
      -- Emergency re-check on first transition to UnreachableSource
      liftIO $ when (transitioned && newHealth == UnreachableSource) $ do
        _ <- async (runApp env emergencyReplicaCheck)
        pure ()

-- | When UnreachableSource is first detected, immediately re-probe IOYes replicas
-- to confirm whether they can actually reach the source (Orchestrator-style).
emergencyReplicaCheck :: App ()
emergencyReplicaCheck = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  env  <- ask
  appLogInfo $ "[" <> ccName cc <> "] UnreachableSource detected: emergency replica re-check"
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing   -> pure ()
    Just topo -> do
      let ioYesReplicas = filter isIOYesReplica (Map.elems (ctNodes topo))
      liftIO $ do
        asyncs <- forM ioYesReplicas $ \ns ->
          async (runApp env (monitorNode (nsNodeId ns)))
        mapM_ wait asyncs

isIOYesReplica :: NodeState -> Bool
isIOYesReplica ns =
  not (nsIsSource ns) &&
  case nsReplicaStatus ns of
    Just rs -> rsReplicaIORunning rs == IOYes
    Nothing -> False
