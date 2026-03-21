module PureMyHA.Config
  ( Config (..)
  , ClusterConfig (..)
  , NodeConfig (..)
  , Credentials (..)
  , ClusterPasswords (..)
  , MonitoringConfig (..)
  , FailureDetectionConfig (..)
  , FailoverConfig (..)
  , HooksConfig (..)
  , LoggingConfig (..)
  , CandidatePriority (..)
  , GlobalConfig (..)
  , defaultLoggingConfig
  , loadConfig
  , parseDuration
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), withObject, withText, (.:), (.:?), (.!=))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime)
import Data.Yaml (decodeFileEither)
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data Config = Config
  { cfgClusters :: [ClusterConfig]
  , cfgLogging  :: LoggingConfig
  } deriving (Show, Generic)

data LoggingConfig = LoggingConfig
  { lcLogFile :: FilePath
  } deriving (Show, Generic)

defaultLoggingConfig :: LoggingConfig
defaultLoggingConfig = LoggingConfig "/var/log/puremyha.log"

-- | Global defaults applied to all clusters unless overridden per-cluster.
data GlobalConfig = GlobalConfig
  { gcMonitoring       :: Maybe MonitoringConfig
  , gcFailureDetection :: Maybe FailureDetectionConfig
  , gcFailover         :: Maybe FailoverConfig
  , gcHooks            :: Maybe HooksConfig
  } deriving (Show, Generic)

data ClusterConfig = ClusterConfig
  { ccName                   :: Text
  , ccNodes                  :: [NodeConfig]
  , ccCredentials            :: Credentials
  , ccReplicationCredentials :: Maybe Credentials
  , ccMonitoring             :: MonitoringConfig
  , ccFailureDetection       :: FailureDetectionConfig
  , ccFailover               :: FailoverConfig
  , ccHooks                  :: Maybe HooksConfig
  } deriving (Show, Generic)

-- | Internal type used only for YAML parsing; all per-cluster settings are optional.
data RawClusterConfig = RawClusterConfig
  { rccName                   :: Text
  , rccNodes                  :: [NodeConfig]
  , rccCredentials            :: Credentials
  , rccReplicationCredentials :: Maybe Credentials
  , rccMonitoring             :: Maybe MonitoringConfig
  , rccFailureDetection       :: Maybe FailureDetectionConfig
  , rccFailover               :: Maybe FailoverConfig
  , rccHooks                  :: Maybe HooksConfig
  } deriving (Show, Generic)

data ClusterPasswords = ClusterPasswords
  { cpPassword     :: Text   -- ^ monitoring/management password
  , cpReplUser     :: Text   -- ^ replication user
  , cpReplPassword :: Text   -- ^ replication password
  } deriving (Show)

data NodeConfig = NodeConfig
  { ncHost :: Text
  , ncPort :: Int
  } deriving (Show, Generic)

data Credentials = Credentials
  { credUser         :: Text
  , credPasswordFile :: FilePath
  } deriving (Show, Generic)

data MonitoringConfig = MonitoringConfig
  { mcInterval               :: NominalDiffTime
  , mcConnectTimeout         :: NominalDiffTime
  , mcReplicationLagWarning  :: NominalDiffTime
  , mcReplicationLagCritical :: NominalDiffTime
  , mcDiscoveryInterval      :: NominalDiffTime  -- 0 = disabled, default 300s
  } deriving (Show, Generic)

data FailureDetectionConfig = FailureDetectionConfig
  { fdcRecoveryBlockPeriod :: NominalDiffTime
  } deriving (Show, Generic)

data FailoverConfig = FailoverConfig
  { fcAutoFailover           :: Bool
  , fcMinReplicasForFailover :: Int
  , fcCandidatePriority      :: [CandidatePriority]
  , fcWaitRelayLogTimeout    :: NominalDiffTime  -- ^ Seconds to wait for relay log apply before promotion (default 60s)
  } deriving (Show, Generic)

data CandidatePriority = CandidatePriority
  { cpHost :: Text
  } deriving (Show, Generic)

data HooksConfig = HooksConfig
  { hcPreFailover              :: Maybe FilePath
  , hcPostFailover             :: Maybe FilePath
  , hcPreSwitchover            :: Maybe FilePath
  , hcPostSwitchover           :: Maybe FilePath
  , hcOnFailureDetection       :: Maybe FilePath
  , hcPostUnsuccessfulFailover :: Maybe FilePath
  } deriving (Show, Generic)

-- | Parse duration strings like "3s", "10s", "3600s"
parseDuration :: Text -> Either String NominalDiffTime
parseDuration t =
  case T.stripSuffix "s" t of
    Just numStr -> case readMaybe (T.unpack numStr) :: Maybe Double of
      Just n  -> Right (realToFrac n)
      Nothing -> Left $ "Invalid duration number: " <> T.unpack numStr
    Nothing -> Left $ "Duration must end with 's': " <> T.unpack t

newtype DurationField = DurationField { unDuration :: NominalDiffTime }

instance FromJSON DurationField where
  parseJSON = withText "Duration" $ \t ->
    case parseDuration t of
      Right d -> pure (DurationField d)
      Left e  -> fail e

-- | Resolve a raw cluster config against optional global defaults.
-- Per-cluster settings take precedence; falls back to global; errors if neither present.
resolveCluster :: Maybe GlobalConfig -> RawClusterConfig -> Either String ClusterConfig
resolveCluster mglobal raw = do
  mc  <- require "monitoring"        rccMonitoring       (gcMonitoring       =<< mglobal)
  fdc <- require "failure_detection" rccFailureDetection (gcFailureDetection =<< mglobal)
  fc  <- require "failover"          rccFailover         (gcFailover         =<< mglobal)
  pure ClusterConfig
    { ccName                   = rccName raw
    , ccNodes                  = rccNodes raw
    , ccCredentials            = rccCredentials raw
    , ccReplicationCredentials = rccReplicationCredentials raw
    , ccMonitoring             = mc
    , ccFailureDetection       = fdc
    , ccFailover               = fc
    , ccHooks                  = rccHooks raw <|> (gcHooks =<< mglobal)
    }
  where
    require field getter globalVal =
      case getter raw <|> globalVal of
        Just v  -> Right v
        Nothing -> Left $ "Cluster '" <> T.unpack (rccName raw) <> "': '"
                       <> field <> "' must be set in the cluster config or in global"

instance FromJSON Config where
  parseJSON = withObject "Config" $ \o -> do
    mglobal     <- o .:? "global"
    rawClusters <- o .:  "clusters"
    logging     <- o .:? "logging" .!= defaultLoggingConfig
    clusters    <- case mapM (resolveCluster mglobal) rawClusters of
      Left err -> fail err
      Right cs -> pure cs
    pure $ Config clusters logging

instance FromJSON LoggingConfig where
  parseJSON = withObject "LoggingConfig" $ \o ->
    LoggingConfig <$> o .:? "log_file" .!= "/var/log/puremyha.log"

instance FromJSON GlobalConfig where
  parseJSON = withObject "GlobalConfig" $ \o ->
    GlobalConfig
      <$> o .:? "monitoring"
      <*> o .:? "failure_detection"
      <*> o .:? "failover"
      <*> o .:? "hooks"

instance FromJSON RawClusterConfig where
  parseJSON = withObject "RawClusterConfig" $ \o ->
    RawClusterConfig
      <$> o .:  "name"
      <*> o .:  "nodes"
      <*> o .:  "credentials"
      <*> o .:? "replication_credentials"
      <*> o .:? "monitoring"
      <*> o .:? "failure_detection"
      <*> o .:? "failover"
      <*> o .:? "hooks"

instance FromJSON NodeConfig where
  parseJSON = withObject "NodeConfig" $ \o ->
    NodeConfig
      <$> o .: "host"
      <*> o .:? "port" .!= 3306

instance FromJSON Credentials where
  parseJSON = withObject "Credentials" $ \o ->
    Credentials
      <$> o .: "user"
      <*> o .: "password_file"

instance FromJSON MonitoringConfig where
  parseJSON = withObject "MonitoringConfig" $ \o ->
    MonitoringConfig
      <$> (unDuration <$> o .:  "interval")
      <*> (unDuration <$> o .:  "connect_timeout")
      <*> (unDuration <$> o .:  "replication_lag_warning")
      <*> (unDuration <$> o .:  "replication_lag_critical")
      <*> (unDuration <$> o .:? "discovery_interval" .!= DurationField 300)

instance FromJSON FailureDetectionConfig where
  parseJSON = withObject "FailureDetectionConfig" $ \o ->
    FailureDetectionConfig
      <$> (unDuration <$> o .: "recovery_block_period")

instance FromJSON FailoverConfig where
  parseJSON = withObject "FailoverConfig" $ \o ->
    FailoverConfig
      <$> o .:? "auto_failover" .!= True
      <*> o .:? "min_replicas_for_failover" .!= 1
      <*> o .:? "candidate_priority" .!= []
      <*> (unDuration <$> o .:? "wait_for_relay_log_apply_timeout" .!= DurationField 60)

instance FromJSON CandidatePriority where
  parseJSON = withObject "CandidatePriority" $ \o ->
    CandidatePriority <$> o .: "host"

instance FromJSON HooksConfig where
  parseJSON = withObject "HooksConfig" $ \o ->
    HooksConfig
      <$> o .:? "pre_failover"
      <*> o .:? "post_failover"
      <*> o .:? "pre_switchover"
      <*> o .:? "post_switchover"
      <*> o .:? "on_failure_detection"
      <*> o .:? "post_unsuccessful_failover"

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = do
  result <- decodeFileEither path
  pure $ case result of
    Left err  -> Left (show err)
    Right cfg -> Right cfg
