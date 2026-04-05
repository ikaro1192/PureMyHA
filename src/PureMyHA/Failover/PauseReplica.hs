module PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica) where

import Control.Concurrent.STM (atomically, writeTBQueue)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Database.MySQL.Base (MySQLConn)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getTLSConfig, appLogInfo, appLogError)
import PureMyHA.Monitor.Event (MonitorEvent (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (stopReplica, startReplica)
import PureMyHA.Topology.State (getClusterTopology)
import PureMyHA.Types

-- | Pause replication on a replica node for maintenance
runPauseReplica
  :: HostName   -- ^ host to pause
  -> App (Either Text ())
runPauseReplica targetHost =
  withTargetNode "Pausing" targetHost stopReplica ReplicaPaused

-- | Resume replication on a paused replica node
runResumeReplica
  :: HostName   -- ^ host to resume
  -> App (Either Text ())
runResumeReplica targetHost =
  withTargetNode "Resuming" targetHost startReplica ReplicaResumed

-- | Common logic for pause/resume: find node, connect, run action, emit event.
withTargetNode
  :: Text                            -- ^ action name for logging (e.g. "Pausing")
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
      "Pausing"  -> "paused"
      "Resuming" -> "resumed"
      other      -> other
