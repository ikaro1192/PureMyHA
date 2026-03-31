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
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import qualified Data.List.NonEmpty as NE
import System.Timeout (timeout)
import PureMyHA.Config (ClusterConfig (..), DbCredentials, MonitoringConfig (..), NodeConfig (..), Port (..), PositiveDuration (..), TLSConfig)
import PureMyHA.Env (App, ClusterEnv (..), envLogger, getMonCredentials, getMonitoringConfig, getTLSConfig)
import PureMyHA.Logger (Logger, logInfo)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (showReplicaStatus, showReplicas, getGtidExecuted, resolveHostInfo)
import PureMyHA.Types
import PureMyHA.Monitor.Detector (identifySource, detectClusterHealth)

-- | Discover all nodes reachable from the seed nodes
discoverTopology :: App ClusterTopology
discoverTopology = do
  cc     <- asks envCluster
  creds  <- getMonCredentials
  mTls   <- getTLSConfig
  logger <- asks envLogger >>= liftIO . readTVarIO
  mc     <- getMonitoringConfig
  let tMicros = round (realToFrac (unPositiveDuration (mcConnectTimeout mc)) * 1_000_000 :: Double) :: Int
  seedNodes <- liftIO $ mapM (\nc -> do
    hi <- resolveHostInfo (HostName (ncHost nc))
    pure (NodeId hi (unPort (ncPort nc)))) (NE.toList (ccNodes cc))
  nodeStates <- liftIO $ discoverAll mTls creds tMicros (Set.fromList seedNodes) Set.empty Map.empty logger
  pure (buildClusterTopology (ccName cc) nodeStates)

-- | Build a ClusterTopology from discovered node states (pure)
buildClusterTopology
  :: ClusterName
  -> Map NodeId NodeState
  -> ClusterTopology
buildClusterTopology name nodeStates =
  let sourceId    = identifySource (Map.elems nodeStates)
      nodeStates' = case sourceId of
        Nothing  -> nodeStates
        Just sid -> Map.adjust (\ns -> ns { nsRole = Source }) sid nodeStates
      health      = detectClusterHealth nodeStates'
  in ClusterTopology
       { ctClusterName          = name
       , ctNodes                = nodeStates'
       , ctSourceNodeId         = sourceId
       , ctHealth               = health
       , ctObservedHealthy      = health == Healthy
       , ctRecoveryBlockedUntil = Nothing
       , ctLastFailoverAt       = Nothing
       , ctPaused               = False
       , ctTopologyDrift        = False
       }

-- | Recursively discover nodes
discoverAll
  :: Maybe TLSConfig   -- ^ TLS configuration
  -> DbCredentials     -- ^ credentials
  -> Int               -- ^ connect timeout in microseconds
  -> Set NodeId        -- ^ queue
  -> Set NodeId        -- ^ visited
  -> Map NodeId NodeState
  -> Logger
  -> IO (Map NodeId NodeState)
discoverAll mTls creds tMicros queue visited acc logger
  | Set.null queue = do
      logInfo logger $ "[discovery] Queue empty, discovery complete (" <> T.pack (show (Map.size acc)) <> " node(s))"
      pure acc
  | otherwise = do
      logInfo logger $ "[discovery] Queue: " <> T.pack (show (map (\n -> unHostName (nodeHost n) <> ":" <> T.pack (show (nodePort n))) (Set.toList queue)))
      let (nid0, rest) = Set.deleteFindMin queue
      -- Resolve hostname to IP so that queue entries from nextDiscoveryTargets
      -- (which use hostname-as-IP fallback) match already-visited resolved nodes.
      nid <- resolveQueueEntry nid0
      if Set.member nid visited
        then discoverAll mTls creds tMicros rest visited acc logger
        else do
          (ns, replicaIds) <- probeNode mTls creds tMicros nid logger
          let visited'  = Set.insert nid visited
              acc'      = Map.insert nid ns acc
              fromRs    = nextDiscoveryTargets ns visited' rest
              newQueue  = foldr (\rid q -> if Set.notMember rid visited' then Set.insert rid q else q) fromRs replicaIds
          discoverAll mTls creds tMicros newQueue visited' acc' logger

-- | Probe a single node and return its NodeState plus any replicas discovered
-- via SHOW PROCESSLIST (only populated when the node is a source).
-- Uses async + timeout to bound the probe duration; a stopped node that causes
-- TCP to hang will be treated as a failed probe after tMicros microseconds.
probeNode :: Maybe TLSConfig -> DbCredentials -> Int -> NodeId -> Logger -> IO (NodeState, [NodeId])
probeNode mTls creds tMicros nid logger = do
  logInfo logger $ "[discovery] Probing " <> unHostName (nodeHost nid) <> ":" <> T.pack (show (nodePort nid))
  now <- getCurrentTime
  let ci = makeConnectInfo nid creds
  mEither <- withAsync (withNodeConn mTls ci $ \conn -> do
    mReplicaStatus <- showReplicaStatus conn
    gtidExec       <- getGtidExecuted conn
    replicaIds <- case mReplicaStatus of
      Just rs -> do
        logInfo logger $ "[discovery] " <> unHostName (nodeHost nid) <> " is a replica of " <> unHostName (rsSourceHost rs) <> ":" <> T.pack (show (rsSourcePort rs))
        pure []
      Nothing -> do
        -- source node: discover downstream replicas via SHOW REPLICAS + SHOW PROCESSLIST
        (discovered, expected, rawHosts) <- showReplicas conn (nodePort nid)
        logInfo logger $ "[" <> unHostName (nodeHost nid) <> "] Raw hosts from SHOW REPLICAS/PROCESSLIST: "
          <> T.pack (show rawHosts)
        logInfo logger $ "[" <> unHostName (nodeHost nid) <> "] Resolved replica NodeIds: "
          <> T.pack (show (map (\n -> unHostName (nodeHost n) <> ":" <> T.pack (show (nodePort n))) discovered))
          <> " (SHOW REPLICAS reports " <> T.pack (show expected) <> " replica(s))"
        when (length discovered < expected) $
          logInfo logger $ "[" <> unHostName (nodeHost nid) <> "] WARNING: found "
            <> T.pack (show (length discovered)) <> " of " <> T.pack (show expected)
            <> " expected replica(s). Ensure the monitoring user has PROCESS privilege "
            <> "or set report_host on each replica."
        pure discovered
    pure (mReplicaStatus, gtidExec, replicaIds)) $ \probeAsync ->
    timeout tMicros (waitCatch probeAsync)
  let result = case mEither of
        Nothing                  -> Left "probe timeout"
        Just (Left e)            -> Left (T.pack (show e))
        Just (Right (Left err))  -> Left err
        Just (Right (Right r))   -> Right r
  case result of
    Left err -> logInfo logger $ "[discovery] " <> unHostName (nodeHost nid) <> " probe failed: " <> err
    Right _  -> pure ()
  let (probeResult, discoveredReplicas) = case result of
        Left err                     -> (Left err, [])
        Right (rs, gtid, replicaIds) -> (Right (rs, gtid), replicaIds)
      ns = buildNodeStateFromProbe nid now probeResult
  pure (ns, discoveredReplicas)

-- | Build a NodeState from a probe result (pure)
buildNodeStateFromProbe
  :: NodeId
  -> UTCTime
  -> Either Text (Maybe ReplicaStatus, Text)
  -> NodeState
buildNodeStateFromProbe nid _ (Left err) = NodeState
  { nsNodeId              = nid
  , nsRole                = Replica
  , nsHealth              = NeedsAttention err
  , nsProbeResult         = ProbeFailure err
  , nsErrantGtids         = ""
  , nsPaused              = False
  , nsConsecutiveFailures = 0
  , nsFenced              = False
  }
buildNodeStateFromProbe nid now (Right (mRs, gtidExec)) = NodeState
  { nsNodeId              = nid
  , nsRole                = if mRs == Nothing then Source else Replica  -- no replica status = potential source
  , nsHealth              = Healthy
  , nsProbeResult         = ProbeSuccess now mRs gtidExec
  , nsErrantGtids         = ""
  , nsPaused              = False
  , nsConsecutiveFailures = 0
  , nsFenced              = False
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
  Map.fromList . map selectBest . groupByHostPort . Map.toList $ nodes
  where
    hostPort nid   = (nodeHost nid, nodePort nid)
    isResolved nid = unIPAddr (nodeIPAddr nid) /= unHostName (nodeHost nid)
    groupByHostPort =
      Map.elems . foldr (\e m -> Map.insertWith (++) (hostPort (fst e)) [e] m) Map.empty
    selectBest xs  = case filter (isResolved . fst) xs of
      (best:_) -> best
      []       -> head xs

-- | Build an initial (empty) topology from config
buildInitialTopology :: ClusterConfig -> ClusterTopology
buildInitialTopology cc = ClusterTopology
  { ctClusterName          = ccName cc
  , ctNodes                = Map.empty
  , ctSourceNodeId         = Nothing
  , ctHealth               = NeedsAttention "Initializing"
  , ctObservedHealthy      = False
  , ctRecoveryBlockedUntil = Nothing
  , ctLastFailoverAt       = Nothing
  , ctPaused               = False
  , ctTopologyDrift        = False
  }
