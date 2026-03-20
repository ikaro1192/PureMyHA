module PureMyHA.Types
  ( NodeId (..)
  , ClusterName
  , IORunning (..)
  , ReplicaStatus (..)
  , NodeHealth (..)
  , NodeState (..)
  , ClusterTopology (..)
  , DaemonState (..)
  , ClusterStatus (..)
  , ClusterTopologyView (..)
  , NodeStateView (..)
  , OperationResult (..)
  , ErrantGtidInfo (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

type ClusterName = Text

data NodeId = NodeId
  { nodeHost :: Text
  , nodePort :: Int
  } deriving (Eq, Ord, Show, Generic)

data IORunning = IOYes | IOConnecting | IONo
  deriving (Eq, Show, Generic)

data ReplicaStatus = ReplicaStatus
  { rsSourceHost          :: Text
  , rsSourcePort          :: Int
  , rsReplicaIORunning    :: IORunning
  , rsReplicaSQLRunning   :: Bool
  , rsSecondsBehindSource :: Maybe Int
  , rsExecutedGtidSet     :: Text
  , rsRetrievedGtidSet    :: Text
  , rsLastIOError         :: Text
  , rsLastSQLError        :: Text
  } deriving (Eq, Show, Generic)

data NodeHealth
  = Healthy
  | DeadSource
  | UnreachableSource
  | DeadSourceAndAllReplicas
  | SplitBrainSuspected
  | NeedsAttention Text
  deriving (Eq, Show, Generic)

data NodeState = NodeState
  { nsNodeId        :: NodeId
  , nsReplicaStatus :: Maybe ReplicaStatus
  , nsGtidExecuted  :: Text
  , nsIsSource      :: Bool
  , nsHealth        :: NodeHealth
  , nsLastSeen      :: Maybe UTCTime
  , nsConnectError  :: Maybe Text
  , nsErrantGtids   :: Text
  , nsPaused        :: Bool
  } deriving (Eq, Show, Generic)

data ClusterTopology = ClusterTopology
  { ctClusterName           :: ClusterName
  , ctNodes                 :: Map NodeId NodeState
  , ctSourceNodeId          :: Maybe NodeId
  , ctHealth                :: NodeHealth
  , ctObservedHealthy       :: Bool             -- True if cluster has ever been Healthy since daemon start
  , ctRecoveryBlockedUntil  :: Maybe UTCTime
  , ctLastFailoverAt        :: Maybe UTCTime
  , ctPaused                :: Bool
  } deriving (Show, Generic)

data DaemonState = DaemonState
  { dsClusters :: Map ClusterName ClusterTopology
  } deriving (Show, Generic)

-- | View types for IPC responses
data ClusterStatus = ClusterStatus
  { csClusterName :: ClusterName
  , csHealth      :: NodeHealth
  , csSourceHost  :: Maybe Text
  , csNodeCount   :: Int
  , csRecoveryBlockedUntil :: Maybe UTCTime
  , csPaused    :: Bool
  } deriving (Show, Eq, Generic)

data ClusterTopologyView = ClusterTopologyView
  { ctvClusterName :: ClusterName
  , ctvNodes       :: [NodeStateView]
  } deriving (Show, Eq, Generic)

data NodeStateView = NodeStateView
  { nsvHost         :: Text
  , nsvPort         :: Int
  , nsvIsSource     :: Bool
  , nsvHealth       :: NodeHealth
  , nsvLagSeconds   :: Maybe Int
  , nsvErrantGtids  :: Text
  , nsvConnectError :: Maybe Text
  , nsvPaused       :: Bool
  } deriving (Show, Eq, Generic)

data OperationResult
  = OperationSuccess Text
  | OperationFailure Text
  deriving (Show, Eq, Generic)

data ErrantGtidInfo = ErrantGtidInfo
  { egiNodeId     :: NodeId
  , egiErrantGtid :: Text
  } deriving (Show, Eq, Generic)
