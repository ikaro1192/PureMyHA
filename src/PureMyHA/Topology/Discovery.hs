module PureMyHA.Topology.Discovery
  ( discoverTopology
  , buildInitialTopology
  ) where

import Control.Exception (try, SomeException)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Types
import PureMyHA.Monitor.Detector (identifySource, detectClusterHealth)

-- | Discover all nodes reachable from the seed nodes
discoverTopology
  :: ClusterConfig
  -> Text          -- ^ MySQL password
  -> IO ClusterTopology
discoverTopology cc password = do
  let seedNodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
      user = credUser (ccCredentials cc)
  nodeStates <- discoverAll user password (Set.fromList seedNodes) Set.empty Map.empty
  let sourceId = identifySource (Map.elems nodeStates)
      -- Mark source node
      nodeStates' = case sourceId of
        Nothing -> nodeStates
        Just sid -> Map.adjust (\ns -> ns { nsIsSource = True }) sid nodeStates
      health = detectClusterHealth nodeStates'
  pure ClusterTopology
    { ctClusterName          = ccName cc
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
  -> IO (Map NodeId NodeState)
discoverAll user password queue visited acc
  | Set.null queue = pure acc
  | otherwise = do
      let (nid, rest) = Set.deleteFindMin queue
      if Set.member nid visited
        then discoverAll user password rest visited acc
        else do
          ns <- probeNode user password nid
          let visited' = Set.insert nid visited
              acc'     = Map.insert nid ns acc
              -- Discover upstream source if this is a replica
              newNodes = case nsReplicaStatus ns of
                Just rs ->
                  let srcId = NodeId (rsSourceHost rs) (rsSourcePort rs)
                  in if Set.notMember srcId visited' && rsSourceHost rs /= ""
                       then Set.insert srcId rest
                       else rest
                Nothing -> rest
          discoverAll user password newNodes visited' acc'

-- | Probe a single node and return its NodeState
probeNode :: Text -> Text -> NodeId -> IO NodeState
probeNode user password nid = do
  now <- getCurrentTime
  let ci = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    mReplicaStatus <- showReplicaStatus conn
    gtidExec       <- getGtidExecuted conn
    pure (mReplicaStatus, gtidExec)
  case result of
    Left err ->
      pure NodeState
        { nsNodeId          = nid
        , nsReplicaStatus   = Nothing
        , nsGtidExecuted    = ""
        , nsIsSource        = False
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
        , nsIsSource        = mRs == Nothing  -- no replica status = potential source
        , nsHealth          = Healthy
        , nsLastSeen        = Just now
        , nsConnectError    = Nothing
        , nsErrantGtids     = ""
        }

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
