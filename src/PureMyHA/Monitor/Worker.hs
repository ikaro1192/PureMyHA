module PureMyHA.Monitor.Worker
  ( startMonitorWorkers
  , monitorNode
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, Async)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, try, catch)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, addUTCTime)
import PureMyHA.Config (ClusterConfig (..), NodeConfig (..), Credentials (..), MonitoringConfig (..), FailoverConfig (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types
import PureMyHA.Monitor.Detector (detectNodeHealth, detectClusterHealth, identifySource)

-- | Start one async monitor worker per node in a cluster
startMonitorWorkers
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> Text             -- ^ password
  -> IO [Async ()]
startMonitorWorkers tvar cc mc password = do
  let nodes = map (\nc -> NodeId (ncHost nc) (ncPort nc)) (ccNodes cc)
  mapM (\nid -> async (runWorker tvar cc mc password nid)) nodes

runWorker
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> Text
  -> NodeId
  -> IO ()
runWorker tvar cc mc password nid = loop
  where
    intervalMicros = round (mcInterval mc * 1_000_000) :: Int
    loop = do
      monitorNode tvar cc mc password nid
        `catch` (\(_ :: SomeException) -> pure ())
      threadDelay intervalMicros
      loop

-- | Perform a single monitoring cycle for a node
monitorNode
  :: TVarDaemonState
  -> ClusterConfig
  -> MonitoringConfig
  -> Text
  -> NodeId
  -> IO ()
monitorNode tvar cc mc password nid = do
  now <- getCurrentTime
  let user = credUser (ccCredentials cc)
      ci   = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    mRs      <- showReplicaStatus conn
    gtidExec <- getGtidExecuted conn
    pure (mRs, gtidExec)
  ns <- case result of
    Left err ->
      pure NodeState
        { nsNodeId          = nid
        , nsReplicaStatus   = Nothing
        , nsGtidExecuted    = ""
        , nsIsSource        = False
        , nsHealth          = NeedsAttention err
        , nsLastSeen        = Nothing
        , nsConnectError    = Just err
        , nsErrantGtids     = ""
        }
    Right (mRs, gtidExec) ->
      pure NodeState
        { nsNodeId          = nid
        , nsReplicaStatus   = mRs
        , nsGtidExecuted    = gtidExec
        , nsIsSource        = mRs == Nothing
        , nsHealth          = Healthy
        , nsLastSeen        = Just now
        , nsConnectError    = Nothing
        , nsErrantGtids     = ""
        }
  -- Update errant GTIDs by querying MySQL
  ns' <- enrichErrantGtids tvar (ccName cc) ns user password
  atomically $ updateNodeState tvar (ccName cc) ns'
  -- Recompute cluster-level health
  recomputeClusterHealth tvar (ccName cc)

enrichErrantGtids :: TVarDaemonState -> ClusterName -> NodeState -> Text -> Text -> IO NodeState
enrichErrantGtids tvar clusterName ns user password = do
  mTopo <- getClusterTopology tvar clusterName
  case mTopo of
    Nothing -> pure ns
    Just topo -> case ctSourceNodeId topo of
      Nothing -> pure ns
      Just srcId -> do
        let srcNodes = Map.lookup srcId (ctNodes topo)
        case srcNodes of
          Nothing -> pure ns
          Just srcNs -> do
            let replicaGtid = maybe "" rsExecutedGtidSet (nsReplicaStatus ns)
                sourceGtid  = nsGtidExecuted srcNs
                ci = makeConnectInfo srcId user password
            result <- withNodeConn ci $ \conn ->
              gtidSubtract conn replicaGtid sourceGtid
            case result of
              Left _         -> pure ns
              Right errant   -> pure ns { nsErrantGtids = errant }

recomputeClusterHealth :: TVarDaemonState -> ClusterName -> IO ()
recomputeClusterHealth tvar clusterName = do
  mTopo <- getClusterTopology tvar clusterName
  case mTopo of
    Nothing -> pure ()
    Just topo -> do
      let newHealth = detectClusterHealth (ctNodes topo)
          newSrcId  = identifySource (Map.elems (ctNodes topo))
          topo' = topo
            { ctHealth       = newHealth
            , ctSourceNodeId = newSrcId
            }
      atomically $ updateClusterTopology tvar topo'
