{-# LANGUAGE StrictData #-}
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
  , HttpMode (..)
  , AutoFailoverMode (..)
  , FenceMode (..)
  , ObservedHealthyRequirement (..)
  , CandidatePriority (..)
  , GlobalConfig (..)
  , LogLevel (..)
  , TLSMode (..)
  , TLSMinVersion (..)
  , TLSConfig (..)
  , Port (..)
  , mkPort
  , PositiveDuration (..)
  , AtLeastOne (..)
  , PositiveInt (..)
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
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime)
import Data.Yaml (decodeFileEither)
import GHC.Generics (Generic)
import Text.Read (readMaybe)
import PureMyHA.Types (ClusterName (..), unClusterName, HostInfo, HostName (..), mkHostInfoFromName, hiHostName, Port (..), mkPort)

data Config = Config
  { cfgClusters :: NonEmpty ClusterConfig
  , cfgLogging  :: LoggingConfig
  , cfgHttp     :: HttpConfig
  } deriving (Show, Generic)

data HttpMode = HttpDisabled | HttpEnabled
  deriving (Show, Eq, Generic)

instance FromJSON HttpMode where
  parseJSON v = (\b -> if b then HttpEnabled else HttpDisabled) <$> parseJSON v

data HttpConfig = HttpConfig
  { hcEnabled       :: HttpMode
  , hcListenAddress :: String
  , hcPort          :: Port
  } deriving (Show, Eq, Generic)

defaultHttpConfig :: HttpConfig
defaultHttpConfig = HttpConfig HttpDisabled "127.0.0.1" (Port 8080)

data AutoFailoverMode = AutoFailoverOff | AutoFailoverOn
  deriving (Show, Eq, Generic)

instance FromJSON AutoFailoverMode where
  parseJSON v = (\b -> if b then AutoFailoverOn else AutoFailoverOff) <$> parseJSON v

data FenceMode = FenceManual | FenceAuto
  deriving (Show, Eq, Generic)

instance FromJSON FenceMode where
  parseJSON v = (\b -> if b then FenceAuto else FenceManual) <$> parseJSON v

data ObservedHealthyRequirement = RequireObservedHealthy | AllowUnobserved
  deriving (Show, Eq, Generic)

instance FromJSON ObservedHealthyRequirement where
  parseJSON v = (\b -> if b then AllowUnobserved else RequireObservedHealthy) <$> parseJSON v

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
  , gcFailover         :: Maybe RawFailoverConfig
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
  , ccNodes                  :: NonEmpty NodeConfig
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
  , rccFailover               :: Maybe RawFailoverConfig
  , rccHooks                  :: Maybe HooksConfig
  , rccTLS                    :: Maybe TLSConfig
  } deriving (Show, Generic)

data DbCredentials = DbCredentials
  { dbUser     :: Text
  , dbPassword :: Text
  }

-- | Hand-written 'Show' instance that redacts 'dbPassword'. Prevents
-- accidental leakage of cleartext DB passwords via logs or exception messages.
instance Show DbCredentials where
  show c = "DbCredentials {dbUser = " ++ show (dbUser c)
        ++ ", dbPassword = <redacted>}"

data ClusterPasswords = ClusterPasswords
  { cpMonCredentials  :: DbCredentials  -- ^ monitoring/management credentials
  , cpReplCredentials :: DbCredentials  -- ^ replication credentials
  }

instance Show ClusterPasswords where
  show cp = "ClusterPasswords {cpMonCredentials = " ++ show (cpMonCredentials cp)
         ++ ", cpReplCredentials = " ++ show (cpReplCredentials cp) ++ "}"

data NodeConfig = NodeConfig
  { ncHost :: Text
  , ncPort :: Port
  } deriving (Show, Generic)

data Credentials = Credentials
  { credUser         :: Text
  , credPasswordFile :: FilePath
  } deriving (Show, Generic)

data MonitoringConfig = MonitoringConfig
  { mcInterval               :: PositiveDuration
  , mcConnectTimeout         :: PositiveDuration
  , mcReplicationLagWarning  :: NominalDiffTime
  , mcReplicationLagCritical :: NominalDiffTime
  , mcDiscoveryInterval      :: NominalDiffTime  -- 0 = disabled, default 300s
  , mcConnectRetries         :: AtLeastOne        -- ^ Total connection attempts per probe cycle (1 = no retry, default)
  , mcConnectRetryBackoff    :: NominalDiffTime  -- ^ Initial backoff between retries, doubles each attempt, capped at connect_timeout (default 1s)
  } deriving (Show, Generic)

data FailureDetectionConfig = FailureDetectionConfig
  { fdcRecoveryBlockPeriod         :: NominalDiffTime
  , fdcConsecutiveFailuresForDead  :: AtLeastOne  -- ^ Consecutive failures required to mark a node dead (default 3)
  } deriving (Show, Generic)

data FailoverConfig = FailoverConfig
  { fcAutoFailover                    :: AutoFailoverMode
  , fcMinReplicasForFailover          :: Int
  , fcCandidatePriority               :: [CandidatePriority]
  , fcWaitRelayLogTimeout             :: NominalDiffTime  -- ^ Seconds to wait for relay log apply before promotion (default 60s)
  , fcAutoFence                       :: FenceMode        -- ^ Automatically set super_read_only on split-brain nodes (default FenceManual)
  , fcMaxReplicaLagForCandidate       :: Maybe PositiveInt -- ^ Max lag in seconds for failover candidates; lagging nodes are excluded (default Nothing)
  , fcNeverPromote                    :: [HostInfo]        -- ^ Hosts permanently excluded from promotion; they continue to replicate but are never selected as candidates (default [])
  , fcFailoverWithoutObservedHealthy  :: ObservedHealthyRequirement  -- ^ Allow failover on startup even if cluster was never observed healthy (default RequireObservedHealthy)
  } deriving (Show, Generic)

data CandidatePriority = CandidatePriority
  { cpHost :: Text
  } deriving (Show, Generic)

-- | Internal type for YAML parsing of failover config; all scalar fields are optional
-- to support field-level merging between per-cluster and global sections.
-- 'candidate_priority' and 'never_promote' are cluster-only and never inherited from global.
data RawFailoverConfig = RawFailoverConfig
  { rfcAutoFailover                    :: Maybe AutoFailoverMode
  , rfcMinReplicasForFailover          :: Maybe Int
  , rfcCandidatePriority               :: [CandidatePriority]
  , rfcWaitRelayLogTimeout             :: Maybe NominalDiffTime
  , rfcAutoFence                       :: Maybe FenceMode
  , rfcMaxReplicaLagForCandidate       :: Maybe PositiveInt
  , rfcNeverPromote                    :: [Text]
  , rfcFailoverWithoutObservedHealthy  :: Maybe ObservedHealthyRequirement
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
  , hcOnTopologyDrift             :: Maybe FilePath  -- ^ Fired on transition to topology drift state
  } deriving (Show, Generic)

-- | A strictly positive duration (> 0).
newtype PositiveDuration = PositiveDuration { unPositiveDuration :: NominalDiffTime }
  deriving (Show, Eq)

-- | An integer value >= 1.
newtype AtLeastOne = AtLeastOne { unAtLeastOne :: Int }
  deriving (Show, Eq)

-- | A strictly positive integer (> 0).
newtype PositiveInt = PositiveInt { unPositiveInt :: Int }
  deriving (Show, Eq)

instance FromJSON PositiveDuration where
  parseJSON v = do
    DurationField d <- parseJSON v
    if d > 0
      then pure (PositiveDuration d)
      else fail "duration must be > 0"

instance FromJSON AtLeastOne where
  parseJSON v = do
    n <- parseJSON v
    if n >= 1
      then pure (AtLeastOne n)
      else fail "value must be >= 1"

instance FromJSON PositiveInt where
  parseJSON v = do
    n <- parseJSON v
    if n > 0
      then pure (PositiveInt n)
      else fail "value must be > 0"

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

-- | Merge per-cluster and global raw failover configs into a resolved 'FailoverConfig'.
-- Scalar fields: cluster value takes precedence over global, then falls back to the default.
-- 'candidate_priority' and 'never_promote' are cluster-only and never inherited from global.
resolveFailover :: Maybe RawFailoverConfig -> Maybe RawFailoverConfig -> FailoverConfig
resolveFailover clusterRaw globalRaw = FailoverConfig
  { fcAutoFailover                   = fromMaybe AutoFailoverOn       (pick rfcAutoFailover)
  , fcMinReplicasForFailover         = fromMaybe 1                    (pick rfcMinReplicasForFailover)
  , fcCandidatePriority              = maybe [] rfcCandidatePriority clusterRaw
  , fcWaitRelayLogTimeout            = fromMaybe 60                   (pick rfcWaitRelayLogTimeout)
  , fcAutoFence                      = fromMaybe FenceManual          (pick rfcAutoFence)
  , fcMaxReplicaLagForCandidate      = pick rfcMaxReplicaLagForCandidate
  , fcNeverPromote                   = map (mkHostInfoFromName . HostName) (maybe [] rfcNeverPromote clusterRaw)
  , fcFailoverWithoutObservedHealthy = fromMaybe RequireObservedHealthy (pick rfcFailoverWithoutObservedHealthy)
  }
  where
    pick :: (RawFailoverConfig -> Maybe a) -> Maybe a
    pick f = (clusterRaw >>= f) <|> (globalRaw >>= f)

-- | Resolve a raw cluster config against optional global defaults.
-- Per-cluster settings take precedence; falls back to global; errors if neither present.
resolveCluster :: Maybe GlobalConfig -> RawClusterConfig -> Either String ClusterConfig
resolveCluster mglobal raw = do
  mc    <- require "monitoring"        rccMonitoring       (gcMonitoring       =<< mglobal)
  fdc   <- require "failure_detection" rccFailureDetection (gcFailureDetection =<< mglobal)
  nodes <- case NE.nonEmpty (rccNodes raw) of
    Just ne -> Right ne
    Nothing -> Left $ "Cluster '" <> T.unpack (rccName raw) <> "': no nodes defined"
  pure ClusterConfig
    { ccName                   = ClusterName (rccName raw)
    , ccNodes                  = nodes
    , ccCredentials            = rccCredentials raw
    , ccReplicationCredentials = rccReplicationCredentials raw
    , ccMonitoring             = mc
    , ccFailureDetection       = fdc
    , ccFailover               = resolveFailover (rccFailover raw) (gcFailover =<< mglobal)
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
    case mglobal >>= gcFailover of
      Just rfc | not (null (rfcCandidatePriority rfc)) || not (null (rfcNeverPromote rfc)) ->
        fail "global.failover.candidate_priority and global.failover.never_promote \
             \are cluster-specific (hostnames differ per cluster) and cannot be set \
             \in the global section; specify them under each cluster's failover block instead"
      _ -> pure ()
    resolved <- case mapM (resolveCluster mglobal) rawClusters of
      Left err -> fail err
      Right cs -> pure cs
    clusters <- case NE.nonEmpty resolved of
      Just ne -> pure ne
      Nothing -> fail "no clusters defined"
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
      <*> o .:? "port" .!= Port 3306

instance FromJSON Credentials where
  parseJSON = withObject "Credentials" $ \o ->
    Credentials
      <$> o .: "user"
      <*> o .: "password_file"

instance FromJSON MonitoringConfig where
  parseJSON = withObject "MonitoringConfig" $ \o ->
    MonitoringConfig
      <$> o .:  "interval"
      <*> o .:  "connect_timeout"
      <*> (unDuration <$> o .:  "replication_lag_warning")
      <*> (unDuration <$> o .:  "replication_lag_critical")
      <*> (unDuration <$> o .:? "discovery_interval"    .!= DurationField 300)
      <*> o .:? "connect_retries"                        .!= AtLeastOne 1
      <*> (unDuration <$> o .:? "connect_retry_backoff" .!= DurationField 1)

instance FromJSON FailureDetectionConfig where
  parseJSON = withObject "FailureDetectionConfig" $ \o ->
    FailureDetectionConfig
      <$> (unDuration <$> o .:  "recovery_block_period")
      <*> o .:? "consecutive_failures_for_dead" .!= AtLeastOne 3

instance FromJSON RawFailoverConfig where
  parseJSON = withObject "FailoverConfig" $ \o ->
    RawFailoverConfig
      <$> o .:? "auto_failover"
      <*> o .:? "min_replicas_for_failover"
      <*> o .:? "candidate_priority" .!= []
      <*> (fmap unDuration <$> o .:? "wait_for_relay_log_apply_timeout")
      <*> o .:? "auto_fence"
      <*> o .:? "max_replica_lag_for_candidate"
      <*> o .:? "never_promote" .!= []
      <*> o .:? "failover_without_observed_healthy"

instance FromJSON CandidatePriority where
  parseJSON = withObject "CandidatePriority" $ \o ->
    CandidatePriority <$> o .: "host"

instance FromJSON HttpConfig where
  parseJSON = withObject "HttpConfig" $ \o ->
    HttpConfig
      <$> o .:? "enabled"        .!= HttpDisabled
      <*> o .:? "listen_address" .!= "127.0.0.1"
      <*> o .:? "port"           .!= Port 8080

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
      <*> o .:? "on_topology_drift"

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = do
  result <- decodeFileEither path
  pure $ case result of
    Left err  -> Left (show err)
    Right cfg -> Right cfg

-- | Validate a parsed 'Config' for cross-field semantic correctness.
-- Single-field constraints (port range, positive durations, etc.) are enforced
-- at parse time by the newtype wrappers. This function checks only:
--   1. Duplicate cluster names
--   2. Duplicate node hosts within a cluster
--   3. replication_lag_warning < replication_lag_critical
--   4. never_promote hosts exist in the nodes list
-- Returns a list of error messages; an empty list means the config is valid.
validateConfig :: Config -> [String]
validateConfig cfg = clusterErrors
  where
    clusters = NE.toList (cfgClusters cfg)

    clusterErrors = duplicateClusterErrors ++ concatMap validateCluster clusters

    clusterNames = map ccName clusters
    duplicateClusterErrors =
      [ "duplicate cluster name: '" <> T.unpack (unClusterName n) <> "'"
      | n <- duplicates clusterNames ]

    validateCluster :: ClusterConfig -> [String]
    validateCluster cc = nodeErrors ++ monErrors ++ fcErrors
      where
        cname  = T.unpack (unClusterName (ccName cc))
        prefix = "cluster '" <> cname <> "': "
        nodes  = NE.toList (ccNodes cc)

        hosts = map ncHost nodes
        nodeErrors =
          [ prefix <> "duplicate node host: '" <> T.unpack h <> "'"
          | h <- duplicates hosts ]

        mc = ccMonitoring cc
        monErrors =
          [ prefix <> "monitoring.replication_lag_warning must be less than replication_lag_critical"
          | mcReplicationLagWarning mc >= mcReplicationLagCritical mc ]

        fc = ccFailover cc
        fcErrors =
          [ prefix <> "failover.never_promote host '" <> T.unpack (unHostName (hiHostName h)) <> "' is not listed in nodes"
          | h <- fcNeverPromote fc, unHostName (hiHostName h) `notElem` hosts ]

-- | Return elements that appear more than once in the list.
duplicates :: Ord a => [a] -> [a]
-- NE.head is total here: NE.group produces a [NonEmpty a].
duplicates = map NE.head . filter ((> 1) . length) . NE.group . sort
