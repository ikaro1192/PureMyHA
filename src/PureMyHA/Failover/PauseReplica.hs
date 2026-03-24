module PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Database.MySQL.Base (MySQLConn)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, appLogInfo, appLogError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (stopReplica, startReplica)
import PureMyHA.Topology.State (getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Pause replication on a replica node for maintenance
runPauseReplica
  :: Text       -- ^ host to pause
  -> App (Either Text ())
runPauseReplica targetHost =
  withTargetNode "Pausing" targetHost stopReplica (\ns -> ns { nsPaused = True })

-- | Resume replication on a paused replica node
runResumeReplica
  :: Text       -- ^ host to resume
  -> App (Either Text ())
runResumeReplica targetHost =
  withTargetNode "Resuming" targetHost startReplica (\ns -> ns { nsPaused = False })

-- | Common logic for pause/resume: find node, connect, run action, update state.
withTargetNode
  :: Text                            -- ^ action name for logging (e.g. "Pausing")
  -> Text                            -- ^ target host
  -> (MySQLConn -> IO ())            -- ^ MySQL action to execute
  -> (NodeState -> NodeState)        -- ^ state update on success
  -> App (Either Text ())
withTargetNode actionName targetHost mysqlAction stateUpdate = do
  tvar  <- asks envDaemonState
  cc    <- asks envCluster
  creds <- getMonCredentials
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case findNodeByHost targetHost (ctNodes topo) of
        Nothing -> pure (Left $ "Node not found: " <> targetHost)
        Just targetNs -> do
          let ci = makeConnectInfo (nsNodeId targetNs) creds
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] " <> actionName <> " replication on " <> targetHost
          result <- liftIO $ withNodeConn ci $ \conn -> mysqlAction conn
          case result of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] " <> actionName <> " failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc) (stateUpdate targetNs)
              appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Replication " <> actionResult <> " on " <> targetHost
              pure (Right ())
  where
    actionResult = case actionName of
      "Pausing"  -> "paused"
      "Resuming" -> "resumed"
      other      -> other
