module PureMyHA.IPC.Protocol
  ( Request (..)
  , Response (..)
  , NodeStateView (..)
  , ClusterStatus (..)
  , ClusterTopologyView (..)
  , OperationResult (..)
  , ErrantGtidInfo (..)
  , Event (..)
  , EventType (..)
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import GHC.Generics (Generic)
import PureMyHA.Types
  ( ClusterName
  , NodeHealth (..)
  , ClusterStatus (..)
  , ClusterTopologyView (..)
  , NodeStateView (..)
  , OperationResult (..)
  , ErrantGtidInfo (..)
  , NodeId (..)
  , Event (..)
  , EventType (..)
  )
-- JSON instances for core types

instance ToJSON NodeId where
  toJSON NodeId{..} = object ["host" .= nodeHost, "port" .= nodePort]

instance FromJSON NodeId where
  parseJSON = withObject "NodeId" $ \o ->
    NodeId <$> o .: "host" <*> o .: "port"

instance ToJSON NodeHealth where
  toJSON Healthy                    = String "Healthy"
  toJSON DeadSource                 = String "DeadSource"
  toJSON UnreachableSource          = String "UnreachableSource"
  toJSON DeadSourceAndAllReplicas   = String "DeadSourceAndAllReplicas"
  toJSON SplitBrainSuspected        = String "SplitBrainSuspected"
  toJSON (NeedsAttention msg)       = object ["NeedsAttention" .= msg]

instance FromJSON NodeHealth where
  parseJSON (String "Healthy")                  = pure Healthy
  parseJSON (String "DeadSource")               = pure DeadSource
  parseJSON (String "UnreachableSource")        = pure UnreachableSource
  parseJSON (String "DeadSourceAndAllReplicas") = pure DeadSourceAndAllReplicas
  parseJSON (String "SplitBrainSuspected")      = pure SplitBrainSuspected
  parseJSON (Object o)                          = NeedsAttention <$> o .: "NeedsAttention"
  parseJSON _                                   = fail "Invalid NodeHealth"

instance ToJSON ClusterStatus where
  toJSON ClusterStatus{..} = object
    [ "clusterName"           .= csClusterName
    , "health"                .= csHealth
    , "sourceHost"            .= csSourceHost
    , "nodeCount"             .= csNodeCount
    , "recoveryBlockedUntil"  .= csRecoveryBlockedUntil
    , "paused"                .= csPaused
    ]

instance FromJSON ClusterStatus where
  parseJSON = withObject "ClusterStatus" $ \o ->
    ClusterStatus
      <$> o .: "clusterName"
      <*> o .: "health"
      <*> o .: "sourceHost"
      <*> o .: "nodeCount"
      <*> o .: "recoveryBlockedUntil"
      <*> o .: "paused"

instance ToJSON NodeStateView where
  toJSON NodeStateView{..} = object
    [ "host"         .= nsvHost
    , "port"         .= nsvPort
    , "isSource"     .= nsvIsSource
    , "health"       .= nsvHealth
    , "lagSeconds"   .= nsvLagSeconds
    , "errantGtids"  .= nsvErrantGtids
    , "connectError" .= nsvConnectError
    , "paused"       .= nsvPaused
    ]

instance FromJSON NodeStateView where
  parseJSON = withObject "NodeStateView" $ \o ->
    NodeStateView
      <$> o .: "host"
      <*> o .: "port"
      <*> o .: "isSource"
      <*> o .: "health"
      <*> o .: "lagSeconds"
      <*> o .: "errantGtids"
      <*> o .: "connectError"
      <*> o .: "paused"

instance ToJSON ClusterTopologyView where
  toJSON ClusterTopologyView{..} = object
    [ "clusterName" .= ctvClusterName
    , "nodes"       .= ctvNodes
    ]

instance FromJSON ClusterTopologyView where
  parseJSON = withObject "ClusterTopologyView" $ \o ->
    ClusterTopologyView
      <$> o .: "clusterName"
      <*> o .: "nodes"

instance ToJSON OperationResult where
  toJSON (OperationSuccess msg) = object ["success" .= msg]
  toJSON (OperationFailure msg) = object ["failure" .= msg]

instance FromJSON OperationResult where
  parseJSON = withObject "OperationResult" $ \o -> do
    ms <- o .:? "success"
    mf <- o .:? "failure"
    case (ms, mf) of
      (Just s, _) -> pure (OperationSuccess s)
      (_, Just f) -> pure (OperationFailure f)
      _           -> fail "Invalid OperationResult"

instance ToJSON ErrantGtidInfo where
  toJSON ErrantGtidInfo{..} = object
    [ "nodeId"     .= egiNodeId
    , "errantGtid" .= egiErrantGtid
    ]

instance FromJSON ErrantGtidInfo where
  parseJSON = withObject "ErrantGtidInfo" $ \o ->
    ErrantGtidInfo <$> o .: "nodeId" <*> o .: "errantGtid"

instance ToJSON EventType where
  toJSON EvHealthChange      = String "HealthChange"
  toJSON EvClusterHealth     = String "ClusterHealth"
  toJSON EvFailoverStarted   = String "FailoverStarted"
  toJSON EvFailoverCompleted = String "FailoverCompleted"
  toJSON EvFailoverFailed    = String "FailoverFailed"
  toJSON EvSwitchoverCompleted = String "SwitchoverCompleted"
  toJSON EvConfigReloaded    = String "ConfigReloaded"
  toJSON EvPauseChanged      = String "PauseChanged"

instance FromJSON EventType where
  parseJSON (String "HealthChange")       = pure EvHealthChange
  parseJSON (String "ClusterHealth")      = pure EvClusterHealth
  parseJSON (String "FailoverStarted")    = pure EvFailoverStarted
  parseJSON (String "FailoverCompleted")  = pure EvFailoverCompleted
  parseJSON (String "FailoverFailed")     = pure EvFailoverFailed
  parseJSON (String "SwitchoverCompleted") = pure EvSwitchoverCompleted
  parseJSON (String "ConfigReloaded")     = pure EvConfigReloaded
  parseJSON (String "PauseChanged")       = pure EvPauseChanged
  parseJSON _                             = fail "Invalid EventType"

instance ToJSON Event where
  toJSON Event{..} = object
    [ "timestamp" .= evTimestamp
    , "cluster"   .= evCluster
    , "type"      .= evType
    , "node"      .= evNode
    , "details"   .= evDetails
    ]

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o ->
    Event
      <$> o .: "timestamp"
      <*> o .: "cluster"
      <*> o .: "type"
      <*> o .: "node"
      <*> o .: "details"

-- | IPC Request types
data Request
  = ReqStatus   { reqCluster :: Maybe ClusterName }
  | ReqTopology { reqCluster :: Maybe ClusterName }
  | ReqSwitchover { reqCluster :: Maybe ClusterName, reqToHost :: Maybe Text, reqDryRun :: Bool }
  | ReqAckRecovery { reqCluster :: Maybe ClusterName }
  | ReqErrantGtid { reqCluster :: Maybe ClusterName }
  | ReqFixErrantGtid { reqCluster :: Maybe ClusterName }
  | ReqDemote { reqCluster :: Maybe ClusterName, reqDemoteHost :: Text, reqDemoteSourceHost :: Text }
  | ReqDiscovery { reqCluster :: Maybe ClusterName }
  | ReqPauseReplica  { reqCluster :: Maybe ClusterName, reqPauseHost  :: Text }
  | ReqResumeReplica { reqCluster :: Maybe ClusterName, reqResumeHost :: Text }
  | ReqPauseFailover  { reqCluster :: Maybe ClusterName }
  | ReqResumeFailover { reqCluster :: Maybe ClusterName }
  | ReqEventHistory   { reqCluster :: Maybe ClusterName, reqLimit :: Maybe Int }
  deriving (Show, Eq, Generic)

instance ToJSON Request where
  toJSON (ReqStatus mc)          = object ["type" .= ("status" :: Text),         "cluster" .= mc]
  toJSON (ReqTopology mc)        = object ["type" .= ("topology" :: Text),        "cluster" .= mc]
  toJSON (ReqSwitchover mc mh dr) = object ["type" .= ("switchover" :: Text),      "cluster" .= mc, "toHost" .= mh, "dryRun" .= dr]
  toJSON (ReqAckRecovery mc)     = object ["type" .= ("ack-recovery" :: Text),    "cluster" .= mc]
  toJSON (ReqErrantGtid mc)      = object ["type" .= ("errant-gtid" :: Text),     "cluster" .= mc]
  toJSON (ReqFixErrantGtid mc)   = object ["type" .= ("fix-errant-gtid" :: Text), "cluster" .= mc]
  toJSON (ReqDemote mc h s)      = object ["type" .= ("demote" :: Text), "cluster" .= mc, "host" .= h, "sourceHost" .= s]
  toJSON (ReqDiscovery mc)       = object ["type" .= ("discovery" :: Text),       "cluster" .= mc]
  toJSON (ReqPauseReplica  mc h) = object ["type" .= ("pause-replica"  :: Text), "cluster" .= mc, "host" .= h]
  toJSON (ReqResumeReplica mc h) = object ["type" .= ("resume-replica" :: Text), "cluster" .= mc, "host" .= h]
  toJSON (ReqPauseFailover  mc)  = object ["type" .= ("pause-failover"   :: Text), "cluster" .= mc]
  toJSON (ReqResumeFailover mc)  = object ["type" .= ("resume-failover"  :: Text), "cluster" .= mc]
  toJSON (ReqEventHistory mc ml) = object ["type" .= ("event-history"   :: Text), "cluster" .= mc, "limit" .= ml]

instance FromJSON Request where
  parseJSON = withObject "Request" $ \o -> do
    t <- o .: "type" :: Parser Text
    case t of
      "status"          -> ReqStatus        <$> o .:? "cluster"
      "topology"        -> ReqTopology      <$> o .:? "cluster"
      "switchover"      -> ReqSwitchover    <$> o .:? "cluster" <*> o .:? "toHost" <*> o .: "dryRun"
      "ack-recovery"    -> ReqAckRecovery   <$> o .:? "cluster"
      "errant-gtid"     -> ReqErrantGtid    <$> o .:? "cluster"
      "fix-errant-gtid" -> ReqFixErrantGtid <$> o .:? "cluster"
      "demote"          -> ReqDemote        <$> o .:? "cluster" <*> o .: "host" <*> o .: "sourceHost"
      "discovery"       -> ReqDiscovery    <$> o .:? "cluster"
      "pause-replica"   -> ReqPauseReplica  <$> o .:? "cluster" <*> o .: "host"
      "resume-replica"  -> ReqResumeReplica <$> o .:? "cluster" <*> o .: "host"
      "pause-failover"  -> ReqPauseFailover  <$> o .:? "cluster"
      "resume-failover" -> ReqResumeFailover <$> o .:? "cluster"
      "event-history"   -> ReqEventHistory   <$> o .:? "cluster" <*> o .:? "limit"
      _                 -> fail $ "Unknown request type: " <> show t

-- | IPC Response types
data Response
  = RespStatus   [ClusterStatus]
  | RespTopology [ClusterTopologyView]
  | RespOperation OperationResult
  | RespErrantGtids [ErrantGtidInfo]
  | RespEventHistory [Event]
  | RespError Text
  deriving (Show, Eq, Generic)

instance ToJSON Response where
  toJSON (RespStatus cs)        = object ["type" .= ("status" :: Text),         "data" .= cs]
  toJSON (RespTopology tv)      = object ["type" .= ("topology" :: Text),        "data" .= tv]
  toJSON (RespOperation r)      = object ["type" .= ("operation" :: Text),       "data" .= r]
  toJSON (RespErrantGtids es)   = object ["type" .= ("errant-gtids" :: Text),    "data" .= es]
  toJSON (RespEventHistory evs) = object ["type" .= ("event-history" :: Text),   "data" .= evs]
  toJSON (RespError msg)        = object ["type" .= ("error" :: Text),           "message" .= msg]

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o -> do
    t <- o .: "type" :: Parser Text
    case t of
      "status"        -> RespStatus       <$> o .: "data"
      "topology"      -> RespTopology     <$> o .: "data"
      "operation"     -> RespOperation    <$> o .: "data"
      "errant-gtids"  -> RespErrantGtids  <$> o .: "data"
      "event-history" -> RespEventHistory <$> o .: "data"
      "error"         -> RespError        <$> o .: "message"
      _               -> fail $ "Unknown response type: " <> show t
