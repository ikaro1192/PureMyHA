module PureMyHA.Supervisor.Worker
  ( startMonitorWorkers
  , startTopologyRefreshWorker
  , WorkerRegistry (..)
  , monitorNode
  , runWorker
  , emergencyReplicaCheck
  , suppressBelowThreshold
  , buildLagHookEnv
  , enrichErrantGtids
  , computeStaleNodes
  , pruneStaleWorkers
  , detectAndPruneStaleWorkers
  , probeTimeoutMicros
  , mergeNodeState
  , detectTopologyDrift
  , mergeTopology
  , computeNewNodes
  , computeDriftConditions
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait, cancel, waitCatch, withAsync, Async)
import Control.Concurrent.STM (atomically, TVar, newTVarIO, modifyTVar', readTVarIO, writeTBQueue)
import Control.Exception (SomeException, catch)
import System.Timeout (timeout)
import Control.Monad (forM, forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (getCurrentTime, NominalDiffTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Hook (HookEnv (..), SourceChange (..))
import PureMyHA.Logger (logDebug)
import PureMyHA.Supervisor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn, withNodeConnRetry)
import PureMyHA.MySQL.GTID (emptyGtidSet)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.Discovery (discoverTopology, deduplicateByHostname)
import PureMyHA.Topology.State
import PureMyHA.Types

newtype WorkerRegistry = WorkerRegistry
  { unWorkerRegistry :: TVar (Map.Map NodeId (Async ())) }

-- | Start one async monitor worker per node in a cluster; also returns registry
startMonitorWorkers :: App (WorkerRegistry, [Async ()])
startMonitorWorkers = do
  env <- ask
  nodes <- liftIO $ mapM (\nc -> do
        hi <- resolveHostInfo (HostName (ncHost nc))
        pure (unsafeNodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes (envCluster env)))
  liftIO $ do
    regTVar <- newTVarIO Map.empty
    let reg = WorkerRegistry regTVar
    asyncs <- forM nodes $ \nid -> do
      a <- async (runApp env (runWorker nid))
      atomically $ modifyTVar' regTVar (Map.insert nid a)
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
runTopologyRefresh reg@(WorkerRegistry regTVar) = do
  env <- ask
  let cc   = envCluster env
      tvar = envDaemonState env
      queue = envEventQueue env
  -- 1. Discover + merge topology (pure merge)
  newTopo  <- discoverTopology
  mOldTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  let mergedTopo = mergeTopology newTopo mOldTopo
  liftIO $ atomically $ writeTBQueue queue (TopologyRefreshed mergedTopo)
  -- 2. Worker management: start new, prune stale (pure decisions)
  knownNodes <- liftIO $ Map.keysSet <$> readTVarIO regTVar
  let discovered = Map.keysSet (ctNodes mergedTopo)
      newNodes   = computeNewNodes discovered knownNodes
  unless (null newNodes) $
    appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Topology refresh: "
      <> T.pack (show (length newNodes)) <> " new node(s) found"
  liftIO $ forM_ newNodes $ \nid -> do
    a <- async (runApp env (runWorker nid))
    atomically $ modifyTVar' regTVar (Map.insert nid a)
  staleNodes <- liftIO $ detectAndPruneStaleWorkers reg cc discovered
  unless (null staleNodes) $
    appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Topology refresh: pruning "
      <> T.pack (show (length staleNodes)) <> " stale worker(s)"
  -- 3. Drift detection — emit event; reducer compares old vs new and fires hooks
  let driftConditions = computeDriftConditions cc mergedTopo
      hasDrift        = if null driftConditions then NoDrift else DriftDetected
  liftIO $ atomically $ writeTBQueue queue (TopologyDriftUpdated hasDrift driftConditions)

-- | Compute newly discovered nodes: those in the discovered set but not yet
-- in the known (registered) set.
computeNewNodes :: Set.Set NodeId -> Set.Set NodeId -> [NodeId]
computeNewNodes discoveredNodes knownNodes =
  Set.toList (Set.difference discoveredNodes knownNodes)

-- | Compute nodes to prune: those in the registry but absent from both
-- the merged topology and the configured seed list.
computeStaleNodes :: Set.Set NodeId -> Set.Set NodeId -> Set.Set NodeId -> Set.Set NodeId
computeStaleNodes knownNodes discoveredNodes configuredNodes =
  Set.difference knownNodes (Set.union discoveredNodes configuredNodes)

-- | Cancel and remove stale workers from the registry.
pruneStaleWorkers :: WorkerRegistry -> [NodeId] -> IO ()
pruneStaleWorkers (WorkerRegistry regTVar) staleNodes =
  forM_ staleNodes $ \nid -> do
    mAsync <- Map.lookup nid <$> readTVarIO regTVar
    forM_ mAsync cancel
    atomically $ modifyTVar' regTVar (Map.delete nid)

-- | Detect and prune stale workers given current registry and topology state.
detectAndPruneStaleWorkers :: WorkerRegistry -> ClusterConfig -> Set.Set NodeId -> IO [NodeId]
detectAndPruneStaleWorkers reg@(WorkerRegistry regTVar) cc discovered = do
  knownNodes <- Map.keysSet <$> readTVarIO regTVar
  configuredNodes <- Set.fromList <$>
        mapM (\nc -> do
          hi <- resolveHostInfo (HostName (ncHost nc))
          pure (unsafeNodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes cc))
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

-- | Pure: compute drift conditions from cluster config and merged topology.
-- Extracts configured hosts, filters reachable nodes, counts healthy replicas,
-- and delegates to 'detectTopologyDrift'.
computeDriftConditions :: ClusterConfig -> ClusterTopology -> [DriftCondition]
computeDriftConditions cc topo =
  let configuredHosts = Set.fromList $ map (HostName . ncHost) (NE.toList (ccNodes cc))
      reachableNodes  = filter nsIsReachable (Map.elems (ctNodes topo))
      discoveredHosts = Set.fromList $ map (nodeHost . nsNodeId) reachableNodes
      healthyReplicas = length $ filter (\ns -> nsRole ns == Replica) reachableNodes
      minReplicas     = fcMinReplicasForFailover (ccFailover cc)
  in detectTopologyDrift configuredHosts discoveredHosts minReplicas healthyReplicas

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

-- | Merge a newly discovered topology with an optional previous topology.
-- Preserves daemon-managed fields from old nodes via 'mergeNodeState' and
-- deduplicates entries that represent the same hostname with different IPs.
mergeTopology :: ClusterTopology -> Maybe ClusterTopology -> ClusterTopology
mergeTopology newTopo Nothing = newTopo
mergeTopology newTopo (Just oldTopo) =
  newTopo { ctNodes = deduplicateByHostname
              (Map.unionWith mergeNodeState (ctNodes newTopo) (ctNodes oldTopo)) }

-- | When merging topology discovery results with existing state, preserve
-- daemon-managed node fields. The monitoring workers are the authoritative
-- source for nsHealth, nsErrantGtids, nsPaused, nsFenced, and
-- nsConsecutiveFailures; topology-refresh probes must not overwrite these
-- for existing nodes.
mergeNodeState :: NodeState -> NodeState -> NodeState
mergeNodeState new old = new
  { nsHealth              = nsHealth old
  , nsErrantGtids         = nsErrantGtids old
  , nsPaused              = nsPaused old
  , nsFenced              = nsFenced old
  , nsConsecutiveFailures = nsConsecutiveFailures old
  , nsRole                = nsRole old
  }

-- | Build the base HookEnv for lag threshold hooks.
-- Sets hookNode to the replica's hostname so hook scripts can identify
-- which replica is lagging in multi-replica topologies.
buildLagHookEnv :: ClusterName -> NodeId -> T.Text -> HookEnv
buildLagHookEnv clusterName nid ts =
  HookEnv { hookClusterName  = clusterName
           , hookSourceChange = NoSourceChange
           , hookFailureType  = Nothing
           , hookTimestamp    = ts
           , hookLagSeconds   = Nothing
           , hookNode         = Just (unHostName (nodeHost nid))
           , hookDriftType    = Nothing
           , hookDriftDetails = Nothing
           }

-- | Perform a single monitoring cycle for a node.
-- The worker only does IO (probe MySQL, enrich errant GTIDs) and emits
-- a raw NodeProbed event. All state-dependent computation (failure counting,
-- health detection, threshold suppression, role preservation) happens in the
-- reducer (applyEvent).
monitorNode :: NodeId -> App ()
monitorNode nid = do
  env  <- ask
  cc   <- asks envCluster
  now  <- liftIO getCurrentTime
  mc   <- liftIO $ readTVarIO (envMonitoring env)
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  let ci        = makeConnectInfo nid creds
      retries   = unAtLeastOne (mcConnectRetries mc)
      backoff   = mcConnectRetryBackoff mc
      cap       = unPositiveDuration (mcConnectTimeout mc)
      logRetry msg = readTVarIO (envLogger env) >>= \l ->
        logDebug l ("[" <> unClusterName (ccName cc) <> "] Node " <> unHostName (nodeHost nid) <> ": " <> msg)
  -- Run the probe in a separate thread so that timeout can interrupt it via
  -- waitCatch (STM — always interruptible) rather than wrapping the I/O directly.
  -- mysql-haskell's readPacket blocks in a C recv() that async exceptions cannot
  -- reliably interrupt; by moving the I/O to a sibling thread we avoid that.
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
  -- Build the raw ProbeResult
  let probeResult = case result of
        Left err            -> ProbeFailure err
        Right (mRs, gtidExec) -> ProbeSuccess now mRs gtidExec
  -- Enrich errant GTIDs (requires IO to query source node)
  let dummyNs = NodeState
        { nsNodeId              = nid
        , nsRole                = Replica
        , nsHealth              = Healthy
        , nsProbeResult         = probeResult
        , nsErrantGtids         = emptyGtidSet
        , nsPaused              = Running
        , nsConsecutiveFailures = 0
        , nsFenced              = Unfenced
        }
  enriched <- enrichErrantGtids dummyNs
  -- Emit the raw fact — all derived state computation happens in applyEvent
  liftIO $ atomically $ writeTBQueue (envEventQueue env) $
    NodeProbed nid probeResult (nsErrantGtids enriched) now


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
                      ci = makeConnectInfo srcId creds
                  mResult <- withAsync (withNodeConn mTls ci $ \conn ->
                    gtidSubtract conn replicaGtid) $ \errantAsync ->
                      timeout tMicros (waitCatch errantAsync)
                  case mResult of
                    Nothing                       -> pure ns
                    Just (Left _)                 -> pure ns
                    Just (Right (Left _))         -> pure ns
                    Just (Right (Right errant))   -> pure ns { nsErrantGtids = errant }

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
