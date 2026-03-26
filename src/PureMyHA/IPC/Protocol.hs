module PureMyHA.IPC.Protocol
  ( Request (..)
  , Response (..)
  , NodeStateView (..)
  , ClusterStatus (..)
  , ClusterTopologyView (..)
  , OperationResult (..)
  , ErrantGtidInfo (..)
  ) where

import Control.Applicative ((<|>))
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
  toJSON (Lagging s)                = object ["Lagging" .= s]

instance FromJSON NodeHealth where
  parseJSON (String "Healthy")                  = pure Healthy
  parseJSON (String "DeadSource")               = pure DeadSource
  parseJSON (String "UnreachableSource")        = pure UnreachableSource
  parseJSON (String "DeadSourceAndAllReplicas") = pure DeadSourceAndAllReplicas
  parseJSON (String "SplitBrainSuspected")      = pure SplitBrainSuspected
  parseJSON (Object o)                          = (Lagging <$> o .: "Lagging")
                                              <|> (NeedsAttention <$> o .: "NeedsAttention")
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
    , "fenced"       .= nsvFenced
    ]

instance FromJSON NodeStateView where
  parseJSON = withObject "NodeStateView" $ \o ->
    NodeStateView
      <$> o .:  "host"
      <*> o .:  "port"
      <*> o .:  "isSource"
      <*> o .:  "health"
      <*> o .:  "lagSeconds"
      <*> o .:  "errantGtids"
      <*> o .:  "connectError"
      <*> o .:  "paused"
      <*> o .:? "fenced" .!= False

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
  | ReqSetLogLevel    { reqLogLevel :: Text }
  | ReqUnfence { reqCluster :: Maybe ClusterName, reqUnfenceHost :: Text }
  | ReqClone
      { reqCloneCluster   :: Maybe ClusterName
      , reqCloneRecipient :: Text
      , reqCloneDonor     :: Maybe Text
      }
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
  toJSON (ReqSetLogLevel lvl)    = object ["type" .= ("set-log-level"   :: Text), "level" .= lvl]
  toJSON (ReqUnfence mc h)       = object ["type" .= ("unfence" :: Text), "cluster" .= mc, "host" .= h]
  toJSON (ReqClone mc r md)      = object ["type" .= ("clone" :: Text), "cluster" .= mc, "recipient" .= r, "donor" .= md]

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
      "set-log-level"   -> ReqSetLogLevel    <$> o .:  "level"
      "unfence"         -> ReqUnfence        <$> o .:? "cluster" <*> o .: "host"
      "clone"           -> ReqClone          <$> o .:? "cluster" <*> o .: "recipient" <*> o .:? "donor"
      _                 -> fail $ "Unknown request type: " <> show t

-- | IPC Response types
data Response
  = RespStatus   [ClusterStatus]
  | RespTopology [ClusterTopologyView]
  | RespOperation OperationResult
  | RespErrantGtids [ErrantGtidInfo]
  | RespError Text
  deriving (Show, Eq, Generic)

instance ToJSON Response where
  toJSON (RespStatus cs)        = object ["type" .= ("status" :: Text),         "data" .= cs]
  toJSON (RespTopology tv)      = object ["type" .= ("topology" :: Text),        "data" .= tv]
  toJSON (RespOperation r)      = object ["type" .= ("operation" :: Text),       "data" .= r]
  toJSON (RespErrantGtids es)   = object ["type" .= ("errant-gtids" :: Text),    "data" .= es]
  toJSON (RespError msg)        = object ["type" .= ("error" :: Text),           "message" .= msg]

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o -> do
    t <- o .: "type" :: Parser Text
    case t of
      "status"        -> RespStatus       <$> o .: "data"
      "topology"      -> RespTopology     <$> o .: "data"
      "operation"     -> RespOperation    <$> o .: "data"
      "errant-gtids"  -> RespErrantGtids  <$> o .: "data"
      "error"         -> RespError        <$> o .: "message"
      _               -> fail $ "Unknown response type: " <> show t
