module PureMyHA.ConfigSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (isNothing)
import qualified Data.Yaml as Yaml
import Test.Hspec
import PureMyHA.Config
  ( Config (..), ClusterConfig (..), MonitoringConfig (..)
  , FailureDetectionConfig (..), FailoverConfig (..)
  , HooksConfig (..)
  , LoggingConfig (..), LogLevel (..), parseLogLevel, logLevelToText
  , parseDuration
  , validateConfig, loadConfig
  , defaultLoggingConfig, defaultHttpConfig
  , TLSMode (..), TLSMinVersion (..), TLSConfig (..)
  , NodeConfig (..), Credentials (..)
  , Port (..), PositiveDuration (..), AtLeastOne (..)
  , AutoFailoverMode (..), FenceMode (..), ObservedHealthyRequirement (..)
  )

spec :: Spec
spec = do
  describe "parseLogLevel" $ do
    it "parses 'debug'" $
      parseLogLevel "debug" `shouldBe` Just LogLevelDebug
    it "parses 'info'" $
      parseLogLevel "info"  `shouldBe` Just LogLevelInfo
    it "parses 'warn'" $
      parseLogLevel "warn"  `shouldBe` Just LogLevelWarn
    it "parses 'error'" $
      parseLogLevel "error" `shouldBe` Just LogLevelError
    it "returns Nothing for invalid level" $
      parseLogLevel "trace" `shouldSatisfy` isNothing
    it "is case-sensitive" $
      parseLogLevel "Info"  `shouldSatisfy` isNothing

  describe "LoggingConfig log_level" $ do
    it "defaults to LogLevelInfo when field is absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters: []"
            , "logging:"
            , "  log_file: /tmp/test.log"
            ]
      case Yaml.decodeEither' yaml :: Either Yaml.ParseException LoggingConfig of
        Right lc -> lcLogLevel lc `shouldBe` LogLevelInfo
        Left err -> expectationFailure (Yaml.prettyPrintParseException err)

    it "parses explicit log_level: debug" $ do
      let yaml = BC.pack $ unlines
            [ "log_file: /tmp/test.log"
            , "log_level: debug"
            ]
      case Yaml.decodeEither' yaml :: Either Yaml.ParseException LoggingConfig of
        Right lc -> lcLogLevel lc `shouldBe` LogLevelDebug
        Left err -> expectationFailure (Yaml.prettyPrintParseException err)

    it "rejects invalid log_level" $ do
      let yaml = BC.pack $ unlines
            [ "log_file: /tmp/test.log"
            , "log_level: verbose"
            ]
      (Yaml.decodeEither' yaml :: Either Yaml.ParseException LoggingConfig)
        `shouldSatisfy` isLeft

  describe "parseDuration" $ do
    it "parses integer seconds" $
      parseDuration "3s" `shouldBe` Right 3

    it "parses large integer seconds" $
      parseDuration "3600s" `shouldBe` Right 3600

    it "parses fractional seconds" $
      parseDuration "0.5s" `shouldBe` Right 0.5

    it "rejects missing suffix" $
      parseDuration "30" `shouldSatisfy` isLeft

    it "rejects non-numeric prefix" $
      parseDuration "xs" `shouldSatisfy` isLeft

    it "rejects empty string" $
      parseDuration "" `shouldSatisfy` isLeft

  describe "MonitoringConfig discovery_interval" $ do
    it "defaults to 300s when field is absent" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 300
        Left err -> expectationFailure err

    it "parses explicit discovery_interval" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\",\"discovery_interval\":\"60s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 60
        Left err -> expectationFailure err

    it "parses discovery_interval of 0s (disabled)" $ do
      let json = "{\"interval\":\"3s\",\"connect_timeout\":\"5s\",\"replication_lag_warning\":\"10s\",\"replication_lag_critical\":\"30s\",\"discovery_interval\":\"0s\"}"
      case eitherDecode (BLC.pack json) :: Either String MonitoringConfig of
        Right mc -> mcDiscoveryInterval mc `shouldBe` 0
        Left err -> expectationFailure err

  describe "Config global/cluster merge" $ do
    it "cluster inherits all settings from global when not specified" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg -> do
          let cc = NE.head (cfgClusters cfg)
          mcInterval (ccMonitoring cc) `shouldBe` PositiveDuration 5
          fdcRecoveryBlockPeriod (ccFailureDetection cc) `shouldBe` 3600
          fcAutoFailover (ccFailover cc) `shouldBe` AutoFailoverOn
          fcAutoFence   (ccFailover cc) `shouldBe` FenceManual

    it "cluster-level monitoring overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    monitoring:"
            , "      interval: 1s"
            , "      connect_timeout: 2s"
            , "      replication_lag_warning: 5s"
            , "      replication_lag_critical: 10s"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          mcInterval (ccMonitoring (NE.head (cfgClusters cfg))) `shouldBe` PositiveDuration 1

    it "cluster-level failure_detection overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    failure_detection:"
            , "      recovery_block_period: 60s"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          fdcRecoveryBlockPeriod (ccFailureDetection (NE.head (cfgClusters cfg))) `shouldBe` 60

    it "consecutive_failures_for_dead defaults to 3 when absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          fdcConsecutiveFailuresForDead (ccFailureDetection (NE.head (cfgClusters cfg))) `shouldBe` AtLeastOne 3

    it "parses explicit consecutive_failures_for_dead" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    failure_detection:"
            , "      recovery_block_period: 3600s"
            , "      consecutive_failures_for_dead: 5"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          fdcConsecutiveFailuresForDead (ccFailureDetection (NE.head (cfgClusters cfg))) `shouldBe` AtLeastOne 5

    it "cluster-level failover overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    failover:"
            , "      auto_failover: false"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          fcAutoFailover (ccFailover (NE.head (cfgClusters cfg))) `shouldBe` AutoFailoverOff

    it "cluster-level hooks override global hooks" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    hooks:"
            , "      pre_failover: /cluster/pre_failover.sh"
            , globalBlock
            , "  hooks:"
            , "    pre_failover: /global/pre_failover.sh"
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          case ccHooks (NE.head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected hooks to be set"
            Just h  -> hcPreFailover h `shouldBe` Just "/cluster/pre_failover.sh"

    it "hooks default to Nothing when absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          ccHooks (NE.head (cfgClusters cfg)) `shouldSatisfy` isNothing

    it "global hooks are used when cluster does not specify hooks" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            , "  hooks:"
            , "    pre_failover: /global/pre_failover.sh"
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          case ccHooks (NE.head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected global hooks to be inherited"
            Just h  -> hcPreFailover h `shouldBe` Just "/global/pre_failover.sh"

    it "parses on_topology_drift hook path" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    hooks:"
            , "      on_topology_drift: /etc/puremyha/hooks/on_topology_drift.sh"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          case ccHooks (NE.head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected hooks to be set"
            Just h  -> hcOnTopologyDrift h `shouldBe` Just "/etc/puremyha/hooks/on_topology_drift.sh"

    it "on_topology_drift defaults to Nothing when absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    hooks:"
            , "      pre_failover: /etc/puremyha/hooks/pre_failover.sh"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          case ccHooks (NE.head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected hooks to be set"
            Just h  -> hcOnTopologyDrift h `shouldSatisfy` isNothing

    it "fails when monitoring is absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            , "  failover:"
            , "    auto_failover: true"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "fails when failure_detection is absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  monitoring:"
            , "    interval: 3s"
            , "    connect_timeout: 2s"
            , "    replication_lag_warning: 10s"
            , "    replication_lag_critical: 30s"
            , "  failover:"
            , "    auto_failover: true"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects candidate_priority set in global failover" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  monitoring:"
            , "    interval: 5s"
            , "    connect_timeout: 2s"
            , "    replication_lag_warning: 10s"
            , "    replication_lag_critical: 30s"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            , "  failover:"
            , "    auto_failover: true"
            , "    candidate_priority:"
            , "      - host: db2"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects never_promote set in global failover" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  monitoring:"
            , "    interval: 5s"
            , "    connect_timeout: 2s"
            , "    replication_lag_warning: 10s"
            , "    replication_lag_critical: 30s"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            , "  failover:"
            , "    auto_failover: true"
            , "    never_promote:"
            , "      - db3-analytics"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "succeeds with defaults when failover is absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  monitoring:"
            , "    interval: 3s"
            , "    connect_timeout: 2s"
            , "    replication_lag_warning: 10s"
            , "    replication_lag_critical: 30s"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg -> do
          let fc = ccFailover (NE.head (cfgClusters cfg))
          fcAutoFailover fc `shouldBe` AutoFailoverOn
          fcAutoFence    fc `shouldBe` FenceManual
          fcCandidatePriority fc `shouldSatisfy` null
          fcNeverPromote      fc `shouldBe` []

  describe "TLS config parsing" $ do
    it "ccTLS defaults to Nothing when tls key is absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> ccTLS (NE.head (cfgClusters cfg)) `shouldSatisfy` isNothing

    it "parses tls.mode: disabled" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: disabled"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          fmap tlsMode (ccTLS (NE.head (cfgClusters cfg))) `shouldBe` Just TLSDisabled

    it "parses tls.mode: skip-verify" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: skip-verify"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          fmap tlsMode (ccTLS (NE.head (cfgClusters cfg))) `shouldBe` Just TLSSkipVerify

    it "parses tls.mode: verify-ca with ca_cert" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: verify-ca"
            , "      ca_cert: /etc/tls/ca.pem"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> do
          let mTls = ccTLS (NE.head (cfgClusters cfg))
          fmap tlsMode (mTls) `shouldBe` Just TLSVerifyCA
          (mTls >>= tlsCACert) `shouldBe` Just "/etc/tls/ca.pem"

    it "parses tls.mode: verify-full with ca_cert" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: verify-full"
            , "      ca_cert: /etc/tls/ca.pem"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          fmap tlsMode (ccTLS (NE.head (cfgClusters cfg))) `shouldBe` Just TLSVerifyFull

    it "parses mutual TLS with client_cert and client_key" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: verify-full"
            , "      ca_cert: /etc/tls/ca.pem"
            , "      client_cert: /etc/tls/client.pem"
            , "      client_key: /etc/tls/client-key.pem"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> do
          let mTls = ccTLS (NE.head (cfgClusters cfg))
          (mTls >>= tlsClientCert) `shouldBe` Just "/etc/tls/client.pem"
          (mTls >>= tlsClientKey)  `shouldBe` Just "/etc/tls/client-key.pem"

    it "rejects unknown tls.mode" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: full-verify"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "parses tls.min_version: \"1.2\"" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: skip-verify"
            , "      min_version: \"1.2\""
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          (ccTLS (NE.head (cfgClusters cfg)) >>= tlsMinVersion) `shouldBe` Just TLSVersion12

    it "parses tls.min_version: \"1.3\"" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: skip-verify"
            , "      min_version: \"1.3\""
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          (ccTLS (NE.head (cfgClusters cfg)) >>= tlsMinVersion) `shouldBe` Just TLSVersion13

    it "tls.min_version defaults to Nothing when absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: skip-verify"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg ->
          (ccTLS (NE.head (cfgClusters cfg)) >>= tlsMinVersion) `shouldBe` Nothing

    it "rejects unknown tls.min_version" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    tls:"
            , "      mode: skip-verify"
            , "      min_version: \"1.1\""
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

  describe "validateConfig" $ do
    it "returns no errors for a valid config" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 3306"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> validateConfig cfg `shouldBe` []

    it "reports error for duplicate cluster names" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db2"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> validateConfig cfg `shouldSatisfy` any (isInfixOf "duplicate cluster name")

    -- port out of range is tested by boundary value tests in "validateConfig extra edge cases"
    -- (port 0, port 65536)

    it "reports error when replication_lag_warning >= replication_lag_critical" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    monitoring:"
            , "      interval: 3s"
            , "      connect_timeout: 2s"
            , "      replication_lag_warning: 30s"
            , "      replication_lag_critical: 10s"
            , "global:"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            , "  failover:"
            , "    auto_failover: true"
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> validateConfig cfg `shouldSatisfy`
          any (isInfixOf "replication_lag_warning")

    it "reports error for duplicate node hosts within a cluster" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 3306"
            , "      - host: db1"
            , "        port: 3307"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err  -> expectationFailure err
        Right cfg -> validateConfig cfg `shouldSatisfy` any (isInfixOf "duplicate node host")

  describe "logLevelToText" $ do
    it "round-trips LogLevelDebug" $
      parseLogLevel (logLevelToText LogLevelDebug) `shouldBe` Just LogLevelDebug
    it "round-trips LogLevelInfo" $
      parseLogLevel (logLevelToText LogLevelInfo) `shouldBe` Just LogLevelInfo
    it "round-trips LogLevelWarn" $
      parseLogLevel (logLevelToText LogLevelWarn) `shouldBe` Just LogLevelWarn
    it "round-trips LogLevelError" $
      parseLogLevel (logLevelToText LogLevelError) `shouldBe` Just LogLevelError

  describe "validateConfig extra edge cases" $ do
    -- Single-field constraints (port range, positive durations, >= 1 integers) are now
    -- enforced at YAML parse time by newtype wrappers. The following tests verify
    -- parse-time rejection. validateConfig only checks cross-field constraints.

    it "rejects empty clusters list at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters: []"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects empty nodes list at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects monitoring.interval of 0s at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "    monitoring:"
            , "      interval: 0s"
            , "      connect_timeout: 2s"
            , "      replication_lag_warning: 10s"
            , "      replication_lag_critical: 30s"
            , "global:"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects monitoring.connect_timeout of 0s at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "    monitoring:"
            , "      interval: 3s"
            , "      connect_timeout: 0s"
            , "      replication_lag_warning: 10s"
            , "      replication_lag_critical: 30s"
            , "global:"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects connect_retries of 0 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "    monitoring:"
            , "      interval: 3s"
            , "      connect_timeout: 2s"
            , "      replication_lag_warning: 10s"
            , "      replication_lag_critical: 30s"
            , "      connect_retries: 0"
            , "global:"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects consecutive_failures_for_dead of 0 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "    failure_detection:"
            , "      recovery_block_period: 3600s"
            , "      consecutive_failures_for_dead: 0"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects node port 0 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 0"
            , "    credentials: {user: u, password_file: /dev/null}"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects node port 65536 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 65536"
            , "    credentials: {user: u, password_file: /dev/null}"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "accepts node port 1 (minimum valid)" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 1"
            , "    credentials: {user: u, password_file: /dev/null}"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isRight

    it "accepts node port 65535 (maximum valid)" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 65535"
            , "    credentials: {user: u, password_file: /dev/null}"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isRight

    it "rejects http port 0 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "http:"
            , "  port: 0"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects http port 65536 at parse time" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "http:"
            , "  port: 65536"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "rejects http port out of range at parse time even when http is disabled" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: [{host: db1}]"
            , "    credentials: {user: u, password_file: /dev/null}"
            , "http:"
            , "  enabled: false"
            , "  port: 99999"
            , globalBlock
            ]
      decodeConfig yaml `shouldSatisfy` isLeft

    it "reports error when replication_lag_warning equals replication_lag_critical" $ do
      let mc  = (ccMonitoring minimalCluster) { mcReplicationLagWarning = 30, mcReplicationLagCritical = 30 }
          cc  = minimalCluster { ccMonitoring = mc }
          cfg = Config (cc :| []) defaultLoggingConfig defaultHttpConfig
      validateConfig cfg `shouldSatisfy` any (isInfixOf "replication_lag_warning")

    it "returns no errors for two valid clusters" $ do
      let cc2 = minimalCluster { ccName = "test2", ccNodes = NodeConfig "db2" (Port 3306) :| [] }
          cfg = Config (minimalCluster :| [cc2]) defaultLoggingConfig defaultHttpConfig
      validateConfig cfg `shouldBe` []

    it "reports error when never_promote host is not in nodes" $ do
      let fc  = (ccFailover minimalCluster) { fcNeverPromote = ["db99"] }
          cc  = minimalCluster { ccFailover = fc }
          cfg = Config (cc :| []) defaultLoggingConfig defaultHttpConfig
      validateConfig cfg `shouldSatisfy` any (isInfixOf "never_promote host 'db99'")

    it "returns no errors when never_promote host is in nodes" $ do
      let fc  = (ccFailover minimalCluster) { fcNeverPromote = ["db1"] }
          cc  = minimalCluster { ccFailover = fc }
          cfg = Config (cc :| []) defaultLoggingConfig defaultHttpConfig
      validateConfig cfg `shouldBe` []

    it "returns no errors for empty never_promote list" $ do
      let cfg = Config (minimalCluster :| []) defaultLoggingConfig defaultHttpConfig
      validateConfig cfg `shouldBe` []

  describe "never_promote YAML parsing" $ do
    it "parses never_promote list from failover config" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "      - host: db2"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "    failover:"
            , "      never_promote:"
            , "        - db2"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg -> fcNeverPromote (ccFailover (NE.head (cfgClusters cfg))) `shouldBe` ["db2"]

    it "defaults never_promote to empty list when not specified" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg -> fcNeverPromote (ccFailover (NE.head (cfgClusters cfg))) `shouldBe` []

  describe "loadConfig" $ do
    it "returns Right for a valid YAML file" $ do
      let yaml = unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes:"
            , "      - host: db1"
            , "        port: 3306"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , "global:"
            , "  monitoring:"
            , "    interval: 5s"
            , "    connect_timeout: 2s"
            , "    replication_lag_warning: 10s"
            , "    replication_lag_critical: 30s"
            , "  failure_detection:"
            , "    recovery_block_period: 3600s"
            , "  failover:"
            , "    auto_failover: true"
            ]
      writeFile "/tmp/puremyha-loadconfig-test.yaml" yaml
      result <- loadConfig "/tmp/puremyha-loadconfig-test.yaml"
      result `shouldSatisfy` isRight

    it "returns Left for a non-existent file" $ do
      result <- loadConfig "/nonexistent/path/puremyha-test.yaml"
      result `shouldSatisfy` isLeft

-- | A minimal valid ClusterConfig for direct validateConfig testing
minimalCluster :: ClusterConfig
minimalCluster = ClusterConfig
  { ccName                   = "test"
  , ccNodes                  = NodeConfig "db1" (Port 3306) :| []
  , ccCredentials            = Credentials "u" "/dev/null"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig (PositiveDuration 5) (PositiveDuration 2) 10 30 300 (AtLeastOne 1) 1
  , ccFailureDetection       = FailureDetectionConfig 3600 (AtLeastOne 3)
  , ccFailover               = FailoverConfig AutoFailoverOn 1 [] 60 FenceManual Nothing [] AllowUnobserved
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

-- | Shared global block (without hooks) used across test cases.
-- Note: appended lines after this block extend the global section.
globalBlock :: String
globalBlock = unlines
  [ "global:"
  , "  monitoring:"
  , "    interval: 5s"
  , "    connect_timeout: 2s"
  , "    replication_lag_warning: 10s"
  , "    replication_lag_critical: 30s"
  , "  failure_detection:"
  , "    recovery_block_period: 3600s"
  , "  failover:"
  , "    auto_failover: true"
  ]

-- | Decode a YAML ByteString into a Config, converting errors to String.
decodeConfig :: BC.ByteString -> Either String Config
decodeConfig = either (Left . Yaml.prettyPrintParseException) Right . Yaml.decodeEither'


isInfixOf :: String -> String -> Bool
isInfixOf needle haystack = any (needle `isPrefixOf`) (tails haystack)
  where
    isPrefixOf [] _          = True
    isPrefixOf _ []          = False
    isPrefixOf (x:xs) (y:ys) = x == y && isPrefixOf xs ys
    tails []         = [[]]
    tails xs@(_:rest) = xs : tails rest
