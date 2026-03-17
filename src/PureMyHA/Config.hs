module PureMyHA.Config
  ( Config (..)
  , ClusterConfig (..)
  , NodeConfig (..)
  , Credentials (..)
  , MonitoringConfig (..)
  , FailureDetectionConfig (..)
  , FailoverConfig (..)
  , HooksConfig (..)
  , LoggingConfig (..)
  , CandidatePriority (..)
  , defaultLoggingConfig
  , loadConfig
  , parseDuration
  ) where

import Data.Aeson (FromJSON (..), Value (..), withObject, withText, (.:), (.:?), (.!=))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime)
import Data.Yaml (decodeFileEither)
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data Config = Config
  { cfgClusters         :: [ClusterConfig]
  , cfgMonitoring       :: MonitoringConfig
  , cfgFailureDetection :: FailureDetectionConfig
  , cfgFailover         :: FailoverConfig
  , cfgHooks            :: Maybe HooksConfig
  , cfgLogging          :: LoggingConfig
  } deriving (Show, Generic)

data LoggingConfig = LoggingConfig
  { lcLogFile :: FilePath
  } deriving (Show, Generic)

defaultLoggingConfig :: LoggingConfig
defaultLoggingConfig = LoggingConfig "/var/log/puremyha.log"

data ClusterConfig = ClusterConfig
  { ccName        :: Text
  , ccNodes       :: [NodeConfig]
  , ccCredentials :: Credentials
  } deriving (Show, Generic)

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
  } deriving (Show, Generic)

data FailureDetectionConfig = FailureDetectionConfig
  { fdcRecoveryBlockPeriod :: NominalDiffTime
  } deriving (Show, Generic)

data FailoverConfig = FailoverConfig
  { fcAutoFailover           :: Bool
  , fcMinReplicasForFailover :: Int
  , fcCandidatePriority      :: [CandidatePriority]
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

instance FromJSON Config where
  parseJSON = withObject "Config" $ \o ->
    Config
      <$> o .: "clusters"
      <*> o .: "monitoring"
      <*> o .: "failure_detection"
      <*> o .: "failover"
      <*> o .:? "hooks"
      <*> o .:? "logging" .!= defaultLoggingConfig

instance FromJSON LoggingConfig where
  parseJSON = withObject "LoggingConfig" $ \o ->
    LoggingConfig <$> o .:? "log_file" .!= "/var/log/puremyha.log"

instance FromJSON ClusterConfig where
  parseJSON = withObject "ClusterConfig" $ \o ->
    ClusterConfig
      <$> o .: "name"
      <*> o .: "nodes"
      <*> o .: "credentials"

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
      <$> (unDuration <$> o .: "interval")
      <*> (unDuration <$> o .: "connect_timeout")
      <*> (unDuration <$> o .: "replication_lag_warning")
      <*> (unDuration <$> o .: "replication_lag_critical")

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
