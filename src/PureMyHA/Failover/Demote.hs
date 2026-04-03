module PureMyHA.Failover.Demote (runDemote, dryRunDemote) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import qualified Data.Text as T
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getReplCredentials, getTLSConfig, appLogInfo, appLogError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
  ( stopReplica, setReadOnly, changeReplicationSourceTo, startReplica )
import PureMyHA.Topology.State (getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Dry-run demote: show SQL statements that would be executed without running them
dryRunDemote
  :: HostName   -- ^ host to demote
  -> HostName   -- ^ new source host
  -> App (Either Text Text)
dryRunDemote demoteHost srcHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case (findNodeByHost demoteHost (ctNodes topo), findNodeByHost srcHost (ctNodes topo)) of
        (Nothing, _) -> pure (Left $ "Node not found: " <> unHostName demoteHost)
        (_, Nothing) -> pure (Left $ "Node not found: " <> unHostName srcHost)
        (Just _, Just srcNs) ->
          let srcId = nsNodeId srcNs
              port  = T.pack (show (nodePort srcId))
          in pure . Right . T.unlines $
               [ "Dry run: would execute on " <> unHostName demoteHost <> ":"
               , "  STOP REPLICA"
               , "  SET GLOBAL read_only = ON"
               , "  CHANGE REPLICATION SOURCE TO SOURCE_HOST='" <> unHostName srcHost
                 <> "', SOURCE_PORT=" <> port <> ", SOURCE_AUTO_POSITION=1, ..."
               , "  START REPLICA"
               ]

-- | Demote a node to replica under a specified source
runDemote
  :: HostName   -- ^ host to demote
  -> HostName   -- ^ new source host
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
        (Nothing, _) -> pure (Left $ "Node not found: " <> unHostName demoteHost)
        (_, Nothing) -> pure (Left $ "Node not found: " <> unHostName srcHost)
        (Just demoteNs, Just srcNs) -> do
          let demoteId = nsNodeId demoteNs
              srcId    = nsNodeId srcNs
              ci       = makeConnectInfo demoteId monCreds
          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Demoting " <> unHostName demoteHost
                    <> " to replica under " <> unHostName srcHost
          result <- liftIO $ withNodeConn mTls ci $ \conn -> do
            stopReplica conn
            setReadOnly conn
            changeReplicationSourceTo conn (unHostName (nodeHost srcId)) (nodePort srcId) replCreds mTls
            startReplica conn
          case result of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] Demote failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc)
                (demoteNs { nsRole = Replica })
              appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Demote completed: "
                        <> unHostName demoteHost <> " is now a replica"
              pure (Right ())
