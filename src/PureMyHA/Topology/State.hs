module PureMyHA.Topology.State
  ( newDaemonState
  , readDaemonState
  , updateClusterTopology
  , getClusterTopology
  , getClusterTopologySTM
  , TVarDaemonState (..)
  , lookupClusterTVar
  , FailoverLock (..)
  , newFailoverLock
  , acquireFailoverLock
  ) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import PureMyHA.Types

newtype TVarDaemonState = TVarDaemonState
  { unTVarDaemonState :: TVar (Map.Map ClusterName (TVar ClusterTopology)) }

newtype FailoverLock = FailoverLock { unFailoverLock :: TMVar () }

newDaemonState :: IO TVarDaemonState
newDaemonState = TVarDaemonState <$> newTVarIO Map.empty

-- Two-level read: outer Map then all inner TVars
readDaemonState :: TVarDaemonState -> IO DaemonState
readDaemonState (TVarDaemonState tvar) = do
  clusterTVars <- readTVarIO tvar
  clusters <- traverse readTVarIO clusterTVars
  pure (DaemonState clusters)

-- On first call: creates inner TVar and writes outer Map (startup only)
-- On subsequent calls: modifyTVar' on inner TVar only
updateClusterTopology :: TVarDaemonState -> ClusterTopology -> STM ()
updateClusterTopology (TVarDaemonState tvar) ct = do
  clusters <- readTVar tvar
  let name = ctClusterName ct
  case Map.lookup name clusters of
    Nothing    -> do
      ctVar <- newTVar ct
      writeTVar tvar (Map.insert name ctVar clusters)
    Just ctVar -> modifyTVar' ctVar $ \prevCt ->
      let mergedObserved = case (ctObservedHealthy prevCt, ctObservedHealthy ct) of
            (HasBeenObservedHealthy, _) -> HasBeenObservedHealthy
            (_, HasBeenObservedHealthy) -> HasBeenObservedHealthy
            _                           -> NeverObservedHealthy
      in ct { ctObservedHealthy      = mergedObserved
         , ctPaused               = ctPaused prevCt
         , ctTopologyDrift        = ctTopologyDrift prevCt
         , ctRecoveryBlockedUntil = ctRecoveryBlockedUntil prevCt
         , ctHealth               = ctHealth prevCt
         , ctSourceNodeId         = ctSourceNodeId prevCt
         , ctLastFailoverAt       = ctLastFailoverAt prevCt
         , ctLastEmergencyCheckAt = ctLastEmergencyCheckAt prevCt
         }

getClusterTopology :: TVarDaemonState -> ClusterName -> IO (Maybe ClusterTopology)
getClusterTopology (TVarDaemonState tvar) name = do
  clusters <- readTVarIO tvar
  case Map.lookup name clusters of
    Nothing    -> pure Nothing
    Just ctVar -> Just <$> readTVarIO ctVar

getClusterTopologySTM :: TVarDaemonState -> ClusterName -> STM (Maybe ClusterTopology)
getClusterTopologySTM (TVarDaemonState tvar) name = do
  mctVar <- Map.lookup name <$> readTVar tvar
  traverse readTVar mctVar

-- | Look up the inner cluster TVar by name (used by long-running consumers
-- like the state manager that need a stable handle to a single cluster).
lookupClusterTVar :: TVarDaemonState -> ClusterName -> IO (Maybe (TVar ClusterTopology))
lookupClusterTVar (TVarDaemonState tvar) name =
  Map.lookup name <$> readTVarIO tvar

newFailoverLock :: IO FailoverLock
newFailoverLock = FailoverLock <$> newTMVarIO ()

-- | Non-blocking acquire; returns True if acquired, False if already locked
acquireFailoverLock :: FailoverLock -> STM Bool
acquireFailoverLock (FailoverLock lock) = do
  mt <- tryTakeTMVar lock
  pure (mt /= Nothing)
