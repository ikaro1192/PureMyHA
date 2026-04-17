module PureMyHA.QuerySpec (spec) where

import Data.Either (isLeft)
import qualified Data.Text as T
import Test.Hspec

import PureMyHA.Config
  ( DbCredentials (..)
  , TLSConfig (..)
  , TLSMode (..)
  )
import PureMyHA.MySQL.GTID
  ( GtidEntry (..)
  , GtidInterval (..)
  , GtidUUID (..)
  , TransactionId (..)
  , unsafeGtidSet
  )
import PureMyHA.MySQL.Query
  ( ProcessInfo (..)
  , buildChangeReplicationSourceSql
  , buildCloneInstanceSql
  , buildGtidSubsetSql
  , buildGtidSubtractSql
  , buildSetCloneValidDonorListSql
  , buildSetGtidNextSql
  , isUserProcess
  , needsPublicKeyRetrieval
  , piId
  )

spec :: Spec
spec = do
  describe "isUserProcess" $ do
    it "excludes Binlog Dump GTID threads" $
      isUserProcess (ProcessInfo 1 "repl" "Binlog Dump GTID") `shouldBe` False

    it "excludes Binlog Dump threads" $
      isUserProcess (ProcessInfo 2 "repl" "Binlog Dump") `shouldBe` False

    it "excludes Daemon threads" $
      isUserProcess (ProcessInfo 3 "event_scheduler" "Daemon") `shouldBe` False

    it "excludes system user" $
      isUserProcess (ProcessInfo 4 "system user" "Connect") `shouldBe` False

    it "includes normal user Query connections" $
      isUserProcess (ProcessInfo 5 "app" "Query") `shouldBe` True

    it "includes Sleep connections from application pools" $
      isUserProcess (ProcessInfo 6 "app" "Sleep") `shouldBe` True

    it "piId accessor returns the process id" $
      piId (ProcessInfo 42 "app" "Query") `shouldBe` 42

  describe "needsPublicKeyRetrieval" $ do
    it "returns True when TLS is not configured" $
      needsPublicKeyRetrieval Nothing `shouldBe` True

    it "returns True when TLS mode is Disabled" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSDisabled }) `shouldBe` True

    it "returns False when TLS mode is SkipVerify" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSSkipVerify }) `shouldBe` False

    it "returns False when TLS mode is VerifyCA" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSVerifyCA }) `shouldBe` False

    it "returns False when TLS mode is VerifyFull" $
      needsPublicKeyRetrieval (Just tls { tlsMode = TLSVerifyFull }) `shouldBe` False

  describe "buildChangeReplicationSourceSql" $ do
    it "builds the expected SQL for safe inputs without public-key option" $
      buildChangeReplicationSourceSql "db1.example.com" 3306 (DbCredentials "repl" "secret") False
        `shouldBe` Right
          "CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1.example.com'\
          \, SOURCE_PORT=3306\
          \, SOURCE_USER='repl'\
          \, SOURCE_PASSWORD='secret'\
          \, SOURCE_AUTO_POSITION=1"

    it "appends GET_SOURCE_PUBLIC_KEY=1 when requested" $
      case buildChangeReplicationSourceSql "db1" 3306 (DbCredentials "repl" "secret") True of
        Right sql -> T.isSuffixOf ", GET_SOURCE_PUBLIC_KEY=1" sql `shouldBe` True
        Left err  -> expectationFailure (T.unpack err)

    it "escapes a single quote inside the password" $
      case buildChangeReplicationSourceSql "db1" 3306 (DbCredentials "repl" "p'ass") False of
        Right sql -> T.isInfixOf "SOURCE_PASSWORD='p''ass'" sql `shouldBe` True
        Left err  -> expectationFailure (T.unpack err)

    it "rejects a host containing a single quote" $
      buildChangeReplicationSourceSql "db'; DROP USER 'x" 3306 (DbCredentials "repl" "p") False
        `shouldSatisfy` isLeft

    it "rejects a user containing whitespace" $
      buildChangeReplicationSourceSql "db1" 3306 (DbCredentials "re pl" "p") False
        `shouldSatisfy` isLeft

  describe "buildCloneInstanceSql" $ do
    it "builds the expected SQL for safe inputs" $
      buildCloneInstanceSql "donor.example.com" 3306 (DbCredentials "clone_user" "secret")
        `shouldBe` Right
          "CLONE INSTANCE FROM 'clone_user'@'donor.example.com':3306 IDENTIFIED BY 'secret'"

    it "escapes a single quote in the password" $
      case buildCloneInstanceSql "donor" 3306 (DbCredentials "clone_user" "p'w") of
        Right sql -> T.isSuffixOf "IDENTIFIED BY 'p''w'" sql `shouldBe` True
        Left err  -> expectationFailure (T.unpack err)

    it "rejects a donor host containing a single quote" $
      buildCloneInstanceSql "donor'; --" 3306 (DbCredentials "u" "p") `shouldSatisfy` isLeft

    it "rejects a user containing a semicolon" $
      buildCloneInstanceSql "donor" 3306 (DbCredentials "u;DROP" "p") `shouldSatisfy` isLeft

  describe "buildSetCloneValidDonorListSql" $ do
    it "builds the expected SQL for a safe donor host" $
      buildSetCloneValidDonorListSql "donor.example.com" 3306
        `shouldBe` Right "SET GLOBAL clone_valid_donor_list = 'donor.example.com:3306'"

    it "rejects a donor host containing a single quote" $
      buildSetCloneValidDonorListSql "donor';--" 3306 `shouldSatisfy` isLeft

  describe "buildGtidSubtractSql" $ do
    it "builds the expected SQL for a rendered GTID set" $
      buildGtidSubtractSql (unsafeGtidSet [sampleEntry])
        `shouldBe` Right "SELECT GTID_SUBTRACT('aaaa-bbbb:1-5', @@GLOBAL.gtid_executed)"

    it "rejects a GTID set whose rendering contains disallowed characters" $
      buildGtidSubtractSql (unsafeGtidSet [taintedEntry]) `shouldSatisfy` isLeft

  describe "buildGtidSubsetSql" $ do
    it "builds the expected SQL for safe GTID set renderings" $
      buildGtidSubsetSql (unsafeGtidSet [sampleEntry]) (unsafeGtidSet [sampleEntry])
        `shouldBe` Right "SELECT GTID_SUBSET('aaaa-bbbb:1-5', 'aaaa-bbbb:1-5')"

    it "rejects when either argument renders unsafe characters" $
      buildGtidSubsetSql (unsafeGtidSet [sampleEntry]) (unsafeGtidSet [taintedEntry])
        `shouldSatisfy` isLeft

  describe "buildSetGtidNextSql" $ do
    it "builds the expected SQL for a single GTID entry" $
      buildSetGtidNextSql sampleEntry
        `shouldBe` Right "SET GTID_NEXT='aaaa-bbbb:1-5'"

    it "rejects an entry whose rendering contains disallowed characters" $
      buildSetGtidNextSql taintedEntry `shouldSatisfy` isLeft

  where
    tls = TLSConfig TLSDisabled Nothing Nothing Nothing Nothing

    sampleEntry =
      GtidEntry (GtidUUID "aaaa-bbbb") Nothing
        [GtidInterval (TransactionId 1) (TransactionId 5)]

    -- Hypothetical tainted entry: simulates a renderer defect that emits an
    -- illegal character. validateGtidRendering must reject it.
    taintedEntry =
      GtidEntry (GtidUUID "aaaa' OR '1'='1") Nothing
        [GtidInterval (TransactionId 1) (TransactionId 1)]
