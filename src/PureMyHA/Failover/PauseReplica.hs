module PureMyHA.Failover.PauseReplica
  ( runPauseReplica
  , runResumeReplica
  , runStopReplication
  , runStartReplication
  ) where

import Control.Concurrent.STM (atomically, writeTBQueue)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Database.MySQL.Base (MySQLConn)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getTLSConfig, appLogInfo, appLogError)
import PureMyHA.Supervisor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (stopReplica, startReplica)
import PureMyHA.Topology.State (getClusterTopology)
import PureMyHA.Types

-- | Pause monitoring on a replica node (exclude from failover candidates).
-- Does NOT execute STOP REPLICA — use 'runStopReplication' for that.
runPauseReplica
  :: HostName   -- ^ host to pause
  -> App (Either Text ())
runPauseReplica targetHost =
  withTargetNodeNoMySQL "Pausing" targetHost ReplicaPaused

-- | Resume monitoring on a paused replica node (re-include in failover candidates).
-- Does NOT execute START REPLICA — use 'runStartReplication' for that.
runResumeReplica
  :: HostName   -- ^ host to resume
  -> App (Either Text ())
runResumeReplica targetHost =
  withTargetNodeNoMySQL "Resuming" targetHost ReplicaResumed

-- | Stop MySQL replication on a replica node.
-- Executes STOP REPLICA and automatically pauses monitoring (nsPaused=True).
runStopReplication
  :: HostName   -- ^ host to stop replication on
  -> App (Either Text ())
runStopReplication targetHost =
  withTargetNode "Stopping" targetHost stopReplica ReplicaPaused

-- | Start MySQL replication on a replica node.
-- Executes START REPLICA and automatically resumes monitoring (nsPaused=False).
runStartReplication
  :: HostName   -- ^ host to start replication on
  -> App (Either Text ())
runStartReplication targetHost =
  withTargetNode "Starting" targetHost startReplica ReplicaResumed

-- | Emit an event for a target node without connecting to MySQL.
-- Used for pause/resume which only change daemon-side state.
withTargetNodeNoMySQL
  :: Text                            -- ^ action name for logging
  -> HostName                        -- ^ target host
  -> (NodeId -> MonitorEvent)        -- ^ event constructor on success
  -> App (Either Text ())
withTargetNodeNoMySQL actionName targetHost mkEvent = do
  tvar  <- asks envDaemonState
  cc    <- asks envCluster
  queue <- asks envEventQueue
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case findNodeByHost targetHost (ctNodes topo) of
        Nothing -> pure (Left $ "Node not found: " <> unHostName targetHost)
        Just targetNs -> do
          liftIO $ atomically $ writeTBQueue queue (mkEvent (nsNodeId targetNs))
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] " <> actionName <> " replica " <> unHostName targetHost
          pure (Right ())

-- | Common logic for stop/start-replication: find node, connect, run MySQL action, emit event.
withTargetNode
  :: Text                            -- ^ action name for logging (e.g. "Stopping")
  -> HostName                        -- ^ target host
  -> (MySQLConn -> IO ())            -- ^ MySQL action to execute
  -> (NodeId -> MonitorEvent)        -- ^ event constructor on success
  -> App (Either Text ())
withTargetNode actionName targetHost mysqlAction mkEvent = do
  tvar  <- asks envDaemonState
  cc    <- asks envCluster
  queue <- asks envEventQueue
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case findNodeByHost targetHost (ctNodes topo) of
        Nothing -> pure (Left $ "Node not found: " <> unHostName targetHost)
        Just targetNs -> do
          let ci = makeConnectInfo (nsNodeId targetNs) creds
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] " <> actionName <> " replication on " <> unHostName targetHost
          result <- liftIO $ withNodeConn mTls ci $ \conn -> mysqlAction conn
          case result of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] " <> actionName <> " failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ writeTBQueue queue (mkEvent (nsNodeId targetNs))
              appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Replication " <> actionResult <> " on " <> unHostName targetHost
              pure (Right ())
  where
    actionResult = case actionName of
      "Stopping" -> "stopped"
      "Starting" -> "started"
      other      -> other
