module PureMyHA.Failover.Demote (runDemote) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..), ClusterPasswords (..))
import PureMyHA.Env (App, ClusterEnv (..), getMySQLUser, getMonPassword, appLogInfo, appLogError)
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
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  pws  <- asks envPasswords
  user <- getMySQLUser
  password <- getMonPassword
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case (findByHost demoteHost, findByHost srcHost) of
        ([], _) -> pure (Left $ "Node not found: " <> demoteHost)
        (_, []) -> pure (Left $ "Node not found: " <> srcHost)
        (demoteNs : _, srcNs : _) -> do
          let demoteId = nsNodeId demoteNs
              srcId    = nsNodeId srcNs
              ci       = makeConnectInfo demoteId user password
          appLogInfo $ "[" <> ccName cc <> "] Demoting " <> demoteHost
                    <> " to replica under " <> srcHost
          result <- liftIO $ withNodeConn ci $ \conn -> do
            stopReplica conn
            setReadOnly conn
            changeReplicationSourceTo conn (nodeHost srcId) (nodePort srcId) (cpReplUser pws) (cpReplPassword pws)
            startReplica conn
          case result of
            Left err -> do
              appLogError $ "[" <> ccName cc <> "] Demote failed: " <> err
              pure (Left err)
            Right () -> do
              liftIO $ atomically $ updateNodeState tvar (ccName cc)
                (demoteNs { nsIsSource = False })
              appLogInfo $ "[" <> ccName cc <> "] Demote completed: "
                        <> demoteHost <> " is now a replica"
              pure (Right ())
