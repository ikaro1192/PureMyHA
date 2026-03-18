module PureMyHA.Failover.Demote (runDemote) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..), Credentials (..))
import PureMyHA.Logger (Logger, logInfo, logError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
  ( stopReplica, setReadOnly, changeReplicationSourceTo, startReplica )
import PureMyHA.Topology.State (TVarDaemonState, getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Demote a node to replica under a specified source
runDemote
  :: TVarDaemonState
  -> ClusterConfig
  -> Text       -- ^ password
  -> Text       -- ^ host to demote
  -> Text       -- ^ new source host
  -> Logger
  -> IO (Either Text ())
runDemote tvar cc password demoteHost srcHost logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          user  = credUser (ccCredentials cc)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case (findByHost demoteHost, findByHost srcHost) of
        ([], _) -> pure (Left $ "Node not found: " <> demoteHost)
        (_, []) -> pure (Left $ "Node not found: " <> srcHost)
        (demoteNs : _, srcNs : _) -> do
          let demoteId = nsNodeId demoteNs
              srcId    = nsNodeId srcNs
              ci       = makeConnectInfo demoteId user password
          logInfo logger $ "[" <> ccName cc <> "] Demoting " <> demoteHost
                        <> " to replica under " <> srcHost
          result <- withNodeConn ci $ \conn -> do
            stopReplica conn
            setReadOnly conn
            changeReplicationSourceTo conn (nodeHost srcId) (nodePort srcId)
            startReplica conn
          case result of
            Left err -> do
              logError logger $ "[" <> ccName cc <> "] Demote failed: " <> err
              pure (Left err)
            Right () -> do
              atomically $ updateNodeState tvar (ccName cc)
                (demoteNs { nsIsSource = False })
              logInfo logger $ "[" <> ccName cc <> "] Demote completed: "
                            <> demoteHost <> " is now a replica"
              pure (Right ())
