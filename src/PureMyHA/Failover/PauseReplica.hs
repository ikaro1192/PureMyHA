module PureMyHA.Failover.PauseReplica (runPauseReplica, runResumeReplica) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..), Credentials (..), ClusterPasswords (..))
import PureMyHA.Logger (Logger, logInfo, logError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query (stopReplica, startReplica)
import PureMyHA.Topology.State (TVarDaemonState, getClusterTopology, updateNodeState)
import PureMyHA.Types

-- | Pause replication on a replica node for maintenance
runPauseReplica
  :: TVarDaemonState
  -> ClusterConfig
  -> ClusterPasswords
  -> Text       -- ^ host to pause
  -> Logger
  -> IO (Either Text ())
runPauseReplica tvar cc pws targetHost logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          user  = credUser (ccCredentials cc)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case findByHost targetHost of
        [] -> pure (Left $ "Node not found: " <> targetHost)
        (targetNs : _) -> do
          let ci = makeConnectInfo (nsNodeId targetNs) user (cpPassword pws)
          logInfo logger $ "[" <> ccName cc <> "] Pausing replication on " <> targetHost
          result <- withNodeConn ci $ \conn -> stopReplica conn
          case result of
            Left err -> do
              logError logger $ "[" <> ccName cc <> "] Pause failed: " <> err
              pure (Left err)
            Right () -> do
              atomically $ updateNodeState tvar (ccName cc)
                (targetNs { nsPaused = True })
              logInfo logger $ "[" <> ccName cc <> "] Replication paused on " <> targetHost
              pure (Right ())

-- | Resume replication on a paused replica node
runResumeReplica
  :: TVarDaemonState
  -> ClusterConfig
  -> ClusterPasswords
  -> Text       -- ^ host to resume
  -> Logger
  -> IO (Either Text ())
runResumeReplica tvar cc pws targetHost logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      let nodes = Map.elems (ctNodes topo)
          user  = credUser (ccCredentials cc)
          findByHost h = filter (\ns -> nodeHost (nsNodeId ns) == h) nodes
      case findByHost targetHost of
        [] -> pure (Left $ "Node not found: " <> targetHost)
        (targetNs : _) -> do
          let ci = makeConnectInfo (nsNodeId targetNs) user (cpPassword pws)
          logInfo logger $ "[" <> ccName cc <> "] Resuming replication on " <> targetHost
          result <- withNodeConn ci $ \conn -> startReplica conn
          case result of
            Left err -> do
              logError logger $ "[" <> ccName cc <> "] Resume failed: " <> err
              pure (Left err)
            Right () -> do
              atomically $ updateNodeState tvar (ccName cc)
                (targetNs { nsPaused = False })
              logInfo logger $ "[" <> ccName cc <> "] Replication resumed on " <> targetHost
              pure (Right ())
