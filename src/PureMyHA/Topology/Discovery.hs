module PureMyHA.Topology.Discovery
  ( discoverTopology
  , buildInitialTopology
  , buildNodeStateFromProbe
  , buildClusterTopology
  , nextDiscoveryTargets
  , deduplicateByHostname
  ) where

import Control.Concurrent.Async (withAsync, waitCatch)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (SomeException)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, ask, asks, runReaderT)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import qualified Data.List.NonEmpty as NE
import System.Timeout (timeout)
import PureMyHA.Config (ClusterConfig (..), DbCredentials, FailoverConfig (..), MonitoringConfig (..), NodeConfig (..), Port (..), PositiveDuration (..), TLSConfig)
import PureMyHA.Env (App, ClusterEnv (..), envLogger, getMonCredentials, getMonitoringConfig, getTLSConfig)
import PureMyHA.Logger (Logger, logInfo)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (GtidSet, emptyGtidSet)
import PureMyHA.MySQL.Query (showReplicaStatus, showReplicas, getGtidExecuted, resolveHostInfo)
import PureMyHA.Types
import PureMyHA.Supervisor.Detector (identifySource, detectClusterHealth)

-- | Internal environment for discovery, bundling invariant parameters.
data DiscoveryEnv = DiscoveryEnv
  { deMTls    :: Maybe TLSConfig
  , deCreds   :: DbCredentials
  , deTMicros :: Int
  , deLogger  :: Logger
  }

-- | Collapse the triple-nested result from timeout/waitCatch into a simple Either.
collapseProbeResult
  :: Maybe (Either SomeException (Either Text a))
  -> Either Text a
collapseProbeResult Nothing                    = Left "probe timeout"
collapseProbeResult (Just (Left e))            = Left (T.pack (show e))
collapseProbeResult (Just (Right (Left err)))  = Left err
collapseProbeResult (Just (Right (Right r)))   = Right r

-- | Split a probe result into the probe info and any discovered replica NodeIds.
splitProbeSuccess
  :: Either Text (Maybe ReplicaStatus, GtidSet, [NodeId])
  -> (Either Text (Maybe ReplicaStatus, GtidSet), [NodeId])
splitProbeSuccess (Left err)                     = (Left err, [])
splitProbeSuccess (Right (rs, gtid, replicaIds)) = (Right (rs, gtid), replicaIds)

-- | Discover all nodes reachable from the seed nodes
discoverTopology :: App ClusterTopology
discoverTopology = do
  cc     <- asks envCluster
  creds  <- getMonCredentials
  mTls   <- getTLSConfig
  logger <- asks envLogger >>= liftIO . readTVarIO
  mc     <- getMonitoringConfig
  let tMicros = round (realToFrac (unPositiveDuration (mcConnectTimeout mc)) * 1_000_000 :: Double) :: Int
      denv = DiscoveryEnv mTls creds tMicros logger
  seedNodes <- liftIO $ mapM (\nc -> do
    hi <- resolveHostInfo (HostName (ncHost nc))
    pure (NodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes cc))
  fc         <- asks envFailover
  nodeStates <- liftIO $ runReaderT (discoverAll (Set.fromList seedNodes) Set.empty Map.empty) denv
  pure (buildClusterTopology (fcMinReplicasForFailover fc) (ccName cc) nodeStates)

-- | Build a ClusterTopology from discovered node states (pure)
buildClusterTopology
  :: Int           -- ^ min_replicas_for_failover (quorum threshold)
  -> ClusterName
  -> Map NodeId NodeState
  -> ClusterTopology
buildClusterTopology minReplicas name nodeStates =
  let sourceId    = identifySource (Map.elems nodeStates)
      nodeStates' = case sourceId of
        Nothing  -> nodeStates
        Just sid -> Map.adjust (\ns -> ns { nsRole = Source }) sid nodeStates
      health      = detectClusterHealth minReplicas nodeStates'
  in ClusterTopology
       { ctClusterName          = name
       , ctNodes                = nodeStates'
       , ctSourceNodeId         = sourceId
       , ctHealth               = health
       , ctObservedHealthy      = if health == Healthy then HasBeenObservedHealthy else NeverObservedHealthy
       , ctRecoveryBlockedUntil = Nothing
       , ctLastFailoverAt       = Nothing
       , ctPaused               = Running
       , ctTopologyDrift        = NoDrift
       , ctLastEmergencyCheckAt = Nothing
       }

-- | Recursively discover nodes
discoverAll
  :: Set NodeId        -- ^ queue
  -> Set NodeId        -- ^ visited
  -> Map NodeId NodeState
  -> ReaderT DiscoveryEnv IO (Map NodeId NodeState)
discoverAll queue visited acc
  | Set.null queue = do
      logger <- asks deLogger
      liftIO $ logInfo logger $ "[discovery] Queue empty, discovery complete (" <> T.pack (show (Map.size acc)) <> " node(s))"
      pure acc
  | otherwise = do
      logger <- asks deLogger
      liftIO $ logInfo logger $ "[discovery] Queue: " <> T.pack (show (map (\n -> unHostName (nodeHost n) <> ":" <> T.pack (show (nodePort n))) (Set.toList queue)))
      let (nid0, rest) = Set.deleteFindMin queue
      -- Resolve hostname to IP so that queue entries from nextDiscoveryTargets
      -- (which use hostname-as-IP fallback) match already-visited resolved nodes.
      nid <- liftIO $ resolveQueueEntry nid0
      if Set.member nid visited
        then discoverAll rest visited acc
        else do
          (ns, replicaIds) <- probeNode nid
          let visited'  = Set.insert nid visited
              acc'      = Map.insert nid ns acc
              fromRs    = nextDiscoveryTargets ns visited' rest
              newQueue  = foldr (\rid q -> if Set.notMember rid visited' then Set.insert rid q else q) fromRs replicaIds
          discoverAll newQueue visited' acc'

-- | Probe a single node and return its NodeState plus any replicas discovered
-- via performance_schema.processlist (only populated when the node is a source).
-- Uses async + timeout to bound the probe duration; a stopped node that causes
-- TCP to hang will be treated as a failed probe after tMicros microseconds.
probeNode :: NodeId -> ReaderT DiscoveryEnv IO (NodeState, [NodeId])
probeNode nid = do
  logger <- asks deLogger
  liftIO $ logInfo logger $ "[discovery] Probing " <> unHostName (nodeHost nid) <> ":" <> T.pack (show (nodePort nid))
  now <- liftIO getCurrentTime
  result <- runProbe nid
  case result of
    Left err -> liftIO $ logInfo logger $ "[discovery] " <> unHostName (nodeHost nid) <> " probe failed: " <> err
    Right _  -> pure ()
  let (probeResult, discoveredReplicas) = splitProbeSuccess result
      ns = buildNodeStateFromProbe nid now probeResult
  pure (ns, discoveredReplicas)

-- | Execute the actual probe: connect, query, and collapse the nested result.
runProbe :: NodeId -> ReaderT DiscoveryEnv IO (Either Text (Maybe ReplicaStatus, GtidSet, [NodeId]))
runProbe nid = do
  DiscoveryEnv{..} <- ask
  let ci = makeConnectInfo nid deCreds
  mEither <- liftIO $
    withAsync (withNodeConn deMTls ci $ \conn -> do
      mReplicaStatus <- showReplicaStatus conn
      gtidExec       <- getGtidExecuted conn
      replicaIds <- case mReplicaStatus of
        Just rs -> do
          logInfo deLogger $ "[discovery] " <> unHostName (nodeHost nid) <> " is a replica of " <> unHostName (rsSourceHost rs) <> ":" <> T.pack (show (rsSourcePort rs))
          pure []
        Nothing -> do
          -- source node: discover downstream replicas via SHOW REPLICAS + performance_schema.processlist
          (discovered, expected, rawHosts) <- showReplicas conn (nodePort nid)
          logInfo deLogger $ "[" <> unHostName (nodeHost nid) <> "] Raw hosts from SHOW REPLICAS/processlist: "
            <> T.pack (show rawHosts)
          logInfo deLogger $ "[" <> unHostName (nodeHost nid) <> "] Resolved replica NodeIds: "
            <> T.pack (show (map (\n -> unHostName (nodeHost n) <> ":" <> T.pack (show (nodePort n))) discovered))
            <> " (SHOW REPLICAS reports " <> T.pack (show expected) <> " replica(s))"
          when (length discovered < expected) $
            logInfo deLogger $ "[" <> unHostName (nodeHost nid) <> "] WARNING: found "
              <> T.pack (show (length discovered)) <> " of " <> T.pack (show expected)
              <> " expected replica(s). Ensure the monitoring user has PROCESS privilege "
              <> "or set report_host on each replica."
          pure discovered
      pure (mReplicaStatus, gtidExec, replicaIds)) $ \probeAsync ->
      timeout deTMicros (waitCatch probeAsync)
  pure (collapseProbeResult mEither)

-- | Build a NodeState from a probe result (pure)
buildNodeStateFromProbe
  :: NodeId
  -> UTCTime
  -> Either Text (Maybe ReplicaStatus, GtidSet)
  -> NodeState
buildNodeStateFromProbe nid _ (Left err) = NodeState
  { nsNodeId              = nid
  , nsRole                = Replica
  , nsHealth              = NodeUnreachable err
  , nsProbeResult         = ProbeFailure err
  , nsErrantGtids         = emptyGtidSet
  , nsPaused              = Running
  , nsConsecutiveFailures = 0
  , nsFenced              = Unfenced
  }
buildNodeStateFromProbe nid now (Right (mRs, gtidExec)) = NodeState
  { nsNodeId              = nid
  , nsRole                = if mRs == Nothing then Source else Replica  -- no replica status = potential source
  , nsHealth              = Healthy
  , nsProbeResult         = ProbeSuccess now mRs gtidExec
  , nsErrantGtids         = emptyGtidSet
  , nsPaused              = Running
  , nsConsecutiveFailures = 0
  , nsFenced              = Unfenced
  }

-- | Calculate next nodes to probe from a discovered node's replica status (pure)
nextDiscoveryTargets
  :: NodeState
  -> Set NodeId  -- ^ visited
  -> Set NodeId  -- ^ current remaining queue
  -> Set NodeId
nextDiscoveryTargets ns visited rest =
  case nsProbeResult ns of
    ProbeSuccess{prReplicaStatus = Just rs} ->
      let srcId = NodeId (mkHostInfoFromName (rsSourceHost rs)) (rsSourcePort rs)
      in if Set.notMember srcId visited && unHostName (rsSourceHost rs) /= ""
           then Set.insert srcId rest
           else rest
    _ -> rest

-- | Resolve the hostname in a NodeId to ensure IP-based deduplication works.
resolveQueueEntry :: NodeId -> IO NodeId
resolveQueueEntry nid = do
  hi <- resolveHostInfo (nodeHost nid)
  pure (NodeId hi (nodePort nid))

-- | Remove duplicate nodes that represent the same hostname:port with different
-- IP representations. Prefers the entry with a resolved IP (IP text differs
-- from hostname text) over hostname-as-IP fallbacks. This can happen when
-- DNS resolution fails for a stopped node: the fallback produces a different
-- NodeId than the previously-resolved entry already in the topology.
deduplicateByHostname :: Map NodeId NodeState -> Map NodeId NodeState
deduplicateByHostname nodes =
    Map.fromList
  . Map.elems
  . Map.fromListWith preferResolved
  . map (\(nid, ns) -> (hostPort nid, (nid, ns)))
  . Map.toList
  $ nodes
  where
    hostPort nid   = (nodeHost nid, nodePort nid)
    isResolved nid = unIPAddr (nodeIPAddr nid) /= unHostName (nodeHost nid)
    preferResolved a@(nidA, _) b@(nidB, _)
      | isResolved nidA = a
      | isResolved nidB = b
      | otherwise       = a

-- | Build an initial (empty) topology from config
buildInitialTopology :: ClusterConfig -> ClusterTopology
buildInitialTopology cc = ClusterTopology
  { ctClusterName          = ccName cc
  , ctNodes                = Map.empty
  , ctSourceNodeId         = Nothing
  , ctHealth               = NeedsAttention "Initializing"
  , ctObservedHealthy      = NeverObservedHealthy
  , ctRecoveryBlockedUntil = Nothing
  , ctLastFailoverAt       = Nothing
  , ctPaused               = Running
  , ctTopologyDrift        = NoDrift
  , ctLastEmergencyCheckAt = Nothing
  }
