module PureMyHA.Supervisor.Detector
  ( detectClusterHealth
  , detectNodeHealth
  , detectReplicaHealth
  , identifySource
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (find, nub)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import PureMyHA.MySQL.GTID (isEmptyGtidSet)
import PureMyHA.Types

-- | Detect the overall health of a cluster based on node states
detectClusterHealth :: Int -> Map NodeId NodeState -> NodeHealth
detectClusterHealth minReplicas nodes
  | Map.null nodes = NeedsAttention "No nodes in cluster"
  | otherwise =
      let nodeList = Map.elems nodes
          sourceCandidates = filter isSource nodeList
          reachableNodes = filter nsIsReachable nodeList
      in case sourceCandidates of
           [] -> case identifySource nodeList of
                   Just srcId | Just src <- find (\n -> nsNodeId n == srcId) nodeList ->
                     detectSingleSource minReplicas nodeList reachableNodes src
                   _ -> detectNoSource nodeList reachableNodes
           [_src] -> detectSingleSource minReplicas nodeList reachableNodes _src
           _  -> SplitBrainSuspected

detectNoSource :: [NodeState] -> [NodeState] -> NodeHealth
detectNoSource nodeList reachableNodes
  | null reachableNodes = DeadSourceAndAllReplicas
  | null nodeList       = NeedsAttention "No nodes configured"
  | otherwise           = NoSourceDetected

detectSingleSource :: Int -> [NodeState] -> [NodeState] -> NodeState -> NodeHealth
detectSingleSource minReplicas nodeList reachableNodes src
  | null reachableNodes           = DeadSourceAndAllReplicas
  | not (nsIsReachable src)       = detectDeadSource minReplicas nodeList
  | hasIoError nodeList           = NeedsAttention "Replica IO errors detected"
  | hasIoConnecting nodeList      = NeedsAttention "Replica IO thread not connected"
  | otherwise                     = Healthy

detectDeadSource :: Int -> [NodeState] -> NodeHealth
detectDeadSource minReplicas nodeList =
  let replicas = filter (not . isSource) nodeList
      reachableReplicas = filter nsIsReachable replicas
      replicasWithIONo = filter replicaIOStopped reachableReplicas
      unanimous = length replicasWithIONo == length reachableReplicas
      quorum    = length replicasWithIONo >= minReplicas
  in if null reachableReplicas
       then DeadSourceAndAllReplicas
       else if not unanimous
              then UnreachableSource
              else if quorum
                     then DeadSource
                     else InsufficientQuorum

replicaIOStopped :: NodeState -> Bool
replicaIOStopped ns = case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> rsReplicaIORunning rs /= IOYes
  _ -> False

hasIoError :: [NodeState] -> Bool
hasIoError = any $ \ns -> not (isSource ns) && case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> not (T.null (rsLastIOError rs))
  _ -> False

hasIoConnecting :: [NodeState] -> Bool
hasIoConnecting = any $ \ns -> not (isSource ns) && case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> rsReplicaIORunning rs == IOConnecting
  _ -> False

-- | Detect health for a single node
detectNodeHealth :: Maybe Int -> NodeState -> NodeHealth
detectNodeHealth mLagThreshold ns = case nsProbeResult ns of
  ProbeFailure{prConnectError = e} -> NodeUnreachable e
  ProbeSuccess{prReplicaStatus = mrs}
    | not (isEmptyGtidSet (nsErrantGtids ns)) ->
        ErrantGtidDetected (nsErrantGtids ns)
    | isSource ns -> Healthy  -- Source nodes ignore residual replica status
    | Just rs <- mrs -> detectReplicaHealth mLagThreshold rs
    | otherwise      -> NotReplicating

detectReplicaHealth :: Maybe Int -> ReplicaStatus -> NodeHealth
detectReplicaHealth mLagThreshold rs
  | rsReplicaIORunning rs == IONo && not (T.null (rsLastIOError rs)) =
      ReplicaIOStopped (rsLastIOError rs)
  | rsReplicaIORunning rs == IONo =
      ReplicaIOStopped ""
  | rsReplicaIORunning rs == IOConnecting =
      ReplicaIOConnecting
  | rsReplicaSQLRunning rs == SQLStopped =
      ReplicaSQLStopped (rsLastSQLError rs)
  | Just lag <- rsSecondsBehindSource rs
  , Just threshold <- mLagThreshold
  , lag >= threshold =
      Lagging lag
  | otherwise = Healthy

-- | Identify which node is the source based on topology
identifySource :: [NodeState] -> Maybe NodeId
identifySource nodes =
  let replicaSourcePairs = nub $ mapMaybe getSourceId nodes
      -- A source is a node that is NOT referenced as a replica's source
      -- OR is explicitly marked as source
      explicitSources = filter isSource nodes
  in case explicitSources of
       [s] -> Just (nsNodeId s)
       _   ->
         -- Fall back: find the node whose host:port is referenced by replicas as their source
         let isReferencedAsSource n =
               (nodeHost (nsNodeId n), unPort (nodePort (nsNodeId n))) `elem` replicaSourcePairs
             allSources = filter isReferencedAsSource nodes
         in case allSources of
              [s] -> Just (nsNodeId s)
              _   -> Nothing

getSourceId :: NodeState -> Maybe (HostName, Int)
getSourceId ns = case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs}
    | unHostName (rsSourceHost rs) /= "" -> Just (rsSourceHost rs, rsSourcePort rs)
  _ -> Nothing
