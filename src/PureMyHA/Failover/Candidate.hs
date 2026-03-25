module PureMyHA.Failover.Candidate
  ( selectCandidate
  , selectSurvivor
  , rankCandidates
  , CandidateInfo (..)
  , isEligibleCandidate
  , hasErrantGtid
  , hasConnectError
  , priorityRank
  , gtidScore
  ) where

import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (comparing, Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import PureMyHA.Types
import PureMyHA.Config (CandidatePriority (..))
import PureMyHA.MySQL.GTID (gtidTransactionCount)

data CandidateInfo = CandidateInfo
  { ciNodeId       :: NodeId
  , ciExecutedGtid :: Text
  , ciPriorityRank :: Int  -- lower is better
  } deriving (Show, Eq)

-- | Select the best failover candidate from a set of replica node states.
-- Excludes:
--   - nodes with errant GTIDs
--   - nodes that are not reachable (have connect errors)
--   - nodes whose health is Lagging
--   - nodes whose lag exceeds maxLag (when specified)
-- Ranks by:
--   1. candidate_priority config order (lower index = higher priority)
--   2. Executed_Gtid_Set (we use text length as a rough proxy; real comparison is done by MySQL)
selectCandidate
  :: Maybe Int              -- ^ max lag in seconds for auto-select candidates (Nothing = no limit)
  -> Map NodeId NodeState
  -> [CandidatePriority]
  -> Maybe Text             -- ^ explicit --to host override
  -> Either Text NodeId
selectCandidate mMaxLag nodes priorities mToHost =
  case mToHost of
    Just toHost ->
      -- Explicit target: validate it exists and has no errant GTIDs
      let matching = Map.elems $ Map.filter
            (\ns -> nodeHost (nsNodeId ns) == toHost && not (isSource ns))
            nodes
      in case matching of
           []  -> Left $ "Host not found as replica: " <> toHost
           (ns:_)
             | hasErrantGtid ns -> Left $ "Cannot promote: node has errant GTIDs: " <> toHost
             | hasConnectError ns -> Left $ "Cannot promote: node unreachable: " <> toHost
             | otherwise -> Right (nsNodeId ns)
    Nothing ->
      -- Auto-select: filter, rank, pick best
      let candidates = rankCandidates mMaxLag (Map.elems nodes) priorities
      in case candidates of
           []    -> Left "No suitable failover candidate found"
           (c:_) -> Right (ciNodeId c)

-- | Rank candidate nodes (replicas without errant GTIDs and within lag threshold)
rankCandidates :: Maybe Int -> [NodeState] -> [CandidatePriority] -> [CandidateInfo]
rankCandidates mMaxLag nodes priorities =
  let eligible = filter (isEligibleCandidate mMaxLag) nodes
      infos    = map (toCandidateInfo priorities) eligible
  in sortBy (comparing ciPriorityRank <> comparing (Down . gtidScore)) infos

isEligibleCandidate :: Maybe Int -> NodeState -> Bool
isEligibleCandidate mMaxLag ns =
  not (isSource ns)
  && not (hasErrantGtid ns)
  && not (hasConnectError ns)
  && not (isLagging ns)
  && not (exceedsMaxLag mMaxLag ns)

isLagging :: NodeState -> Bool
isLagging ns = case nsHealth ns of
  Lagging _ -> True
  _         -> False

exceedsMaxLag :: Maybe Int -> NodeState -> Bool
exceedsMaxLag Nothing  _  = False
exceedsMaxLag (Just maxLag) ns = case nsProbeResult ns of
  ProbeSuccess{prReplicaStatus = Just rs} ->
    maybe False (> maxLag) (rsSecondsBehindSource rs)
  _ -> False

hasErrantGtid :: NodeState -> Bool
hasErrantGtid ns = not (T.null (nsErrantGtids ns))

hasConnectError :: NodeState -> Bool
hasConnectError ns = case nsProbeResult ns of
  ProbeFailure{prConnectError = e} -> not (T.null e)
  ProbeSuccess{}                   -> False

toCandidateInfo :: [CandidatePriority] -> NodeState -> CandidateInfo
toCandidateInfo priorities ns = CandidateInfo
  { ciNodeId       = nsNodeId ns
  , ciExecutedGtid = case nsProbeResult ns of
      ProbeSuccess{prReplicaStatus = Just rs} -> rsExecutedGtidSet rs
      _ -> ""
  , ciPriorityRank = priorityRank priorities (nodeHost (nsNodeId ns))
  }

priorityRank :: [CandidatePriority] -> Text -> Int
priorityRank priorities host =
  case mapMaybe (\(i, p) -> if cpHost p == host then Just i else Nothing)
         (zip [0..] priorities) of
    (rank:_) -> rank
    []       -> maxBound

-- | Returns the total number of transactions in a GTID set as a score.
gtidScore :: CandidateInfo -> Integer
gtidScore = gtidTransactionCount . ciExecutedGtid

-- | Select the node to keep writable (highest GTID) among a list of source-role
-- nodes during split-brain fencing.  Ranked solely by GTID transaction count —
-- candidate_priority is intentionally ignored because those preferences apply to
-- failover replica selection, not to split-brain survivor identification.
selectSurvivor :: [CandidatePriority] -> [NodeState] -> Maybe NodeId
selectSurvivor _priorities nodes =
  let infos  = map (toSourceCandidateInfo []) nodes
      ranked = sortBy (comparing (Down . gtidScore)) infos
  in case ranked of
       []    -> Nothing
       (c:_) -> Just (ciNodeId c)

-- | Like toCandidateInfo but uses prGtidExecuted so that source nodes
-- (which have no replica status) are ranked correctly.
toSourceCandidateInfo :: [CandidatePriority] -> NodeState -> CandidateInfo
toSourceCandidateInfo priorities ns = CandidateInfo
  { ciNodeId       = nsNodeId ns
  , ciExecutedGtid = case nsProbeResult ns of
      ProbeSuccess{prGtidExecuted = g} -> g
      _                                -> ""
  , ciPriorityRank = priorityRank priorities (nodeHost (nsNodeId ns))
  }
