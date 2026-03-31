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
import PureMyHA.Logger (nullLogger)
import PureMyHA.Topology.State (TVarDaemonState, newFailoverLock)
import PureMyHA.Types

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2024 1 1) 0

mkNodeId :: Text -> Int -> NodeId
mkNodeId h p = NodeId (mkHostInfoFromName (HostName h)) p

mkReplicaStatus :: Text -> Int -> IORunning -> Text -> ReplicaStatus
mkReplicaStatus srcHost srcPort ioRunning execGtid = ReplicaStatus
  { rsSourceHost          = HostName srcHost
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
  { nsNodeId              = nid
  , nsRole                = role
  , nsHealth              = health
  , nsProbeResult         = ProbeSuccess fixedTime mRs ""
  , nsErrantGtids         = ""
  , nsPaused              = False
  , nsConsecutiveFailures = 0
  , nsFenced              = False
  }

-- | Build a test ClusterEnv with dummy values for fields not under test
mkTestEnv :: TVarDaemonState -> ClusterConfig -> FailoverConfig -> IO ClusterEnv
mkTestEnv tvar cc fc = do
  let pws = ClusterPasswords (DbCredentials "" "") (DbCredentials "" "")
      fdc = FailureDetectionConfig 0 (AtLeastOne 3)
  mcVar    <- newTVarIO (MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1)
  hooksVar <- newTVarIO Nothing
  lock     <- newFailoverLock
  logger    <- nullLogger
  loggerVar <- newTVarIO logger
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
    , envTLS         = Nothing
    }

healthySource :: NodeState
healthySource = mkNodeState (mkNodeId "db1" 3306) Source Nothing Healthy

healthyReplica :: NodeState
healthyReplica = mkNodeState (mkNodeId "db2" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) Healthy

replicaWithErrantGtid :: NodeState
replicaWithErrantGtid = (mkNodeState (mkNodeId "db3" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100"))
  (ErrantGtidDetected "uuid3:1"))
  { nsErrantGtids = "uuid3:1" }

replicaWithIOError :: NodeState
replicaWithIOError = mkNodeState (mkNodeId "db4" 3306) Replica
  (Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-50")
    { rsLastIOError = "Access denied" })
  (ReplicaIOStopped "Access denied")

unreachableNode :: NodeId -> NodeState
unreachableNode nid = NodeState
  { nsNodeId              = nid
  , nsRole                = Replica
  , nsHealth              = NodeUnreachable "Connection refused"
  , nsProbeResult         = ProbeFailure "Connection refused"
  , nsErrantGtids         = ""
  , nsPaused              = False
  , nsConsecutiveFailures = 0
  , nsFenced              = False
  }

unreachableReplica :: NodeState
unreachableReplica = unreachableNode (NodeId (mkHostInfoFromName "db5") 3306)

-- | Cluster where source is unreachable, replicas show IO=No
clusterWithDeadSource :: Map NodeId NodeState
clusterWithDeadSource = Map.fromList
  [ (mkNodeId "db1" 3306, (unreachableNode (mkNodeId "db1" 3306)) { nsRole = Source })
  , (mkNodeId "db2" 3306, NodeState
      { nsNodeId              = mkNodeId "db2" 3306
      , nsRole                = Replica
      , nsHealth              = Healthy
      , nsProbeResult         = ProbeSuccess fixedTime (Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-100")) ""
      , nsErrantGtids         = ""
      , nsPaused              = False
      , nsConsecutiveFailures = 0
      , nsFenced              = False
      })
  ]

-- | A healthy 2-node cluster
clusterHealthy :: Map NodeId NodeState
clusterHealthy = Map.fromList
  [ (mkNodeId "db1" 3306, healthySource)
  , (mkNodeId "db2" 3306, healthyReplica)
  ]
