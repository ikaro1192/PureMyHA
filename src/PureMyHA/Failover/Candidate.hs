module PureMyHA.Failover.Candidate
  ( selectCandidate
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
-- Ranks by:
--   1. candidate_priority config order (lower index = higher priority)
--   2. Executed_Gtid_Set (we use text length as a rough proxy; real comparison is done by MySQL)
selectCandidate
  :: Map NodeId NodeState
  -> [CandidatePriority]
  -> Maybe Text             -- ^ explicit --to host override
  -> Either Text NodeId
selectCandidate nodes priorities mToHost =
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
      let candidates = rankCandidates (Map.elems nodes) priorities
      in case candidates of
           []    -> Left "No suitable failover candidate found"
           (c:_) -> Right (ciNodeId c)

-- | Rank candidate nodes (replicas without errant GTIDs)
rankCandidates :: [NodeState] -> [CandidatePriority] -> [CandidateInfo]
rankCandidates nodes priorities =
  let eligible = filter isEligibleCandidate nodes
      infos    = map (toCandidateInfo priorities) eligible
  in sortBy (comparing ciPriorityRank <> comparing (Down . gtidScore)) infos

isEligibleCandidate :: NodeState -> Bool
isEligibleCandidate ns =
  not (isSource ns)
  && not (hasErrantGtid ns)
  && not (hasConnectError ns)

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
