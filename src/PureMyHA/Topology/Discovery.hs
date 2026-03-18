module PureMyHA.Topology.Discovery
  ( discoverTopology
  , buildInitialTopology
  , buildNodeStateFromProbe
  , buildClusterTopology
  , nextDiscoveryTargets
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import Control.Monad (when)
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..))
import PureMyHA.Logger (Logger, logInfo)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Types
import PureMyHA.Monitor.Detector (identifySource, detectClusterHealth)

-- | Discover all nodes reachable from the seed nodes
discoverTopology
  :: ClusterConfig
  -> Text          -- ^ MySQL password
  -> Logger
  -> IO ClusterTopology
discoverTopology cc password logger = do
  let seedNodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
      user = credUser (ccCredentials cc)
  nodeStates <- discoverAll user password (Set.fromList seedNodes) Set.empty Map.empty logger
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
        Just sid -> Map.adjust (\ns -> ns { nsIsSource = True }) sid nodeStates
      health      = detectClusterHealth nodeStates'
  in ClusterTopology
       { ctClusterName          = name
       , ctNodes                = nodeStates'
       , ctSourceNodeId         = sourceId
       , ctHealth               = health
       , ctRecoveryBlockedUntil = Nothing
       , ctLastFailoverAt       = Nothing
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
  | Set.null queue = pure acc
  | otherwise = do
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
  now <- getCurrentTime
  let ci = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    mReplicaStatus <- showReplicaStatus conn
    gtidExec       <- getGtidExecuted conn
    replicaIds <- case mReplicaStatus of
      Just _  -> pure []
      Nothing -> do
        -- source node: discover downstream replicas via SHOW PROCESSLIST
        discovered <- showReplicas conn (nodePort nid)
        expected   <- countExpectedReplicas conn
        when (length discovered /= expected) $
          logInfo logger $ "[" <> nodeHost nid <> "] SHOW REPLICAS reports "
            <> T.pack (show expected) <> " replica(s) but "
            <> T.pack (show (length discovered))
            <> " found via SHOW PROCESSLIST (replicas without report_host may be missing)"
        pure discovered
    pure (mReplicaStatus, gtidExec, replicaIds)
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
  { nsNodeId        = nid
  , nsReplicaStatus = Nothing
  , nsGtidExecuted  = ""
  , nsIsSource      = False
  , nsHealth        = NeedsAttention err
  , nsLastSeen      = Nothing
  , nsConnectError  = Just err
  , nsErrantGtids   = ""
  }
buildNodeStateFromProbe nid now (Right (mRs, gtidExec)) = NodeState
  { nsNodeId        = nid
  , nsReplicaStatus = mRs
  , nsGtidExecuted  = gtidExec
  , nsIsSource      = mRs == Nothing  -- no replica status = potential source
  , nsHealth        = Healthy
  , nsLastSeen      = Just now
  , nsConnectError  = Nothing
  , nsErrantGtids   = ""
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
  , ctRecoveryBlockedUntil = Nothing
  , ctLastFailoverAt       = Nothing
  }
