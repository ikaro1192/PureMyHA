module PureMyHA.Config
  ( Config (..)
  , ClusterConfig (..)
  , NodeConfig (..)
  , Credentials (..)
  , DbCredentials (..)
  , ClusterPasswords (..)
  , MonitoringConfig (..)
  , FailureDetectionConfig (..)
  , FailoverConfig (..)
  , HooksConfig (..)
  , LoggingConfig (..)
  , HttpConfig (..)
  , CandidatePriority (..)
  , GlobalConfig (..)
  , LogLevel (..)
  , TLSMode (..)
  , TLSMinVersion (..)
  , TLSConfig (..)
  , parseLogLevel
  , logLevelToText
  , defaultLoggingConfig
  , defaultHttpConfig
  , loadConfig
  , parseDuration
  , validateConfig
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), withObject, withText, (.:), (.:?), (.!=))
import Data.List (group, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime)
import Data.Yaml (decodeFileEither)
import GHC.Generics (Generic)
import Text.Read (readMaybe)
import PureMyHA.Types (ClusterName (..), unClusterName)

data Config = Config
  { cfgClusters :: [ClusterConfig]
  , cfgLogging  :: LoggingConfig
  , cfgHttp     :: HttpConfig
  } deriving (Show, Generic)

data HttpConfig = HttpConfig
  { hcEnabled       :: Bool
  , hcListenAddress :: String
  , hcPort          :: Int
  } deriving (Show, Eq, Generic)

defaultHttpConfig :: HttpConfig
defaultHttpConfig = HttpConfig False "127.0.0.1" 8080

data LogLevel = LogLevelDebug | LogLevelInfo | LogLevelWarn | LogLevelError
  deriving (Show, Eq, Bounded, Enum)

logLevelToText :: LogLevel -> Text
logLevelToText LogLevelDebug = "debug"
logLevelToText LogLevelInfo  = "info"
logLevelToText LogLevelWarn  = "warn"
logLevelToText LogLevelError = "error"

parseLogLevel :: Text -> Maybe LogLevel
parseLogLevel t = lookup t [(logLevelToText l, l) | l <- [minBound .. maxBound]]

data LoggingConfig = LoggingConfig
  { lcLogFile   :: FilePath
  , lcLogLevel  :: LogLevel -- ^ Minimum log level (default: info)
  } deriving (Show)

defaultLoggingConfig :: LoggingConfig
defaultLoggingConfig = LoggingConfig "/var/log/puremyha.log" LogLevelInfo

-- | Global defaults applied to all clusters unless overridden per-cluster.
data GlobalConfig = GlobalConfig
  { gcMonitoring       :: Maybe MonitoringConfig
  , gcFailureDetection :: Maybe FailureDetectionConfig
  , gcFailover         :: Maybe FailoverConfig
  , gcHooks            :: Maybe HooksConfig
  } deriving (Show, Generic)

data TLSMode
  = TLSDisabled
  | TLSSkipVerify
  | TLSVerifyCA
  | TLSVerifyFull
  deriving (Show, Eq, Generic)

-- | Minimum TLS protocol version. Defaults to TLS 1.2 when not specified.
data TLSMinVersion
  = TLSVersion12  -- ^ Allow TLS 1.2 and TLS 1.3
  | TLSVersion13  -- ^ Allow TLS 1.3 only
  deriving (Show, Eq, Generic)

data TLSConfig = TLSConfig
  { tlsMode       :: TLSMode
  , tlsMinVersion :: Maybe TLSMinVersion  -- ^ Nothing = TLS 1.2+ (default)
  , tlsCACert     :: Maybe FilePath       -- ^ required for verify-ca / verify-full
  , tlsClientCert :: Maybe FilePath       -- ^ optional (mutual TLS)
  , tlsClientKey  :: Maybe FilePath       -- ^ optional (mutual TLS)
  } deriving (Show, Eq, Generic)

data ClusterConfig = ClusterConfig
  { ccName                   :: ClusterName
  , ccNodes                  :: [NodeConfig]
  , ccCredentials            :: Credentials
  , ccReplicationCredentials :: Maybe Credentials
  , ccMonitoring             :: MonitoringConfig
  , ccFailureDetection       :: FailureDetectionConfig
  , ccFailover               :: FailoverConfig
  , ccHooks                  :: Maybe HooksConfig
  , ccTLS                    :: Maybe TLSConfig
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
  , rccTLS                    :: Maybe TLSConfig
  } deriving (Show, Generic)

data DbCredentials = DbCredentials
  { dbUser     :: Text
  , dbPassword :: Text
  } deriving (Show)

data ClusterPasswords = ClusterPasswords
  { cpMonCredentials  :: DbCredentials  -- ^ monitoring/management credentials
  , cpReplCredentials :: DbCredentials  -- ^ replication credentials
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
  , mcConnectRetries         :: Int              -- ^ Total connection attempts per probe cycle (1 = no retry, default)
  , mcConnectRetryBackoff    :: NominalDiffTime  -- ^ Initial backoff between retries, doubles each attempt, capped at connect_timeout (default 1s)
  } deriving (Show, Generic)

data FailureDetectionConfig = FailureDetectionConfig
  { fdcRecoveryBlockPeriod         :: NominalDiffTime
  , fdcConsecutiveFailuresForDead  :: Int   -- ^ Consecutive failures required to mark a node dead (default 3)
  } deriving (Show, Generic)

data FailoverConfig = FailoverConfig
  { fcAutoFailover                :: Bool
  , fcMinReplicasForFailover      :: Int
  , fcCandidatePriority           :: [CandidatePriority]
  , fcWaitRelayLogTimeout         :: NominalDiffTime  -- ^ Seconds to wait for relay log apply before promotion (default 60s)
  , fcAutoFence                   :: Bool             -- ^ Automatically set super_read_only on split-brain nodes (default false)
  , fcMaxReplicaLagForCandidate   :: Maybe Int        -- ^ Max lag in seconds for failover candidates; lagging nodes are excluded (default Nothing)
  , fcNeverPromote                :: [Text]           -- ^ Hosts permanently excluded from promotion; they continue to replicate but are never selected as candidates (default [])
  } deriving (Show, Generic)

data CandidatePriority = CandidatePriority
  { cpHost :: Text
  } deriving (Show, Generic)

data HooksConfig = HooksConfig
  { hcPreFailover                 :: Maybe FilePath
  , hcPostFailover                :: Maybe FilePath
  , hcPreSwitchover               :: Maybe FilePath
  , hcPostSwitchover              :: Maybe FilePath
  , hcOnFailureDetection          :: Maybe FilePath
  , hcPostUnsuccessfulFailover    :: Maybe FilePath
  , hcOnFence                     :: Maybe FilePath
  , hcOnLagThresholdExceeded      :: Maybe FilePath  -- ^ Fired when a replica transitions to Lagging health
  , hcOnLagThresholdRecovered     :: Maybe FilePath  -- ^ Fired when a replica recovers from Lagging health
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
    { ccName                   = ClusterName (rccName raw)
    , ccNodes                  = rccNodes raw
    , ccCredentials            = rccCredentials raw
    , ccReplicationCredentials = rccReplicationCredentials raw
    , ccMonitoring             = mc
    , ccFailureDetection       = fdc
    , ccFailover               = fc
    , ccHooks                  = rccHooks raw <|> (gcHooks =<< mglobal)
    , ccTLS                    = rccTLS raw
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
    http        <- o .:? "http"    .!= defaultHttpConfig
    clusters    <- case mapM (resolveCluster mglobal) rawClusters of
      Left err -> fail err
      Right cs -> pure cs
    pure $ Config clusters logging http

instance FromJSON LoggingConfig where
  parseJSON = withObject "LoggingConfig" $ \o -> do
    logFile   <- o .:? "log_file"   .!= "/var/log/puremyha.log"
    lvlText   <- o .:? "log_level"  .!= ("info" :: Text)
    logLevel  <- case parseLogLevel lvlText of
      Just l  -> pure l
      Nothing -> fail $ "Invalid log_level: " <> T.unpack lvlText
                      <> " (expected: debug, info, warn, error)"
    pure $ LoggingConfig logFile logLevel

instance FromJSON GlobalConfig where
  parseJSON = withObject "GlobalConfig" $ \o ->
    GlobalConfig
      <$> o .:? "monitoring"
      <*> o .:? "failure_detection"
      <*> o .:? "failover"
      <*> o .:? "hooks"

instance FromJSON TLSMode where
  parseJSON = withText "TLSMode" $ \t -> case t of
    "disabled"    -> pure TLSDisabled
    "skip-verify" -> pure TLSSkipVerify
    "verify-ca"   -> pure TLSVerifyCA
    "verify-full" -> pure TLSVerifyFull
    _             -> fail $ "Invalid tls.mode: " <> show t
                         <> " (expected: disabled, skip-verify, verify-ca, verify-full)"

instance FromJSON TLSMinVersion where
  parseJSON = withText "TLSMinVersion" $ \t -> case t of
    "1.2" -> pure TLSVersion12
    "1.3" -> pure TLSVersion13
    _     -> fail $ "Invalid tls.min_version: " <> show t
                 <> " (expected: \"1.2\" or \"1.3\")"

instance FromJSON TLSConfig where
  parseJSON = withObject "TLSConfig" $ \o ->
    TLSConfig
      <$> o .:? "mode"        .!= TLSDisabled
      <*> o .:? "min_version"
      <*> o .:? "ca_cert"
      <*> o .:? "client_cert"
      <*> o .:? "client_key"

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
      <*> o .:? "tls"

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
      <*> (unDuration <$> o .:? "discovery_interval"    .!= DurationField 300)
      <*>               o .:? "connect_retries"          .!= 1
      <*> (unDuration <$> o .:? "connect_retry_backoff" .!= DurationField 1)

instance FromJSON FailureDetectionConfig where
  parseJSON = withObject "FailureDetectionConfig" $ \o ->
    FailureDetectionConfig
      <$> (unDuration <$> o .:  "recovery_block_period")
      <*> o .:? "consecutive_failures_for_dead" .!= 3

instance FromJSON FailoverConfig where
  parseJSON = withObject "FailoverConfig" $ \o ->
    FailoverConfig
      <$> o .:? "auto_failover" .!= True
      <*> o .:? "min_replicas_for_failover" .!= 1
      <*> o .:? "candidate_priority" .!= []
      <*> (unDuration <$> o .:? "wait_for_relay_log_apply_timeout" .!= DurationField 60)
      <*> o .:? "auto_fence" .!= False
      <*> o .:? "max_replica_lag_for_candidate"
      <*> o .:? "never_promote" .!= []

instance FromJSON CandidatePriority where
  parseJSON = withObject "CandidatePriority" $ \o ->
    CandidatePriority <$> o .: "host"

instance FromJSON HttpConfig where
  parseJSON = withObject "HttpConfig" $ \o ->
    HttpConfig
      <$> o .:? "enabled"        .!= False
      <*> o .:? "listen_address" .!= "127.0.0.1"
      <*> o .:? "port"           .!= 8080

instance FromJSON HooksConfig where
  parseJSON = withObject "HooksConfig" $ \o ->
    HooksConfig
      <$> o .:? "pre_failover"
      <*> o .:? "post_failover"
      <*> o .:? "pre_switchover"
      <*> o .:? "post_switchover"
      <*> o .:? "on_failure_detection"
      <*> o .:? "post_unsuccessful_failover"
      <*> o .:? "on_fence"
      <*> o .:? "on_lag_threshold_exceeded"
      <*> o .:? "on_lag_threshold_recovered"

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = do
  result <- decodeFileEither path
  pure $ case result of
    Left err  -> Left (show err)
    Right cfg -> Right cfg

-- | Validate a parsed 'Config' for semantic correctness.
-- Returns a list of error messages; an empty list means the config is valid.
validateConfig :: Config -> [String]
validateConfig cfg = clusterErrors ++ httpErrors
  where
    clusters = cfgClusters cfg

    clusterErrors
      | null clusters = ["no clusters defined"]
      | otherwise     = duplicateClusterErrors ++ concatMap validateCluster clusters

    clusterNames = map ccName clusters
    duplicateClusterErrors =
      [ "duplicate cluster name: '" <> T.unpack (unClusterName n) <> "'"
      | n <- duplicates clusterNames ]

    validateCluster :: ClusterConfig -> [String]
    validateCluster cc = nodeErrors ++ monErrors ++ fdErrors ++ fcErrors
      where
        cname  = T.unpack (unClusterName (ccName cc))
        prefix = "cluster '" <> cname <> "': "
        nodes  = ccNodes cc

        nodeErrors
          | null nodes = [prefix <> "no nodes defined"]
          | otherwise  = duplicateHostErrors ++ concatMap (validateNode prefix) nodes

        hosts = map ncHost nodes
        duplicateHostErrors =
          [ prefix <> "duplicate node host: '" <> T.unpack h <> "'"
          | h <- duplicates hosts ]

        validateNode :: String -> NodeConfig -> [String]
        validateNode p nc =
          [ p <> "node port " <> show (ncPort nc) <> " is out of range (1-65535)"
          | ncPort nc < 1 || ncPort nc > 65535 ]

        mc = ccMonitoring cc
        monErrors = concat
          [ [ prefix <> "monitoring.interval must be > 0"
            | mcInterval mc <= 0 ]
          , [ prefix <> "monitoring.connect_timeout must be > 0"
            | mcConnectTimeout mc <= 0 ]
          , [ prefix <> "monitoring.replication_lag_warning must be less than replication_lag_critical"
            | mcReplicationLagWarning mc >= mcReplicationLagCritical mc ]
          , [ prefix <> "monitoring.connect_retries must be >= 1"
            | mcConnectRetries mc < 1 ]
          ]

        fdc = ccFailureDetection cc
        fdErrors =
          [ prefix <> "failure_detection.consecutive_failures_for_dead must be >= 1"
          | fdcConsecutiveFailuresForDead fdc < 1 ]

        fc = ccFailover cc
        fcErrors =
          [ prefix <> "failover.max_replica_lag_for_candidate must be > 0"
          | Just n <- [fcMaxReplicaLagForCandidate fc], n <= 0 ]
          ++
          [ prefix <> "failover.never_promote host '" <> T.unpack h <> "' is not listed in nodes"
          | h <- fcNeverPromote fc, h `notElem` hosts ]

    httpErrors
      | not (hcEnabled (cfgHttp cfg)) = []
      | p < 1 || p > 65535 =
          ["http.port " <> show p <> " is out of range (1-65535)"]
      | otherwise = []
      where p = hcPort (cfgHttp cfg)

-- | Return elements that appear more than once in the list.
duplicates :: Ord a => [a] -> [a]
duplicates = map head . filter ((> 1) . length) . group . sort
