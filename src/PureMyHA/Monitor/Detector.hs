module PureMyHA.Monitor.Detector
  ( detectClusterHealth
  , detectNodeHealth
  , detectReplicaHealth
  , identifySource
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Maybe (mapMaybe, isJust)
import qualified Data.Text as T
import PureMyHA.Types

-- | Detect the overall health of a cluster based on node states
detectClusterHealth :: Map NodeId NodeState -> NodeHealth
detectClusterHealth nodes
  | Map.null nodes = NeedsAttention "No nodes in cluster"
  | otherwise =
      let nodeList = Map.elems nodes
          sourceCandidates = filter nsIsSource nodeList
          reachableNodes = filter (isJust . nsLastSeen) nodeList
      in case sourceCandidates of
           [] -> detectNoSource nodeList reachableNodes
           [_src] -> detectSingleSource nodeList reachableNodes _src
           _  -> SplitBrainSuspected

detectNoSource :: [NodeState] -> [NodeState] -> NodeHealth
detectNoSource nodeList reachableNodes
  | null reachableNodes = DeadSourceAndAllReplicas
  | null nodeList       = NeedsAttention "No nodes configured"
  | otherwise           = NeedsAttention "No source node detected"

detectSingleSource :: [NodeState] -> [NodeState] -> NodeState -> NodeHealth
detectSingleSource nodeList reachableNodes src
  | null reachableNodes           = DeadSourceAndAllReplicas
  | not (nsIsReachable src)       = detectDeadSource nodeList
  | hasIoError nodeList           = NeedsAttention "Replica IO errors detected"
  | otherwise                     = Healthy

detectDeadSource :: [NodeState] -> NodeHealth
detectDeadSource nodeList =
  let replicas = filter (not . nsIsSource) nodeList
      reachableReplicas = filter nsIsReachable replicas
      replicasWithIONo = filter replicaIOStopped reachableReplicas
  in if null reachableReplicas
       then DeadSourceAndAllReplicas
       else if length replicasWithIONo == length reachableReplicas
              then DeadSource
              else UnreachableSource

nsIsReachable :: NodeState -> Bool
nsIsReachable ns = isJust (nsLastSeen ns) && nsConnectError ns == Nothing

replicaIOStopped :: NodeState -> Bool
replicaIOStopped ns =
  case nsReplicaStatus ns of
    Just rs -> rsReplicaIORunning rs == IONo
    Nothing -> False

hasIoError :: [NodeState] -> Bool
hasIoError = any $ \ns ->
  case nsReplicaStatus ns of
    Just rs -> not (T.null (rsLastIOError rs))
    Nothing -> False

-- | Detect health for a single node
detectNodeHealth :: NodeState -> NodeHealth
detectNodeHealth ns
  | isJust (nsConnectError ns) = NeedsAttention (maybe "" id (nsConnectError ns))
  | not (T.null (nsErrantGtids ns)) =
      NeedsAttention ("Errant GTIDs: " <> nsErrantGtids ns)
  | otherwise = case nsReplicaStatus ns of
      Nothing -> Healthy  -- source or standalone
      Just rs -> detectReplicaHealth rs

detectReplicaHealth :: ReplicaStatus -> NodeHealth
detectReplicaHealth rs
  | rsReplicaIORunning rs == IONo && not (T.null (rsLastIOError rs)) =
      NeedsAttention ("IO error: " <> rsLastIOError rs)
  | rsReplicaIORunning rs == IONo =
      NeedsAttention "Replica IO not running"
  | not (rsReplicaSQLRunning rs) =
      NeedsAttention ("SQL error: " <> rsLastSQLError rs)
  | otherwise = Healthy

-- | Identify which node is the source based on topology
identifySource :: [NodeState] -> Maybe NodeId
identifySource nodes =
  let replicaSourceIds = nub $ mapMaybe getSourceId nodes
      -- A source is a node that is NOT referenced as a replica's source
      -- OR is explicitly marked as source
      explicitSources = filter nsIsSource nodes
  in case explicitSources of
       [s] -> Just (nsNodeId s)
       _   ->
         -- Fall back: node that appears as a source of others
         let allSources = filter (\n -> nsNodeId n `notElem` replicaSourceIds) nodes
         in case allSources of
              [s] -> Just (nsNodeId s)
              _   -> Nothing

getSourceId :: NodeState -> Maybe NodeId
getSourceId ns = case nsReplicaStatus ns of
  Just rs ->
    if rsSourceHost rs /= ""
      then Just (NodeId (rsSourceHost rs) (rsSourcePort rs))
      else Nothing
  Nothing -> Nothing
