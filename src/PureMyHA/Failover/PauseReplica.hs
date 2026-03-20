module PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMySQLUser, getMonPassword, appLogInfo, appLogError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (stopReplica, startReplica)
import PureMyHA.Topology.State (getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Pause replication on a replica node for maintenance
runPauseReplica
  :: Text       -- ^ host to pause
  -> App (Either Text ())
runPauseReplica targetHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  user <- getMySQLUser
  password <- getMonPassword
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case findByHost targetHost of
        [] -> pure (Left $ "Node not found: " <> targetHost)
        (targetNs : _) -> do
          let ci = makeConnectInfo (nsNodeId targetNs) user password
          appLogInfo $ "[" <> ccName cc <> "] Pausing replication on " <> targetHost
          result <- liftIO $ withNodeConn ci $ \conn -> stopReplica conn
          case result of
            Left err -> do
              appLogError $ "[" <> ccName cc <> "] Pause failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc)
                (targetNs { nsPaused = True })
              appLogInfo $ "[" <> ccName cc <> "] Replication paused on " <> targetHost
              pure (Right ())

-- | Resume replication on a paused replica node
runResumeReplica
  :: Text       -- ^ host to resume
  -> App (Either Text ())
runResumeReplica targetHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  user <- getMySQLUser
  password <- getMonPassword
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case findByHost targetHost of
        [] -> pure (Left $ "Node not found: " <> targetHost)
        (targetNs : _) -> do
          let ci = makeConnectInfo (nsNodeId targetNs) user password
          appLogInfo $ "[" <> ccName cc <> "] Resuming replication on " <> targetHost
          result <- liftIO $ withNodeConn ci $ \conn -> startReplica conn
          case result of
            Left err -> do
              appLogError $ "[" <> ccName cc <> "] Resume failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc)
                (targetNs { nsPaused = False })
              appLogInfo $ "[" <> ccName cc <> "] Replication resumed on " <> targetHost
              pure (Right ())
