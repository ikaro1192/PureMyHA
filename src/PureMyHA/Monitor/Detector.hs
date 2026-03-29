module PureMyHA.Monitor.Detector
  ( detectClusterHealth
  , detectNodeHealth
  , detectReplicaHealth
  , identifySource
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import PureMyHA.Types

-- | Detect the overall health of a cluster based on node states
detectClusterHealth :: Map NodeId NodeState -> NodeHealth
detectClusterHealth nodes
  | Map.null nodes = NeedsAttention "No nodes in cluster"
  | otherwise =
      let nodeList = Map.elems nodes
          sourceCandidates = filter isSource nodeList
          reachableNodes = filter nsIsReachable nodeList
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
  | hasIoConnecting nodeList      = NeedsAttention "Replica IO thread not connected"
  | otherwise                     = Healthy

detectDeadSource :: [NodeState] -> NodeHealth
detectDeadSource nodeList =
  let replicas = filter (not . isSource) nodeList
      reachableReplicas = filter nsIsReachable replicas
      replicasWithIONo = filter replicaIOStopped reachableReplicas
  in if null reachableReplicas
       then DeadSourceAndAllReplicas
       else if length replicasWithIONo == length reachableReplicas
              then DeadSource
              else UnreachableSource

replicaIOStopped :: NodeState -> Bool
replicaIOStopped ns = case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> rsReplicaIORunning rs /= IOYes
  _ -> False

hasIoError :: [NodeState] -> Bool
hasIoError = any $ \ns -> case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> not (T.null (rsLastIOError rs))
  _ -> False

hasIoConnecting :: [NodeState] -> Bool
hasIoConnecting = any $ \ns -> case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} -> rsReplicaIORunning rs == IOConnecting
  _ -> False

-- | Detect health for a single node
detectNodeHealth :: Maybe Int -> NodeState -> NodeHealth
detectNodeHealth mLagThreshold ns = case nsProbeResult ns of
  ProbeFailure{prConnectError = e} -> NeedsAttention e
  ProbeSuccess{prReplicaStatus = mrs}
    | not (T.null (nsErrantGtids ns)) ->
        NeedsAttention ("Errant GTIDs: " <> nsErrantGtids ns)
    | Just rs <- mrs -> detectReplicaHealth mLagThreshold rs
    | otherwise      -> Healthy  -- source or standalone

detectReplicaHealth :: Maybe Int -> ReplicaStatus -> NodeHealth
detectReplicaHealth mLagThreshold rs
  | rsReplicaIORunning rs == IONo && not (T.null (rsLastIOError rs)) =
      NeedsAttention ("IO error: " <> rsLastIOError rs)
  | rsReplicaIORunning rs == IONo =
      NeedsAttention "Replica IO not running"
  | rsReplicaIORunning rs == IOConnecting =
      NeedsAttention "Replica IO thread not connected (Connecting)"
  | rsReplicaSQLRunning rs == SQLStopped =
      NeedsAttention ("SQL error: " <> rsLastSQLError rs)
  | Just lag <- rsSecondsBehindSource rs
  , Just threshold <- mLagThreshold
  , lag >= threshold =
      Lagging lag
  | otherwise = Healthy

-- | Identify which node is the source based on topology
identifySource :: [NodeState] -> Maybe NodeId
identifySource nodes =
  let replicaSourceIds = nub $ mapMaybe getSourceId nodes
      -- A source is a node that is NOT referenced as a replica's source
      -- OR is explicitly marked as source
      explicitSources = filter isSource nodes
  in case explicitSources of
       [s] -> Just (nsNodeId s)
       _   ->
         -- Fall back: node that appears as a source of others
         let allSources = filter (\n -> nsNodeId n `notElem` replicaSourceIds) nodes
         in case allSources of
              [s] -> Just (nsNodeId s)
              _   -> Nothing

getSourceId :: NodeState -> Maybe NodeId
getSourceId ns = case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs}
    | unHostName (rsSourceHost rs) /= "" -> Just (NodeId (rsSourceHost rs) (rsSourcePort rs))
  _ -> Nothing
