module PureMyHA.Topology.Discovery
  ( discoverTopology
  , buildInitialTopology
  , buildNodeStateFromProbe
  , buildClusterTopology
  , nextDiscoveryTargets
  ) where

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
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..))
import PureMyHA.Env (App, envCluster, envLogger, getMySQLUser, getMonPassword)
import PureMyHA.Logger (Logger, logInfo)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Types
import PureMyHA.Monitor.Detector (identifySource, detectClusterHealth)

-- | Discover all nodes reachable from the seed nodes
discoverTopology :: App ClusterTopology
discoverTopology = do
  cc       <- asks envCluster
  user     <- getMySQLUser
  password <- getMonPassword
  logger   <- asks envLogger >>= liftIO . readTVarIO
  let seedNodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
  nodeStates <- liftIO $ discoverAll user password (Set.fromList seedNodes) Set.empty Map.empty logger
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
       }

-- | Recursively discover nodes
discoverAll
  :: Text              -- ^ user
  -> Text              -- ^ password
  -> Set NodeId        -- ^ queue
  -> Set NodeId        -- ^ visited
  -> Map NodeId NodeState
  -> Logger
  -> IO (Map NodeId NodeState)
discoverAll user password queue visited acc logger
  | Set.null queue = do
      logInfo logger $ "[discovery] Queue empty, discovery complete (" <> T.pack (show (Map.size acc)) <> " node(s))"
      pure acc
  | otherwise = do
      logInfo logger $ "[discovery] Queue: " <> T.pack (show (map (\n -> nodeHost n <> ":" <> T.pack (show (nodePort n))) (Set.toList queue)))
      let (nid, rest) = Set.deleteFindMin queue
      if Set.member nid visited
        then discoverAll user password rest visited acc logger
        else do
          (ns, replicaIds) <- probeNode user password nid logger
          let visited'  = Set.insert nid visited
              acc'      = Map.insert nid ns acc
              fromRs    = nextDiscoveryTargets ns visited' rest
              newQueue  = foldr (\rid q -> if Set.notMember rid visited' then Set.insert rid q else q) fromRs replicaIds
          discoverAll user password newQueue visited' acc' logger

-- | Probe a single node and return its NodeState plus any replicas discovered
-- via SHOW PROCESSLIST (only populated when the node is a source).
probeNode :: Text -> Text -> NodeId -> Logger -> IO (NodeState, [NodeId])
probeNode user password nid logger = do
  logInfo logger $ "[discovery] Probing " <> nodeHost nid <> ":" <> T.pack (show (nodePort nid))
  now <- getCurrentTime
  let ci = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    mReplicaStatus <- showReplicaStatus conn
    gtidExec       <- getGtidExecuted conn
    replicaIds <- case mReplicaStatus of
      Just rs -> do
        logInfo logger $ "[discovery] " <> nodeHost nid <> " is a replica of " <> rsSourceHost rs <> ":" <> T.pack (show (rsSourcePort rs))
        pure []
      Nothing -> do
        -- source node: discover downstream replicas via SHOW REPLICAS + SHOW PROCESSLIST
        (discovered, expected, rawHosts) <- showReplicas conn (nodePort nid)
        logInfo logger $ "[" <> nodeHost nid <> "] Raw hosts from SHOW REPLICAS/PROCESSLIST: "
          <> T.pack (show rawHosts)
        logInfo logger $ "[" <> nodeHost nid <> "] Resolved replica NodeIds: "
          <> T.pack (show (map (\n -> nodeHost n <> ":" <> T.pack (show (nodePort n))) discovered))
          <> " (SHOW REPLICAS reports " <> T.pack (show expected) <> " replica(s))"
        when (length discovered < expected) $
          logInfo logger $ "[" <> nodeHost nid <> "] WARNING: found "
            <> T.pack (show (length discovered)) <> " of " <> T.pack (show expected)
            <> " expected replica(s). Ensure the monitoring user has PROCESS privilege "
            <> "or set report_host on each replica."
        pure discovered
    pure (mReplicaStatus, gtidExec, replicaIds)
  case result of
    Left err -> logInfo logger $ "[discovery] " <> nodeHost nid <> " probe failed: " <> err
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
  { nsNodeId               = nid
  , nsReplicaStatus        = Nothing
  , nsGtidExecuted         = ""
  , nsRole                 = Replica
  , nsHealth               = NeedsAttention err
  , nsLastSeen             = Nothing
  , nsConnectError         = Just err
  , nsErrantGtids          = ""
  , nsPaused               = False
  , nsConsecutiveFailures  = 0
  }
buildNodeStateFromProbe nid now (Right (mRs, gtidExec)) = NodeState
  { nsNodeId               = nid
  , nsReplicaStatus        = mRs
  , nsGtidExecuted         = gtidExec
  , nsRole                 = if mRs == Nothing then Source else Replica  -- no replica status = potential source
  , nsHealth               = Healthy
  , nsLastSeen             = Just now
  , nsConnectError         = Nothing
  , nsErrantGtids          = ""
  , nsPaused               = False
  , nsConsecutiveFailures  = 0
  }

-- | Calculate next nodes to probe from a discovered node's replica status (pure)
nextDiscoveryTargets
  :: NodeState
  -> Set NodeId  -- ^ visited
  -> Set NodeId  -- ^ current remaining queue
  -> Set NodeId
nextDiscoveryTargets ns visited rest =
  case nsReplicaStatus ns of
    Just rs ->
      let srcId = NodeId (rsSourceHost rs) (rsSourcePort rs)
      in if Set.notMember srcId visited && rsSourceHost rs /= ""
           then Set.insert srcId rest
           else rest
    Nothing -> rest

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
  }
