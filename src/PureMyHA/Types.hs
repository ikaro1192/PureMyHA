{-# LANGUAGE StrictData #-}
module PureMyHA.Types
  ( NodeId (..)
  , nodeHost
  , nodeIPAddr
  , ClusterName (..)
  , HostName (..)
  , IPAddr (..)
  , HostInfo (..)
  , mkHostInfoFromName
  , IORunning (..)
  , SQLThreadState (..)
  , ReplicaStatus (..)
  , NodeHealth (..)
  , healthErrorMessage
  , isUnhealthy
  , NodeRole (..)
  , isSource
  , findNodeByHost
  , ProbeResult (..)
  , NodeState (..)
  , nsIsReachable
  , ClusterTopology (..)
  , DaemonState (..)
  , ClusterStatus (..)
  , ClusterTopologyView (..)
  , NodeStateView (..)
  , OperationResult (..)
  , ErrantGtidInfo (..)
  , HookEvent (..)
  , ClusterAction (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import PureMyHA.MySQL.GTID (GtidSet, renderGtidSet)

newtype ClusterName = ClusterName { unClusterName :: Text }
  deriving (Eq, Ord, Show, Generic)

instance IsString ClusterName where
  fromString = ClusterName . T.pack

instance FromJSON ClusterName where
  parseJSON v = ClusterName <$> parseJSON v

instance ToJSON ClusterName where
  toJSON (ClusterName t) = toJSON t

newtype HostName = HostName { unHostName :: Text }
  deriving (Eq, Ord, Show, Generic)

instance IsString HostName where
  fromString = HostName . T.pack

instance FromJSON HostName where
  parseJSON v = HostName <$> parseJSON v

instance ToJSON HostName where
  toJSON (HostName t) = toJSON t

newtype IPAddr = IPAddr { unIPAddr :: Text }
  deriving (Eq, Ord, Show, Generic)

instance IsString IPAddr where
  fromString = IPAddr . T.pack

instance FromJSON IPAddr where
  parseJSON v = IPAddr <$> parseJSON v

instance ToJSON IPAddr where
  toJSON (IPAddr t) = toJSON t

data HostInfo = HostInfo
  { hiHostName :: HostName
  , hiIPAddr   :: IPAddr
  } deriving (Show, Generic)

instance Eq HostInfo where
  a == b = hiIPAddr a == hiIPAddr b

instance Ord HostInfo where
  compare a b = compare (hiIPAddr a) (hiIPAddr b)

instance IsString HostInfo where
  fromString = mkHostInfoFromName . fromString

-- | Create a HostInfo using the hostname text as both hostname and IP.
-- Used when DNS resolution is not available (pure contexts).
mkHostInfoFromName :: HostName -> HostInfo
mkHostInfoFromName h = HostInfo h (IPAddr (unHostName h))

data NodeId = NodeId
  { nodeHostInfo :: HostInfo
  , nodePort     :: Int
  } deriving (Show, Generic)

instance Eq NodeId where
  a == b = hiIPAddr (nodeHostInfo a) == hiIPAddr (nodeHostInfo b) && nodePort a == nodePort b

instance Ord NodeId where
  compare a b = compare (hiIPAddr (nodeHostInfo a), nodePort a) (hiIPAddr (nodeHostInfo b), nodePort b)

-- | Get the original hostname from a NodeId
nodeHost :: NodeId -> HostName
nodeHost = hiHostName . nodeHostInfo

-- | Get the resolved IP address from a NodeId
nodeIPAddr :: NodeId -> IPAddr
nodeIPAddr = hiIPAddr . nodeHostInfo

data IORunning = IOYes | IOConnecting | IONo
  deriving (Eq, Show, Generic)

data SQLThreadState = SQLRunning | SQLStopped
  deriving (Eq, Show, Generic)

data ReplicaStatus = ReplicaStatus
  { rsSourceHost          :: HostName
  , rsSourcePort          :: Int
  , rsReplicaIORunning    :: IORunning
  , rsReplicaSQLRunning   :: SQLThreadState
  , rsSecondsBehindSource :: Maybe Int
  , rsExecutedGtidSet     :: GtidSet
  , rsRetrievedGtidSet    :: GtidSet
  , rsLastIOError         :: Text
  , rsLastSQLError        :: Text
  } deriving (Eq, Show, Generic)

data NodeHealth
  = Healthy
  | DeadSource
  | InsufficientQuorum          -- ^ All reachable replicas report IO=No, but witness count < min_replicas_for_failover
  | UnreachableSource
  | DeadSourceAndAllReplicas
  | SplitBrainSuspected
  | NodeUnreachable Text         -- ^ Probe connect failure (Text = error message)
  | ReplicaIOStopped Text        -- ^ IO thread = No (Text = last IO error, may be empty)
  | ReplicaIOConnecting          -- ^ IO thread = Connecting (not yet established)
  | ReplicaSQLStopped Text       -- ^ SQL thread stopped (Text = last SQL error)
  | ErrantGtidDetected GtidSet    -- ^ Errant GTIDs present
  | NoSourceDetected             -- ^ Cluster-level: no node has source role
  | NeedsAttention Text          -- ^ Escape hatch for truly unexpected/unclassified conditions
  | Lagging Int
  deriving (Eq, Show, Generic)

-- | Extract a human-readable error message from an unhealthy state, if any.
healthErrorMessage :: NodeHealth -> Maybe Text
healthErrorMessage (NodeUnreachable msg)   = Just msg
healthErrorMessage (ReplicaIOStopped msg)
  | T.null msg = Just "Replica IO not running"
  | otherwise  = Just ("IO error: " <> msg)
healthErrorMessage ReplicaIOConnecting     = Just "Replica IO connecting"
healthErrorMessage (ReplicaSQLStopped msg) = Just ("SQL error: " <> msg)
healthErrorMessage (ErrantGtidDetected g)  = Just ("Errant GTIDs: " <> renderGtidSet g)
healthErrorMessage NoSourceDetected        = Just "No source detected"
healthErrorMessage (NeedsAttention msg)    = Just msg
healthErrorMessage (Lagging n)             = Just ("Lagging " <> T.pack (show n) <> "s")
healthErrorMessage DeadSource              = Just "Dead source"
healthErrorMessage InsufficientQuorum      = Just "Insufficient quorum for dead source confirmation"
healthErrorMessage UnreachableSource       = Just "Unreachable source"
healthErrorMessage DeadSourceAndAllReplicas = Just "Dead source and all replicas"
healthErrorMessage SplitBrainSuspected     = Just "Split brain suspected"
healthErrorMessage Healthy                 = Nothing

-- | Is this health state considered unhealthy?
isUnhealthy :: NodeHealth -> Bool
isUnhealthy Healthy = False
isUnhealthy _       = True

data NodeRole = Source | Replica
  deriving (Eq, Show, Generic)

isSource :: NodeState -> Bool
isSource ns = nsRole ns == Source

findNodeByHost :: HostName -> Map NodeId NodeState -> Maybe NodeState
findNodeByHost h nodes =
  case filter (\ns -> nodeHost (nsNodeId ns) == h) (Map.elems nodes) of
    (x:_) -> Just x
    []    -> Nothing

-- | Result of probing a node. Encodes the invariant that a successful probe
-- always has a last-seen time and optional replica info, while a failed probe
-- always has an error message and never has replica info or a last-seen time.
data ProbeResult
  = ProbeSuccess
      { prLastSeen      :: UTCTime
      , prReplicaStatus :: Maybe ReplicaStatus
      , prGtidExecuted  :: GtidSet
      }
  | ProbeFailure
      { prConnectError  :: Text
      }
  deriving (Eq, Show, Generic)

data NodeState = NodeState
  { nsNodeId              :: NodeId
  , nsRole                :: NodeRole
  , nsHealth              :: NodeHealth
  , nsProbeResult         :: ProbeResult
  , nsErrantGtids         :: GtidSet
  , nsPaused              :: Bool
  , nsConsecutiveFailures :: Int    -- ^ Number of consecutive probe failures; resets to 0 on success
  , nsFenced              :: Bool   -- ^ True if super_read_only was set by auto-fence
  } deriving (Eq, Show, Generic)

-- | True if the last probe succeeded
nsIsReachable :: NodeState -> Bool
nsIsReachable ns = case nsProbeResult ns of
  ProbeSuccess{} -> True
  ProbeFailure{} -> False

data ClusterTopology = ClusterTopology
  { ctClusterName           :: ClusterName
  , ctNodes                 :: Map NodeId NodeState
  , ctSourceNodeId          :: Maybe NodeId
  , ctHealth                :: NodeHealth
  , ctObservedHealthy       :: Bool             -- True if cluster has ever been Healthy since daemon start
  , ctRecoveryBlockedUntil  :: Maybe UTCTime
  , ctLastFailoverAt        :: Maybe UTCTime
  , ctPaused                :: Bool
  , ctTopologyDrift         :: Bool             -- True if topology drift is currently detected
  } deriving (Show, Generic)

data DaemonState = DaemonState
  { dsClusters :: Map ClusterName ClusterTopology
  } deriving (Show, Generic)

-- | View types for IPC responses
data ClusterStatus = ClusterStatus
  { csClusterName :: ClusterName
  , csHealth      :: NodeHealth
  , csSourceHost  :: Maybe HostName
  , csNodeCount   :: Int
  , csRecoveryBlockedUntil :: Maybe UTCTime
  , csPaused    :: Bool
  } deriving (Show, Eq, Generic)

data ClusterTopologyView = ClusterTopologyView
  { ctvClusterName :: ClusterName
  , ctvNodes       :: [NodeStateView]
  } deriving (Show, Eq, Generic)

data NodeStateView = NodeStateView
  { nsvHost         :: HostName
  , nsvPort         :: Int
  , nsvIsSource     :: Bool
  , nsvHealth       :: NodeHealth
  , nsvLagSeconds   :: Maybe Int
  , nsvErrantGtids  :: GtidSet
  , nsvConnectError :: Maybe Text
  , nsvPaused       :: Bool
  , nsvFenced       :: Bool
  } deriving (Show, Eq, Generic)

data OperationResult
  = OperationSuccess Text
  | OperationFailure Text
  deriving (Show, Eq, Generic)

data HookEvent
  = OnFailureDetection Text        -- ^ hookFailureType string ("DeadSource" etc.)
  | OnTopologyDrift Text Text      -- ^ (driftType, driftDetails)
  | OnLagThresholdExceeded Int     -- ^ lag seconds
  | OnLagThresholdRecovered        -- ^ replica recovered from Lagging health
  deriving (Eq, Show)

data ClusterAction
  = TriggerAutoFailover
  | TriggerAutoFence
  | TriggerEmergencyReplicaCheck
  | FireHook HookEvent
  deriving (Eq, Show)

data ErrantGtidInfo = ErrantGtidInfo
  { egiNodeId     :: NodeId
  , egiErrantGtid :: GtidSet
  } deriving (Show, Eq, Generic)

