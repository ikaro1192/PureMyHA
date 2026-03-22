module PureMyHA.Event
  ( EventBuffer
  , newEventBuffer
  , recordEvent
  , getRecentEvents
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Foldable (toList)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import PureMyHA.Types (ClusterName, Event (..))

-- | Bounded ring buffer: (events most-recent-first, maxSize)
type EventBuffer = TVar (Seq Event, Int)

newEventBuffer :: Int -> IO EventBuffer
newEventBuffer maxSize = newTVarIO (Seq.empty, maxSize)

-- | Prepend event; truncate to maxSize (oldest events dropped)
recordEvent :: EventBuffer -> Event -> IO ()
recordEvent buf ev = atomically $ modifyTVar' buf $ \(evs, maxSize) ->
  (Seq.take maxSize (ev Seq.<| evs), maxSize)

-- | Return events newest-first, optionally filtered by cluster and limited in count
getRecentEvents :: EventBuffer -> Maybe ClusterName -> Maybe Int -> IO [Event]
getRecentEvents buf mCluster mLimit = do
  (evs, _) <- readTVarIO buf
  let filtered = case mCluster of
        Nothing -> toList evs
        Just cn -> filter ((== cn) . evCluster) (toList evs)
  pure $ case mLimit of
    Nothing -> filtered
    Just n  -> take n filtered
