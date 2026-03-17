module Fixtures
  ( mkNodeState
  , mkReplicaStatus
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

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime, fromGregorian, UTCTime (..))
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
  , rsReplicaSQLRunning   = True
  , rsSecondsBehindSource = Just 0
  , rsExecutedGtidSet     = execGtid
  , rsRetrievedGtidSet    = execGtid
  , rsLastIOError         = ""
  , rsLastSQLError        = ""
  }

mkNodeState :: NodeId -> Bool -> Maybe ReplicaStatus -> NodeHealth -> NodeState
mkNodeState nid isSource mRs health = NodeState
  { nsNodeId          = nid
  , nsReplicaStatus   = mRs
  , nsGtidExecuted    = ""
  , nsIsSource        = isSource
  , nsHealth          = health
  , nsLastSeen        = Just fixedTime
  , nsConnectError    = Nothing
  , nsErrantGtids     = ""
  }

healthySource :: NodeState
healthySource = mkNodeState (mkNodeId "db1" 3306) True Nothing Healthy

healthyReplica :: NodeState
healthyReplica = mkNodeState (mkNodeId "db2" 3306) False
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100")) Healthy

replicaWithErrantGtid :: NodeState
replicaWithErrantGtid = (mkNodeState (mkNodeId "db3" 3306) False
  (Just (mkReplicaStatus "db1" 3306 IOYes "uuid1:1-100"))
  (NeedsAttention "Errant GTIDs: uuid3:1"))
  { nsErrantGtids = "uuid3:1" }

replicaWithIOError :: NodeState
replicaWithIOError = mkNodeState (mkNodeId "db4" 3306) False
  (Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-50")
    { rsLastIOError = "Access denied" })
  (NeedsAttention "IO error: Access denied")

unreachableNode :: NodeId -> NodeState
unreachableNode nid = NodeState
  { nsNodeId          = nid
  , nsReplicaStatus   = Nothing
  , nsGtidExecuted    = ""
  , nsIsSource        = False
  , nsHealth          = NeedsAttention "Connection refused"
  , nsLastSeen        = Nothing
  , nsConnectError    = Just "Connection refused"
  , nsErrantGtids     = ""
  }

unreachableReplica :: NodeState
unreachableReplica = unreachableNode (NodeId "db5" 3306)

-- | Cluster where source is unreachable, replicas show IO=No
clusterWithDeadSource :: Map NodeId NodeState
clusterWithDeadSource = Map.fromList
  [ (mkNodeId "db1" 3306, (unreachableNode (mkNodeId "db1" 3306)) { nsIsSource = True })
  , (mkNodeId "db2" 3306, NodeState
      { nsNodeId    = mkNodeId "db2" 3306
      , nsReplicaStatus = Just (mkReplicaStatus "db1" 3306 IONo "uuid1:1-100")
      , nsGtidExecuted    = ""
      , nsIsSource  = False
      , nsHealth    = Healthy
      , nsLastSeen  = Just fixedTime
      , nsConnectError = Nothing
      , nsErrantGtids = ""
      })
  ]

-- | A healthy 2-node cluster
clusterHealthy :: Map NodeId NodeState
clusterHealthy = Map.fromList
  [ (mkNodeId "db1" 3306, healthySource)
  , (mkNodeId "db2" 3306, healthyReplica)
  ]
