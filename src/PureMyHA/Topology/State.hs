module PureMyHA.Topology.State
  ( newDaemonState
  , readDaemonState
  , updateNodeState
  , updateClusterTopology
  , getClusterTopology
  , setRecoveryBlock
  , clearRecoveryBlock
  , recordFailover
  , TVarDaemonState
  , FailoverLock
  , newFailoverLock
  , acquireFailoverLock
  ) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, addUTCTime, NominalDiffTime)
import PureMyHA.Types

type TVarDaemonState = TVar DaemonState
type FailoverLock = TMVar ()

newDaemonState :: IO TVarDaemonState
newDaemonState = newTVarIO (DaemonState Map.empty)

readDaemonState :: TVarDaemonState -> IO DaemonState
readDaemonState = readTVarIO

updateNodeState :: TVarDaemonState -> ClusterName -> NodeState -> STM ()
updateNodeState tvar clusterName ns = do
  ds <- readTVar tvar
  let clusters = dsClusters ds
  case Map.lookup clusterName clusters of
    Nothing -> pure ()  -- cluster not yet initialized
    Just ct ->
      let newNodes = Map.insert (nsNodeId ns) ns (ctNodes ct)
          ct'      = ct { ctNodes = newNodes }
      in writeTVar tvar ds { dsClusters = Map.insert clusterName ct' clusters }

updateClusterTopology :: TVarDaemonState -> ClusterTopology -> STM ()
updateClusterTopology tvar ct = do
  ds <- readTVar tvar
  let prevObserved = maybe False ctObservedHealthy (Map.lookup (ctClusterName ct) (dsClusters ds))
      ct' = ct { ctObservedHealthy = prevObserved || ctObservedHealthy ct }
  writeTVar tvar ds { dsClusters = Map.insert (ctClusterName ct) ct' (dsClusters ds) }

getClusterTopology :: TVarDaemonState -> ClusterName -> IO (Maybe ClusterTopology)
getClusterTopology tvar name = do
  ds <- readTVarIO tvar
  pure $ Map.lookup name (dsClusters ds)

setRecoveryBlock :: TVarDaemonState -> ClusterName -> UTCTime -> NominalDiffTime -> STM ()
setRecoveryBlock tvar clusterName now period = do
  ds <- readTVar tvar
  let deadline = addUTCTime period now
  case Map.lookup clusterName (dsClusters ds) of
    Nothing -> pure ()
    Just ct ->
      let ct' = ct { ctRecoveryBlockedUntil = Just deadline }
      in writeTVar tvar ds
           { dsClusters = Map.insert clusterName ct' (dsClusters ds) }

clearRecoveryBlock :: TVarDaemonState -> ClusterName -> STM ()
clearRecoveryBlock tvar clusterName = do
  ds <- readTVar tvar
  case Map.lookup clusterName (dsClusters ds) of
    Nothing -> pure ()
    Just ct ->
      let ct' = ct { ctRecoveryBlockedUntil = Nothing }
      in writeTVar tvar ds
           { dsClusters = Map.insert clusterName ct' (dsClusters ds) }

recordFailover :: TVarDaemonState -> ClusterName -> UTCTime -> STM ()
recordFailover tvar clusterName now = do
  ds <- readTVar tvar
  case Map.lookup clusterName (dsClusters ds) of
    Nothing -> pure ()
    Just ct ->
      let ct' = ct { ctLastFailoverAt = Just now }
      in writeTVar tvar ds
           { dsClusters = Map.insert clusterName ct' (dsClusters ds) }

newFailoverLock :: IO FailoverLock
newFailoverLock = newTMVarIO ()

-- | Non-blocking acquire; returns True if acquired, False if already locked
acquireFailoverLock :: FailoverLock -> STM Bool
acquireFailoverLock lock = do
  mt <- tryTakeTMVar lock
  pure (mt /= Nothing)
