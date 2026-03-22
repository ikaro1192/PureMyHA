module Fixtures
  ( mkNodeState
  , mkReplicaStatus
  , mkTestEnv
  , fixedTime
  , healthySource
  , healthyReplica
  , replicaWithErrantGtid
  , replicaWithIOError
  , unreachableNode
  , unreachableReplica
  , clusterWithDeadSource
  , clusterHealthy
  ) where

import Control.Concurrent.STM (newTVarIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime, fromGregorian, UTCTime (..))
import PureMyHA.Config
import PureMyHA.Env (ClusterEnv (..))
import PureMyHA.Event (newEventBuffer)
import PureMyHA.Logger (nullLogger)
import PureMyHA.Topology.State (TVarDaemonState, newFailoverLock)
import PureMyHA.Types

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2024 1 1) 0

mkNodeId :: Text -> Int -> NodeId
mkNodeId h p = NodeId h p

mkReplicaStatus :: Text -> Int -> IORunning -> Text -> ReplicaStatus
mkReplicaStatus srcHost srcPort ioRunning execGtid = ReplicaStatus
  { rsSourceHost          = srcHost
  , rsSourcePort          = srcPort
  , rsReplicaIORunning    = ioRunning
  , rsReplicaSQLRunning   = SQLRunning
  , rsSecondsBehindSource = Just 0
  , rsExecutedGtidSet     = execGtid
  , rsRetrievedGtidSet    = execGtid
  , rsLastIOError         = ""
  , rsLastSQLError        = ""
  }

mkNodeState :: NodeId -> NodeRole -> Maybe ReplicaStatus -> NodeHealth -> NodeState
mkNodeState nid role mRs health = NodeState
  { nsNodeId               = nid
  , nsReplicaStatus        = mRs
  , nsGtidExecuted         = ""
  , nsRole                 = role
  , nsHealth               = health
  , nsLastSeen             = Just fixedTime
  , nsConnectError         = Nothing
  , nsErrantGtids          = ""
  , nsPaused               = False
  , nsConsecutiveFailures  = 0
  }

-- | Build a test ClusterEnv with dummy values for fields not under test
mkTestEnv :: TVarDaemonState -> ClusterConfig -> FailoverConfig -> IO ClusterEnv
mkTestEnv tvar cc fc = do
  let pws = ClusterPasswords "" "" ""
      fdc = FailureDetectionConfig 0 3
  mcVar    <- newTVarIO (MonitoringConfig 3 5 30 60 300 1 1)
  hooksVar <- newTVarIO Nothing
  lock     <- newFailoverLock
  logger    <- nullLogger
  loggerVar <- newTVarIO logger
  eventBuf  <- newEventBuffer 100
  pure ClusterEnv
    { envDaemonState = tvar
    , envCluster     = cc
    , envFailover    = fc
    , envDetection   = fdc
    , envPasswords   = pws
    , envMonitoring  = mcVar
    , envHooks       = hooksVar
    , envLock        = lock
    , envLogger      = loggerVar
    , envEventBuffer = eventBuf
    }

healthySource :: NodeState
healthySource = mkNodeState (mkNodeId "db1" 3306) Source Nothing Healthy

healthyReplica :: NodeState
healthyReplica = mkNodeState (mkNodeId "db2" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) Healthy

replicaWithErrantGtid :: NodeState
replicaWithErrantGtid = (mkNodeState (mkNodeId "db3" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100"))
  (NeedsAttention "Errant GTIDs: uuid3:1"))
  { nsErrantGtids = "uuid3:1" }

replicaWithIOError :: NodeState
replicaWithIOError = mkNodeState (mkNodeId "db4" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-50")
    { rsLastIOError = "Access denied" })
  (NeedsAttention "IO error: Access denied")

unreachableNode :: NodeId -> NodeState
unreachableNode nid = NodeState
  { nsNodeId               = nid
  , nsReplicaStatus        = Nothing
  , nsGtidExecuted         = ""
  , nsRole                 = Replica
  , nsHealth               = NeedsAttention "Connection refused"
  , nsLastSeen             = Nothing
  , nsConnectError         = Just "Connection refused"
  , nsErrantGtids          = ""
  , nsPaused               = False
  , nsConsecutiveFailures  = 0
  }

unreachableReplica :: NodeState
unreachableReplica = unreachableNode (NodeId "db5" 3306)

-- | Cluster where source is unreachable, replicas show IO=No
clusterWithDeadSource :: Map NodeId NodeState
clusterWithDeadSource = Map.fromList
  [ (mkNodeId "db1" 3306, (unreachableNode (mkNodeId "db1" 3306)) { nsRole = Source })
  , (mkNodeId "db2" 3306, NodeState
      { nsNodeId               = mkNodeId "db2" 3306
      , nsReplicaStatus        = Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-100")
      , nsGtidExecuted         = ""
      , nsRole                 = Replica
      , nsHealth               = Healthy
      , nsLastSeen             = Just fixedTime
      , nsConnectError         = Nothing
      , nsErrantGtids          = ""
      , nsPaused               = False
      , nsConsecutiveFailures  = 0
      })
  ]

-- | A healthy 2-node cluster
clusterHealthy :: Map NodeId NodeState
clusterHealthy = Map.fromList
  [ (mkNodeId "db1" 3306, healthySource)
  , (mkNodeId "db2" 3306, healthyReplica)
  ]
