module PureMyHA.Monitor.Worker
  ( startMonitorWorkers
  , startTopologyRefreshWorker
  , WorkerRegistry
  , monitorNode
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, Async)
import Control.Concurrent.STM (atomically, TVar, newTVarIO, modifyTVar', readTVarIO)
import Control.Exception (SomeException, catch)
import Control.Monad (when, forM, forM_, unless)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..), MonitoringConfig (..), HooksConfig (..), FailoverConfig (..), FailureDetectionConfig (..))
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
  -> Text             -- ^ password
  -> Logger
  -> IO (WorkerRegistry, [Async ()])
startMonitorWorkers tvar cc mcVar hooksVar lock fc fdc password logger = do
  reg <- newTVarIO Map.empty
  let nodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
  asyncs <- forM nodes $ \nid -> do
    a <- async (runWorker tvar cc mcVar hooksVar lock fc fdc password nid logger)
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
  -> Text
  -> NodeId
  -> Logger
  -> IO ()
runWorker tvar cc mcVar hooksVar lock fc fdc password nid logger = loop
  where
    loop = do
      mc     <- readTVarIO mcVar
      mHooks <- readTVarIO hooksVar
      let intervalMicros = round (mcInterval mc * 1_000_000) :: Int
      monitorNode tvar cc mc lock fc fdc password mHooks nid logger
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
  -> Text
  -> WorkerRegistry
  -> Logger
  -> IO (Async ())
startTopologyRefreshWorker tvar cc mcVar hooksVar lock fc fdc password reg logger =
  async (topologyRefreshLoop tvar cc mcVar hooksVar lock fc fdc password reg logger)

topologyRefreshLoop
  :: TVarDaemonState
  -> ClusterConfig
  -> TVar MonitoringConfig
  -> TVar (Maybe HooksConfig)
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> WorkerRegistry
  -> Logger
  -> IO ()
topologyRefreshLoop tvar cc mcVar hooksVar lock fc fdc password reg logger = loop
  where
    loop = do
      mc <- readTVarIO mcVar
      let interval = mcDiscoveryInterval mc
      if interval <= 0
        then threadDelay 60_000_000  -- disabled: check every 60s in case config reloads
        else do
          threadDelay (round (interval * 1_000_000) :: Int)
          runTopologyRefresh tvar cc mcVar hooksVar lock fc fdc password reg logger
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
  -> Text
  -> WorkerRegistry
  -> Logger
  -> IO ()
runTopologyRefresh tvar cc mcVar hooksVar lock fc fdc password reg logger = do
  newTopo    <- discoverTopology cc password logger
  atomically $ updateClusterTopology tvar newTopo
  knownNodes <- Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes newTopo)
      newNodes   = Set.toList (Set.difference discovered knownNodes)
  unless (null newNodes) $
    logInfo logger $ "[" <> ccName cc <> "] Topology refresh: "
      <> T.pack (show (length newNodes)) <> " new node(s) found"
  forM_ newNodes $ \nid -> do
    a <- async (runWorker tvar cc mcVar hooksVar lock fc fdc password nid logger)
    atomically $ modifyTVar' reg (Map.insert nid a)

-- | Perform a single monitoring cycle for a node
monitorNode
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> Maybe HooksConfig
  -> NodeId
  -> Logger
  -> IO ()
monitorNode tvar cc _mc lock fc fdc password mHooks nid logger = do
  now <- getCurrentTime
  let user = credUser (ccCredentials cc)
      ci   = makeConnectInfo nid user password
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
        }
  -- Update errant GTIDs by querying MySQL
  ns' <- enrichErrantGtids tvar (ccName cc) ns user password
  let ns'' = ns' { nsHealth = detectNodeHealth ns' }
  logHealthChange logger (ccName cc) nid mOldNs ns''
  atomically $ updateNodeState tvar (ccName cc) ns''
  -- Recompute cluster-level health
  recomputeClusterHealth tvar cc lock fc fdc password mHooks logger

logHealthChange :: Logger -> ClusterName -> NodeId -> Maybe NodeState -> NodeState -> IO ()
logHealthChange logger clusterName nid mOld new = do
  let host = nodeHost nid
  case (fmap nsHealth mOld, nsHealth new) of
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
  -> FailoverLock
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text             -- ^ password
  -> Maybe HooksConfig
  -> Logger
  -> IO ()
recomputeClusterHealth tvar cc lock fc fdc password mHooks logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure ()
    Just topo -> do
      let newHealth = detectClusterHealth (ctNodes topo)
          newSrcId  = identifySource (Map.elems (ctNodes topo))
          topo' = topo
            { ctHealth       = newHealth
            , ctSourceNodeId = newSrcId
            }
      let transitioned = ctHealth topo /= newHealth
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
      atomically $ updateClusterTopology tvar topo'
      -- Trigger auto-failover on transition to DeadSource
      when (transitioned && newHealth == DeadSource && fcAutoFailover fc) $ do
        _ <- async (runAutoFailover tvar lock cc fc fdc password mHooks logger)
        pure ()
