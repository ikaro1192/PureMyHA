module PureMyHA.Monitor.Worker
  ( startMonitorWorkers
  , startTopologyRefreshWorker
  , WorkerRegistry
  , monitorNode
  , runWorker
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait, Async)
import Control.Concurrent.STM (atomically, TVar, newTVarIO, modifyTVar', readTVarIO)
import Control.Exception (SomeException, catch)
import Control.Monad (when, forM, forM_, unless)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..), ClusterPasswords (..), MonitoringConfig (..), HooksConfig (..), FailoverConfig (..), FailureDetectionConfig (..))
import PureMyHA.Failover.Auto (runAutoFailover)
import PureMyHA.Hook (runHookFireForget, getCurrentTimestamp, HookEnv (..))
import PureMyHA.Logger (Logger, logInfo, logWarn)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.Discovery (discoverTopology)
import PureMyHA.Topology.State
import PureMyHA.Types
import PureMyHA.Monitor.Detector (detectClusterHealth, detectNodeHealth, identifySource)

type WorkerRegistry = TVar (Map.Map NodeId (Async ()))

-- | Start one async monitor worker per node in a cluster; also returns registry
startMonitorWorkers
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Logger
  -> IO (WorkerRegistry, [Async ()])
startMonitorWorkers tvar cc mcVar hooksVar lock fc fdc pws logger = do
  reg <- newTVarIO Map.empty
  let nodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
  asyncs <- forM nodes $ \nid -> do
    a <- async (runWorker tvar cc mcVar hooksVar lock fc fdc pws nid logger)
    atomically $ modifyTVar' reg (Map.insert nid a)
    pure a
  pure (reg, asyncs)

runWorker
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> NodeId
  -> Logger
  -> IO ()
runWorker tvar cc mcVar hooksVar lock fc fdc pws nid logger = loop
  where
    loop = do
      mc     <- readTVarIO mcVar
      mHooks <- readTVarIO hooksVar
      let intervalMicros = round (mcInterval mc * 1_000_000) :: Int
      monitorNode tvar cc mc lock fc fdc pws mHooks nid logger
        `catch` (\(_ :: SomeException) -> pure ())
      threadDelay intervalMicros
      loop

-- | Start the topology refresh worker for a cluster
startTopologyRefreshWorker
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> WorkerRegistry
  -> Logger
  -> IO (Async ())
startTopologyRefreshWorker tvar cc mcVar hooksVar lock fc fdc pws reg logger =
  async (topologyRefreshLoop tvar cc mcVar hooksVar lock fc fdc pws reg logger)

topologyRefreshLoop
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> WorkerRegistry
  -> Logger
  -> IO ()
topologyRefreshLoop tvar cc mcVar hooksVar lock fc fdc pws reg logger = loop
  where
    loop = do
      mc <- readTVarIO mcVar
      let interval = mcDiscoveryInterval mc
      if interval <= 0
        then threadDelay 60_000_000  -- disabled: check every 60s in case config reloads
        else do
          threadDelay (round (interval * 1_000_000) :: Int)
          runTopologyRefresh tvar cc mcVar hooksVar lock fc fdc pws reg logger
            `catch` (\(_ :: SomeException) -> pure ())
      loop

runTopologyRefresh
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> WorkerRegistry
  -> Logger
  -> IO ()
runTopologyRefresh tvar cc mcVar hooksVar lock fc fdc pws reg logger = do
  newTopo    <- discoverTopology cc (cpPassword pws) logger
  atomically $ updateClusterTopology tvar newTopo
  knownNodes <- Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes newTopo)
      newNodes   = Set.toList (Set.difference discovered knownNodes)
  unless (null newNodes) $
    logInfo logger $ "[" <> ccName cc <> "] Topology refresh: "
      <> T.pack (show (length newNodes)) <> " new node(s) found"
  forM_ newNodes $ \nid -> do
    a <- async (runWorker tvar cc mcVar hooksVar lock fc fdc pws nid logger)
    atomically $ modifyTVar' reg (Map.insert nid a)

-- | Perform a single monitoring cycle for a node
monitorNode
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Maybe HooksConfig
  -> NodeId
  -> Logger
  -> IO ()
monitorNode tvar cc mc lock fc fdc pws mHooks nid logger = do
  now <- getCurrentTime
  let user = credUser (ccCredentials cc)
      ci   = makeConnectInfo nid user (cpPassword pws)
  -- Read old state before connecting, so we can preserve nsIsSource on error
  mOldNs <- do
    mTopo <- getClusterTopology tvar (ccName cc)
    pure $ mTopo >>= \t -> Map.lookup nid (ctNodes t)
  result <- withNodeConn ci $ \conn -> do
    mRs      <- showReplicaStatus conn
    gtidExec <- getGtidExecuted conn
    pure (mRs, gtidExec)
  ns <- case result of
    Left err ->
      pure NodeState
        { nsNodeId          = nid
        , nsReplicaStatus   = Nothing
        , nsGtidExecuted    = ""
        , nsIsSource        = maybe False nsIsSource mOldNs
        , nsHealth          = NeedsAttention err
        , nsLastSeen        = Nothing
        , nsConnectError    = Just err
        , nsErrantGtids     = ""
        , nsPaused          = maybe False nsPaused mOldNs
        }
    Right (mRs, gtidExec) ->
      pure NodeState
        { nsNodeId          = nid
        , nsReplicaStatus   = mRs
        , nsGtidExecuted    = gtidExec
        , nsIsSource        = mRs == Nothing
        , nsHealth          = Healthy
        , nsLastSeen        = Just now
        , nsConnectError    = Nothing
        , nsErrantGtids     = ""
        , nsPaused          = maybe False nsPaused mOldNs
        }
  -- Update errant GTIDs by querying MySQL
  ns' <- enrichErrantGtids tvar (ccName cc) ns user (cpPassword pws)
  let ns'' = ns' { nsHealth = detectNodeHealth ns' }
  logHealthChange logger (ccName cc) nid mOldNs ns''
  atomically $ updateNodeState tvar (ccName cc) ns''
  -- Recompute cluster-level health
  recomputeClusterHealth tvar cc mc lock fc fdc pws mHooks logger

logHealthChange :: Logger -> ClusterName -> NodeId -> Maybe NodeState -> NodeState -> IO ()
logHealthChange logger clusterName nid mOld new = do
  let host = nodeHost nid
  if nsPaused new
    then pure ()
    else case (fmap nsHealth mOld, nsHealth new) of
      (Just Healthy, NeedsAttention err) ->
        logWarn logger $ "[" <> clusterName <> "] Node " <> host <> " unreachable: " <> err
      (Just (NeedsAttention _), Healthy) ->
        logInfo logger $ "[" <> clusterName <> "] Node " <> host <> " recovered"
      (Nothing, NeedsAttention err) ->
        logWarn logger $ "[" <> clusterName <> "] Node " <> host <> " initial connect failed: " <> err
      _ -> pure ()

enrichErrantGtids :: TVarDaemonState -> ClusterName -> NodeState -> Text -> Text -> IO NodeState
enrichErrantGtids tvar clusterName ns user password = do
  mTopo <- getClusterTopology tvar clusterName
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
                ci = makeConnectInfo srcId user password
            result <- withNodeConn ci $ \conn ->
              gtidSubtract conn replicaGtid sourceGtid
            case result of
              Left _         -> pure ns
              Right errant   -> pure ns { nsErrantGtids = errant }

recomputeClusterHealth
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> ClusterPasswords
  -> Maybe HooksConfig
  -> Logger
  -> IO ()
recomputeClusterHealth tvar cc mc lock fc fdc pws mHooks logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
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
      when transitioned $
        case newHealth of
          DeadSource -> do
            ts <- getCurrentTimestamp
            let env = HookEnv (ccName cc) Nothing Nothing (Just "DeadSource") ts
            runHookFireForget mHooks hcOnFailureDetection env
          DeadSourceAndAllReplicas -> do
            ts <- getCurrentTimestamp
            let env = HookEnv (ccName cc) Nothing Nothing (Just "DeadSourceAndAllReplicas") ts
            runHookFireForget mHooks hcOnFailureDetection env
          _ -> pure ()
      -- Log all health transitions for observability
      when transitioned $
        logInfo logger $ "[" <> ccName cc <> "] Cluster health: "
          <> T.pack (show (ctHealth topo)) <> " \x2192 " <> T.pack (show newHealth)
      atomically $ updateClusterTopology tvar topo'
      -- Trigger auto-failover when DeadSource (not just on transition, so resume-failover works)
      -- The failover lock prevents concurrent execution; anti-flap block prevents repeated failovers
      when (newHealth == DeadSource && fcAutoFailover fc && observedHealthy) $ do
        _ <- async (runAutoFailover tvar lock cc fc fdc pws mHooks logger)
        pure ()
      -- Emergency re-check on first transition to UnreachableSource
      when (transitioned && newHealth == UnreachableSource) $ do
        _ <- async (emergencyReplicaCheck tvar cc mc lock fc fdc pws mHooks logger)
        pure ()

-- | When UnreachableSource is first detected, immediately re-probe IOYes replicas
-- to confirm whether they can actually reach the source (Orchestrator-style).
emergencyReplicaCheck
  :: TVarDaemonState -> ClusterConfig -> MonitoringConfig -> FailoverLock
  -> FailoverConfig -> FailureDetectionConfig -> ClusterPasswords
  -> Maybe HooksConfig -> Logger -> IO ()
emergencyReplicaCheck tvar cc mc lock fc fdc pws mHooks logger = do
  logInfo logger $ "[" <> ccName cc <> "] UnreachableSource detected: emergency replica re-check"
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing   -> pure ()
    Just topo -> do
      let ioYesReplicas = filter isIOYesReplica (Map.elems (ctNodes topo))
      asyncs <- forM ioYesReplicas $ \ns ->
        async (monitorNode tvar cc mc lock fc fdc pws mHooks (nsNodeId ns) logger)
      mapM_ wait asyncs

isIOYesReplica :: NodeState -> Bool
isIOYesReplica ns =
  not (nsIsSource ns) &&
  case nsReplicaStatus ns of
    Just rs -> rsReplicaIORunning rs == IOYes
    Nothing -> False
