module PureMyHA.Monitor.Worker
  ( startMonitorWorkers
  , startTopologyRefreshWorker
  , WorkerRegistry
  , monitorNode
  , runWorker
  , suppressBelowThreshold
  , buildLagHookEnv
  , enrichErrantGtids
  , computeStaleNodes
  , pruneStaleWorkers
  , detectAndPruneStaleWorkers
  , probeTimeoutMicros
  , mergeNodeState
  , DriftCondition (..)
  , detectTopologyDrift
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait, cancel, waitCatch, withAsync, Async)
import Control.Concurrent.STM (atomically, TVar, newTVarIO, modifyTVar', readTVarIO)
import Control.Exception (SomeException, catch)
import System.Timeout (timeout)
import Control.Monad (when, forM, forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (getCurrentTime, NominalDiffTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Auto (runAutoFailover, runAutoFence)
import PureMyHA.Hook (runHookFireForget, getCurrentTimestamp, HookEnv (..))
import PureMyHA.Logger (logDebug, logInfo, logWarn)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn, withNodeConnRetry)
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.Discovery (discoverTopology, deduplicateByHostname)
import PureMyHA.Topology.State
import PureMyHA.Types
import PureMyHA.Monitor.Detector (detectClusterHealth, detectNodeHealth, identifySource)

type WorkerRegistry = TVar (Map.Map NodeId (Async ()))

-- | Start one async monitor worker per node in a cluster; also returns registry
startMonitorWorkers :: App (WorkerRegistry, [Async ()])
startMonitorWorkers = do
  env <- ask
  nodes <- liftIO $ mapM (\nc -> do
        hi <- resolveHostInfo (HostName (ncHost nc))
        pure (NodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes (envCluster env)))
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
      let intervalMicros = round (unPositiveDuration (mcInterval mc) * 1_000_000) :: Int
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
          newTopo { ctNodes = deduplicateByHostname
                      (Map.unionWith mergeNodeState (ctNodes newTopo) (ctNodes oldTopo)) }
  liftIO $ atomically $ updateClusterTopology tvar mergedTopo
  knownNodes <- liftIO $ Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes mergedTopo)
      newNodes   = Set.toList (Set.difference discovered knownNodes)
  unless (null newNodes) $
    appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Topology refresh: "
      <> T.pack (show (length newNodes)) <> " new node(s) found"
  -- Start workers for newly discovered nodes
  liftIO $ forM_ newNodes $ \nid -> do
    a <- async (runApp env (runWorker nid))
    atomically $ modifyTVar' reg (Map.insert nid a)
  -- Prune workers for truly decommissioned nodes
  staleNodes <- liftIO $ detectAndPruneStaleWorkers reg cc discovered
  unless (null staleNodes) $
    appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Topology refresh: pruning "
      <> T.pack (show (length staleNodes)) <> " stale worker(s)"
  -- Topology drift detection: use reachability so that stopped nodes register
  -- as missing even though they remain in the topology with a failed probe result.
  let configuredHosts = Set.fromList $ map (HostName . ncHost) (NE.toList (ccNodes cc))
      reachableNodes  = filter nsIsReachable (Map.elems (ctNodes mergedTopo))
      discoveredHosts = Set.fromList $ map (nodeHost . nsNodeId) reachableNodes
      healthyReplicas = length $ filter (\ns -> nsRole ns == Replica) reachableNodes
      minReplicas     = fcMinReplicasForFailover (ccFailover cc)
      driftConditions = detectTopologyDrift configuredHosts discoveredHosts minReplicas healthyReplicas
      hasDrift        = not (null driftConditions)
  wasInDrift <- liftIO $ atomically $ do
    mTopo <- getClusterTopologySTM tvar (ccName cc)
    updateClusterTopologyDrift tvar (ccName cc) hasDrift
    pure (maybe False ctTopologyDrift mTopo)
  -- Fire hook only on False→True transition to avoid repeated firings
  liftIO $ when (hasDrift && not wasInDrift) $ do
    mHooks <- readTVarIO (envHooks env)
    ts     <- getCurrentTimestamp
    forM_ driftConditions $ \dc -> do
      let (dt, dd) = renderDriftCondition dc
      runHookFireForget mHooks hcOnTopologyDrift
        HookEnv { hookClusterName  = ccName cc
                , hookNewSource    = Nothing
                , hookOldSource    = Nothing
                , hookFailureType  = Nothing
                , hookTimestamp    = ts
                , hookLagSeconds   = Nothing
                , hookNode         = Nothing
                , hookDriftType    = Just dt
                , hookDriftDetails = Just dd
                }

-- | Compute nodes to prune: those in the registry but absent from both
-- the merged topology and the configured seed list.
computeStaleNodes :: Set.Set NodeId -> Set.Set NodeId -> Set.Set NodeId -> Set.Set NodeId
computeStaleNodes knownNodes discoveredNodes configuredNodes =
  Set.difference knownNodes (Set.union discoveredNodes configuredNodes)

-- | Cancel and remove stale workers from the registry.
pruneStaleWorkers :: WorkerRegistry -> [NodeId] -> IO ()
pruneStaleWorkers reg staleNodes =
  forM_ staleNodes $ \nid -> do
    mAsync <- Map.lookup nid <$> readTVarIO reg
    forM_ mAsync cancel
    atomically $ modifyTVar' reg (Map.delete nid)

-- | Detect and prune stale workers given current registry and topology state.
detectAndPruneStaleWorkers :: WorkerRegistry -> ClusterConfig -> Set.Set NodeId -> IO [NodeId]
detectAndPruneStaleWorkers reg cc discovered = do
  knownNodes <- Map.keysSet <$> readTVarIO reg
  configuredNodes <- Set.fromList <$>
        mapM (\nc -> do
          hi <- resolveHostInfo (HostName (ncHost nc))
          pure (NodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes cc))
  let staleNodes = Set.toList (computeStaleNodes knownNodes discovered configuredNodes)
  pruneStaleWorkers reg staleNodes
  pure staleNodes

-- | Compute the probe timeout in microseconds.
-- Formula: connect_timeout × (2 × connect_retries + 1)
-- This covers the worst case of all retry attempts completing with max backoff,
-- and ensures a hung MySQL (TCP connected but query never responds) is detected.
probeTimeoutMicros :: NominalDiffTime -> Int -> Int
probeTimeoutMicros cap retries =
  round (realToFrac cap * fromIntegral (2 * retries + 1) * 1_000_000 :: Double)

-- | Suppress unhealthy health state when consecutive failure count is below
-- the configured threshold. Falls back to previous health (or Healthy if no prior state).
suppressBelowThreshold :: Int -> Int -> Maybe NodeState -> NodeState -> NodeState
suppressBelowThreshold threshold failCount mOldNs ns
  | failCount > 0 && failCount < threshold =
      ns { nsHealth = maybe Healthy nsHealth mOldNs }
  | otherwise = ns

-- | Conditions representing a topology drift from the expected state.
data DriftCondition
  = MissingNode HostName                  -- ^ A configured node not found in discovered topology
  | UnexpectedNode HostName               -- ^ A discovered node not present in config
  | ReplicaCountBelowThreshold Int Int    -- ^ (actual healthy replicas, min_replicas_for_failover)
  deriving (Eq, Show)

-- | Pure: detect topology drift by comparing configured and discovered host sets
-- and checking healthy replica count against the failover threshold.
detectTopologyDrift
  :: Set.Set HostName  -- ^ Configured hosts (from ccNodes)
  -> Set.Set HostName  -- ^ Discovered hosts (from merged topology)
  -> Int               -- ^ min_replicas_for_failover
  -> Int               -- ^ Current healthy replica count
  -> [DriftCondition]
detectTopologyDrift configured discovered minReplicas healthyReplicas =
  [ MissingNode h    | h <- Set.toList (Set.difference configured discovered) ]
  ++ [ UnexpectedNode h | h <- Set.toList (Set.difference discovered configured) ]
  ++ [ ReplicaCountBelowThreshold healthyReplicas minReplicas
     | healthyReplicas < minReplicas ]

-- | When merging topology discovery results with existing state, preserve
-- daemon-managed node fields. The monitoring workers are the authoritative
-- source for nsHealth, nsPaused, nsFenced, and nsConsecutiveFailures;
-- topology-refresh probes must not overwrite these for existing nodes.
mergeNodeState :: NodeState -> NodeState -> NodeState
mergeNodeState new old = new
  { nsHealth              = nsHealth old
  , nsPaused              = nsPaused old
  , nsFenced              = nsFenced old
  , nsConsecutiveFailures = nsConsecutiveFailures old
  , nsRole                = nsRole old
  }

-- | Render a DriftCondition as (PUREMYHA_DRIFT_TYPE, PUREMYHA_DRIFT_DETAILS).
renderDriftCondition :: DriftCondition -> (T.Text, T.Text)
renderDriftCondition (MissingNode h)                      = ("missing_node", unHostName h)
renderDriftCondition (UnexpectedNode h)                   = ("unexpected_node", unHostName h)
renderDriftCondition (ReplicaCountBelowThreshold act thr) =
  ("replica_count_below_threshold", T.pack (show act) <> " < " <> T.pack (show thr))

-- | Build the base HookEnv for lag threshold hooks.
-- Sets hookNode to the replica's hostname so hook scripts can identify
-- which replica is lagging in multi-replica topologies.
buildLagHookEnv :: ClusterName -> NodeId -> T.Text -> HookEnv
buildLagHookEnv clusterName nid ts =
  HookEnv { hookClusterName  = clusterName
           , hookNewSource    = Nothing
           , hookOldSource    = Nothing
           , hookFailureType  = Nothing
           , hookTimestamp    = ts
           , hookLagSeconds   = Nothing
           , hookNode         = Just (unHostName (nodeHost nid))
           , hookDriftType    = Nothing
           , hookDriftDetails = Nothing
           }

-- | Perform a single monitoring cycle for a node
monitorNode :: NodeId -> App ()
monitorNode nid = do
  env  <- ask
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fdc  <- asks envDetection
  now  <- liftIO getCurrentTime
  mc   <- liftIO $ readTVarIO (envMonitoring env)
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  let ci        = makeConnectInfo nid creds
      threshold = unAtLeastOne (fdcConsecutiveFailuresForDead fdc)
      retries   = unAtLeastOne (mcConnectRetries mc)
      backoff   = mcConnectRetryBackoff mc
      cap       = unPositiveDuration (mcConnectTimeout mc)
      logRetry msg = readTVarIO (envLogger env) >>= \l ->
        logDebug l ("[" <> unClusterName (ccName cc) <> "] Node " <> unHostName (nodeHost nid) <> ": " <> msg)
  -- Read old state before connecting for prevFailures count
  mOldNs <- liftIO $ do
    mTopo <- getClusterTopology tvar (ccName cc)
    pure $ mTopo >>= \t -> Map.lookup nid (ctNodes t)
  let prevFailures = maybe 0 nsConsecutiveFailures mOldNs
  -- Run the probe in a separate thread so that timeout can interrupt it via
  -- waitCatch (STM — always interruptible) rather than wrapping the I/O directly.
  -- mysql-haskell's readPacket blocks in a C recv() that async exceptions cannot
  -- reliably interrupt; by moving the I/O to a sibling thread we avoid that.
  -- The probe thread runs to completion once MySQL responds; it holds no shared
  -- locks so no deadlock is possible.
  let tMicros = probeTimeoutMicros cap retries
  result <- liftIO $ do
    probeAsync <- async $ withNodeConnRetry retries backoff cap logRetry mTls ci $ \conn -> do
      mRs      <- showReplicaStatus conn
      gtidExec <- getGtidExecuted conn
      pure (mRs, gtidExec)
    mEither <- timeout tMicros (waitCatch probeAsync)
    case mEither of
      Nothing          -> return (Left "probe timeout")
      Just (Left  e)   -> return (Left (T.pack (show e)))
      Just (Right r)   -> return r
  let newFailures = case result of { Left _ -> prevFailures + 1; Right _ -> 0 }
  let ns = case result of
        Left err ->
          NodeState
            { nsNodeId              = nid
            , nsRole                = maybe Replica nsRole mOldNs  -- preserve existing role on error
            , nsHealth              = NodeUnreachable err
            , nsProbeResult         = ProbeFailure err
            , nsErrantGtids         = emptyGtidSet
            , nsPaused              = False    -- actual value read atomically at write time
            , nsConsecutiveFailures = newFailures
            , nsFenced              = False    -- actual value read atomically at write time
            }
        Right (mRs, gtidExec) ->
          NodeState
            { nsNodeId              = nid
            , nsRole                = if mRs == Nothing then Source else Replica
            , nsHealth              = Healthy
            , nsProbeResult         = ProbeSuccess now mRs gtidExec
            , nsErrantGtids         = emptyGtidSet
            , nsPaused              = False    -- actual value read atomically at write time
            , nsConsecutiveFailures = 0
            , nsFenced              = False    -- actual value read atomically at write time
            }
  -- Update errant GTIDs by querying MySQL
  ns' <- enrichErrantGtids ns
  let lagThreshold = Just (round (realToFrac (mcReplicationLagCritical mc) :: Double) :: Int)
      ns''  = ns' { nsHealth = detectNodeHealth lagThreshold ns' }
  -- Apply consecutive failure threshold: suppress unhealthy state until N consecutive failures
  let ns''' = suppressBelowThreshold threshold newFailures mOldNs ns''
  -- Log below-threshold failures for observability
  liftIO $ when (newFailures > 0 && newFailures < threshold) $ do
    logger <- readTVarIO (envLogger env)
    case result of
      Left err -> logInfo logger $ "[" <> unClusterName (ccName cc) <> "] Node " <> unHostName (nodeHost nid)
                    <> " probe failed (" <> T.pack (show newFailures) <> "/"
                    <> T.pack (show threshold) <> "): " <> err
      Right _  -> pure ()
  logHealthChange nid mOldNs ns'''
  -- Fire lag threshold hooks on Lagging health transitions
  liftIO $ do
    mHooks <- readTVarIO (envHooks env)
    ts     <- getCurrentTimestamp
    let oldHealth = fmap nsHealth mOldNs
        newHealth = nsHealth ns'''
        baseEnv   = buildLagHookEnv (ccName cc) nid ts
    case (oldHealth, newHealth) of
      (Just (Lagging _), Lagging _) -> pure ()  -- already lagging, no transition
      (_, Lagging lag) ->
        runHookFireForget mHooks hcOnLagThresholdExceeded
          baseEnv { hookLagSeconds = Just lag }
      (Just (Lagging _), _) ->
        runHookFireForget mHooks hcOnLagThresholdRecovered baseEnv
      _ -> pure ()
  -- Use atomic read-modify-write to preserve nsRole/nsPaused from the current
  -- topology. This prevents race conditions where failover or pause/resume
  -- commands change these fields between the worker's read and write.
  liftIO $ atomically $ updateNodeStatePreserveRole tvar (ccName cc) ns'''
  -- Recompute cluster-level health
  recomputeClusterHealth

logHealthChange :: NodeId -> Maybe NodeState -> NodeState -> App ()
logHealthChange nid mOld new = do
  clusterName <- getClusterName
  logger <- asks envLogger >>= liftIO . readTVarIO
  if nsPaused new
    then pure ()
    else case (fmap nsHealth mOld, nsHealth new) of
      (Just Healthy, newH) | Just err <- healthErrorMessage newH ->
        liftIO $ logWarn logger $ "[" <> unClusterName clusterName <> "] Node " <> host <> " unreachable: " <> err
      (Just oldH, Healthy) | isUnhealthy oldH ->
        liftIO $ logInfo logger $ "[" <> unClusterName clusterName <> "] Node " <> host <> " recovered"
      (Nothing, newH) | Just err <- healthErrorMessage newH ->
        liftIO $ logWarn logger $ "[" <> unClusterName clusterName <> "] Node " <> host <> " initial connect failed: " <> err
      _ -> pure ()
  where
    host = unHostName (nodeHost nid)

enrichErrantGtids :: NodeState -> App NodeState
enrichErrantGtids ns = do
  tvar  <- asks envDaemonState
  cc    <- asks envCluster
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  env   <- ask
  mc    <- liftIO $ readTVarIO (envMonitoring env)
  let tMicros = probeTimeoutMicros (unPositiveDuration (mcConnectTimeout mc)) (unAtLeastOne (mcConnectRetries mc))
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
            Just srcNs ->
              if not (nsIsReachable srcNs) || not (nsIsReachable ns)
                then pure ns
                else do
                  let replicaGtid = case nsProbeResult ns of
                        ProbeSuccess{prReplicaStatus = Just rs} -> rsExecutedGtidSet rs
                        _ -> emptyGtidSet
                      sourceGtid = case nsProbeResult srcNs of
                        ProbeSuccess{prGtidExecuted = g} -> g
                        ProbeFailure{} -> emptyGtidSet
                      ci = makeConnectInfo srcId creds
                  mResult <- withAsync (withNodeConn mTls ci $ \conn ->
                    gtidSubtract conn replicaGtid sourceGtid) $ \errantAsync ->
                      timeout tMicros (waitCatch errantAsync)
                  case mResult of
                    Nothing                       -> pure ns
                    Just (Left _)                 -> pure ns
                    Just (Right (Left _))         -> pure ns
                    Just (Right (Right errant))   -> pure ns { nsErrantGtids = errant }

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
      let transitioned     = ctHealth topo /= newHealth
          observedHealthy  = ctObservedHealthy topo || newHealth == Healthy
      -- Fire on_failure_detection hook on transition to a dead state
      liftIO $ when transitioned $
        case newHealth of
          DeadSource -> do
            mHooks <- readTVarIO (envHooks env)
            ts <- getCurrentTimestamp
            let hookEnv = HookEnv { hookClusterName  = ccName cc
                                   , hookNewSource    = Nothing
                                   , hookOldSource    = Nothing
                                   , hookFailureType  = Just "DeadSource"
                                   , hookTimestamp    = ts
                                   , hookLagSeconds   = Nothing
                                   , hookNode         = Nothing
                                   , hookDriftType    = Nothing
                                   , hookDriftDetails = Nothing
                                   }
            runHookFireForget mHooks hcOnFailureDetection hookEnv
          DeadSourceAndAllReplicas -> do
            mHooks <- readTVarIO (envHooks env)
            ts <- getCurrentTimestamp
            let hookEnv = HookEnv { hookClusterName  = ccName cc
                                   , hookNewSource    = Nothing
                                   , hookOldSource    = Nothing
                                   , hookFailureType  = Just "DeadSourceAndAllReplicas"
                                   , hookTimestamp    = ts
                                   , hookLagSeconds   = Nothing
                                   , hookNode         = Nothing
                                   , hookDriftType    = Nothing
                                   , hookDriftDetails = Nothing
                                   }
            runHookFireForget mHooks hcOnFailureDetection hookEnv
          _ -> pure ()
      -- Log all health transitions for observability
      when transitioned $ liftIO $ do
        logger <- readTVarIO (envLogger env)
        logInfo logger $ "[" <> unClusterName (ccName cc) <> "] Cluster health: "
          <> T.pack (show (ctHealth topo)) <> " \x2192 " <> T.pack (show newHealth)
      liftIO $ atomically $ updateClusterHealthFields tvar (ccName cc) newHealth newSrcId observedHealthy
      -- Trigger auto-failover when DeadSource (not just on transition, so resume-failover works)
      -- The failover lock prevents concurrent execution; anti-flap block prevents repeated failovers
      liftIO $ when (newHealth == DeadSource && fcAutoFailover fc && observedHealthy) $ do
        _ <- async (runApp env runAutoFailover)
        pure ()
      -- Trigger auto-fence on first transition to SplitBrainSuspected only.
      -- Firing only on transition prevents re-fencing after the operator runs `unfence`.
      liftIO $ when (transitioned && newHealth == SplitBrainSuspected && fcAutoFence fc && observedHealthy) $ do
        _ <- async (runApp env runAutoFence)
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
  appLogInfo $ "[" <> unClusterName (ccName cc) <> "] UnreachableSource detected: emergency replica re-check"
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
  not (isSource ns) &&
  case nsProbeResult ns of
    ProbeSuccess{prReplicaStatus = Just rs} -> rsReplicaIORunning rs == IOYes
    _ -> False
