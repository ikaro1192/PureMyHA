module PureMyHA.ConfigSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Yaml as Yaml
import Test.Hspec
import PureMyHA.Config
  ( Config (..), ClusterConfig (..), MonitoringConfig (..)
  , FailureDetectionConfig (..), FailoverConfig (..)
  , HooksConfig (..)
  , LoggingConfig (..), LogLevel (..), parseLogLevel
  , parseDuration
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
            , "    nodes: []"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg -> do
          let cc = head (cfgClusters cfg)
          mcInterval (ccMonitoring cc) `shouldBe` 5
          fdcRecoveryBlockPeriod (ccFailureDetection cc) `shouldBe` 3600
          fcAutoFailover (ccFailover cc) `shouldBe` True

    it "cluster-level monitoring overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          mcInterval (ccMonitoring (head (cfgClusters cfg))) `shouldBe` 1

    it "cluster-level failure_detection overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          fdcRecoveryBlockPeriod (ccFailureDetection (head (cfgClusters cfg))) `shouldBe` 60

    it "consecutive_failures_for_dead defaults to 3 when absent" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          fdcConsecutiveFailuresForDead (ccFailureDetection (head (cfgClusters cfg))) `shouldBe` 3

    it "parses explicit consecutive_failures_for_dead" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          fdcConsecutiveFailuresForDead (ccFailureDetection (head (cfgClusters cfg))) `shouldBe` 5

    it "cluster-level failover overrides global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          fcAutoFailover (ccFailover (head (cfgClusters cfg))) `shouldBe` False

    it "cluster-level hooks override global hooks" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          case ccHooks (head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected hooks to be set"
            Just h  -> hcPreFailover h `shouldBe` Just "/cluster/pre_failover.sh"

    it "hooks default to Nothing when absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
            , "    credentials:"
            , "      user: u"
            , "      password_file: /dev/null"
            , globalBlock
            ]
      case decodeConfig yaml of
        Left err -> expectationFailure err
        Right cfg ->
          ccHooks (head (cfgClusters cfg)) `shouldSatisfy` isNothing

    it "global hooks are used when cluster does not specify hooks" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
          case ccHooks (head (cfgClusters cfg)) of
            Nothing -> expectationFailure "expected global hooks to be inherited"
            Just h  -> hcPreFailover h `shouldBe` Just "/global/pre_failover.sh"

    it "fails when monitoring is absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
            , "    nodes: []"
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

    it "fails when failover is absent from both cluster and global" $ do
      let yaml = BC.pack $ unlines
            [ "clusters:"
            , "  - name: test"
            , "    nodes: []"
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
      decodeConfig yaml `shouldSatisfy` isLeft

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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

isNothing :: Maybe a -> Bool
isNothing Nothing = True
isNothing _       = False
