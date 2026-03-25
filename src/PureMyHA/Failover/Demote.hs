module PureMyHA.Failover.Demote (runDemote) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getReplCredentials, getTLSConfig, appLogInfo, appLogError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
  ( stopReplica, setReadOnly, changeReplicationSourceTo, startReplica )
import PureMyHA.Topology.State (getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Demote a node to replica under a specified source
runDemote
  :: Text       -- ^ host to demote
  -> Text       -- ^ new source host
  -> App (Either Text ())
runDemote demoteHost srcHost = do
  tvar      <- asks envDaemonState
  cc        <- asks envCluster
  monCreds  <- getMonCredentials
  replCreds <- getReplCredentials
  mTls      <- getTLSConfig
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case (findNodeByHost demoteHost (ctNodes topo), findNodeByHost srcHost (ctNodes topo)) of
        (Nothing, _) -> pure (Left $ "Node not found: " <> demoteHost)
        (_, Nothing) -> pure (Left $ "Node not found: " <> srcHost)
        (Just demoteNs, Just srcNs) -> do
          let demoteId = nsNodeId demoteNs
              srcId    = nsNodeId srcNs
              ci       = makeConnectInfo demoteId monCreds
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Demoting " <> demoteHost
                    <> " to replica under " <> srcHost
          result <- liftIO $ withNodeConn mTls ci $ \conn -> do
            stopReplica conn
            setReadOnly conn
            changeReplicationSourceTo conn (nodeHost srcId) (nodePort srcId) replCreds mTls
            startReplica conn
          case result of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] Demote failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc)
                (demoteNs { nsRole = Replica })
              appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Demote completed: "
                        <> demoteHost <> " is now a replica"
              pure (Right ())
