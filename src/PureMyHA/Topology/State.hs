module PureMyHA.Topology.State
  ( newDaemonState
  , readDaemonState
  , updateNodeState
  , updateClusterTopology
  , getClusterTopology
  , setRecoveryBlock
  , clearRecoveryBlock
  , recordFailover
  , setClusterPause
  , clearClusterPause
  , TVarDaemonState
  , FailoverLock
  , newFailoverLock
  , acquireFailoverLock
  ) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, addUTCTime, NominalDiffTime)
import PureMyHA.Types

type TVarDaemonState = TVar (Map.Map ClusterName (TVar ClusterTopology))
type FailoverLock = TMVar ()

lookupClusterTVar :: TVarDaemonState -> ClusterName -> STM (Maybe (TVar ClusterTopology))
lookupClusterTVar tvar name = Map.lookup name <$> readTVar tvar

newDaemonState :: IO TVarDaemonState
newDaemonState = newTVarIO Map.empty

-- Two-level read: outer Map then all inner TVars
readDaemonState :: TVarDaemonState -> IO DaemonState
readDaemonState tvar = do
  clusterTVars <- readTVarIO tvar
  clusters <- traverse readTVarIO clusterTVars
  pure (DaemonState clusters)

-- Only touches inner TVar; outer TVar stays in STM read-set, never written
updateNodeState :: TVarDaemonState -> ClusterName -> NodeState -> STM ()
updateNodeState tvar clusterName ns = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct ->
      ct { ctNodes = Map.insert (nsNodeId ns) ns (ctNodes ct) }

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
      ct { ctObservedHealthy = ctObservedHealthy prevCt || ctObservedHealthy ct
         , ctPaused = ctPaused prevCt
         }

getClusterTopology :: TVarDaemonState -> ClusterName -> IO (Maybe ClusterTopology)
getClusterTopology tvar name = do
  clusters <- readTVarIO tvar
  case Map.lookup name clusters of
    Nothing    -> pure Nothing
    Just ctVar -> Just <$> readTVarIO ctVar

setRecoveryBlock :: TVarDaemonState -> ClusterName -> UTCTime -> NominalDiffTime -> STM ()
setRecoveryBlock tvar clusterName now period = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct ->
      ct { ctRecoveryBlockedUntil = Just (addUTCTime period now) }

clearRecoveryBlock :: TVarDaemonState -> ClusterName -> STM ()
clearRecoveryBlock tvar clusterName = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct -> ct { ctRecoveryBlockedUntil = Nothing }

recordFailover :: TVarDaemonState -> ClusterName -> UTCTime -> STM ()
recordFailover tvar clusterName now = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct -> ct { ctLastFailoverAt = Just now }

newFailoverLock :: IO FailoverLock
newFailoverLock = newTMVarIO ()

-- | Non-blocking acquire; returns True if acquired, False if already locked
acquireFailoverLock :: FailoverLock -> STM Bool
acquireFailoverLock lock = do
  mt <- tryTakeTMVar lock
  pure (mt /= Nothing)

setClusterPause :: TVarDaemonState -> ClusterName -> STM ()
setClusterPause tvar clusterName = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct -> ct { ctPaused = True }

clearClusterPause :: TVarDaemonState -> ClusterName -> STM ()
clearClusterPause tvar clusterName = do
  mctVar <- lookupClusterTVar tvar clusterName
  case mctVar of
    Nothing    -> pure ()
    Just ctVar -> modifyTVar' ctVar $ \ct -> ct { ctPaused = False }
