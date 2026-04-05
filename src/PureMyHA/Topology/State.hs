module PureMyHA.Topology.State
  ( newDaemonState
  , readDaemonState
  , updateClusterTopology
  , getClusterTopology
  , getClusterTopologySTM
  , TVarDaemonState
  , FailoverLock
  , newFailoverLock
  , acquireFailoverLock
  ) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import PureMyHA.Types

type TVarDaemonState = TVar (Map.Map ClusterName (TVar ClusterTopology))
type FailoverLock = TMVar ()

newDaemonState :: IO TVarDaemonState
newDaemonState = newTVarIO Map.empty

-- Two-level read: outer Map then all inner TVars
readDaemonState :: TVarDaemonState -> IO DaemonState
readDaemonState tvar = do
  clusterTVars <- readTVarIO tvar
  clusters <- traverse readTVarIO clusterTVars
  pure (DaemonState clusters)

-- On first call: creates inner TVar and writes outer Map (startup only)
-- On subsequent calls: modifyTVar' on inner TVar only
updateClusterTopology :: TVarDaemonState -> ClusterTopology -> STM ()
updateClusterTopology tvar ct = do
  clusters <- readTVar tvar
  let name = ctClusterName ct
  case Map.lookup name clusters of
    Nothing    -> do
      ctVar <- newTVar ct
      writeTVar tvar (Map.insert name ctVar clusters)
    Just ctVar -> modifyTVar' ctVar $ \prevCt ->
      ct { ctObservedHealthy      = ctObservedHealthy prevCt || ctObservedHealthy ct
         , ctPaused               = ctPaused prevCt
         , ctTopologyDrift        = ctTopologyDrift prevCt
         , ctRecoveryBlockedUntil = ctRecoveryBlockedUntil prevCt
         , ctHealth               = ctHealth prevCt
         , ctSourceNodeId         = ctSourceNodeId prevCt
         , ctLastFailoverAt       = ctLastFailoverAt prevCt
         }

getClusterTopology :: TVarDaemonState -> ClusterName -> IO (Maybe ClusterTopology)
getClusterTopology tvar name = do
  clusters <- readTVarIO tvar
  case Map.lookup name clusters of
    Nothing    -> pure Nothing
    Just ctVar -> Just <$> readTVarIO ctVar

getClusterTopologySTM :: TVarDaemonState -> ClusterName -> STM (Maybe ClusterTopology)
getClusterTopologySTM tvar name = do
  mctVar <- Map.lookup name <$> readTVar tvar
  traverse readTVar mctVar

newFailoverLock :: IO FailoverLock
newFailoverLock = newTMVarIO ()

-- | Non-blocking acquire; returns True if acquired, False if already locked
acquireFailoverLock :: FailoverLock -> STM Bool
acquireFailoverLock lock = do
  mt <- tryTakeTMVar lock
  pure (mt /= Nothing)
