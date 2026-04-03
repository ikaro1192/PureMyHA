module PureMyHA.ErrantGtidSpec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Test.Hspec
import Fixtures
import PureMyHA.Config
  ( ClusterConfig (..), Credentials (..), FailoverConfig (..)
  , MonitoringConfig (..), FailureDetectionConfig (..), NodeConfig (..)
  , Port (..), PositiveDuration (..), AtLeastOne (..)
  )
import PureMyHA.Env (runApp)
import PureMyHA.Failover.ErrantGtid (collectErrantGtids, dryRunFixErrantGtid)
import PureMyHA.MySQL.GTID
import PureMyHA.Topology.Discovery (buildClusterTopology)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types
import Data.List.NonEmpty (NonEmpty ((:|)))

spec :: Spec
spec = do
  describe "expandGtidEntry" $ do
    it "expands a single GTID" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 5) (TransactionId 5)])
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 5)]

    it "expands a range interval" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)])
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "expands multiple intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 2), GtidInterval (TransactionId 5) (TransactionId 6)])
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 5)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 6)
                    ]

    it "returns empty list for no intervals" $
      expandGtidEntry (GtidEntry (GtidUUID "uuid1") Nothing [])
        `shouldBe` []

  describe "collectErrantGtids" $ do
    it "returns empty list for empty input" $
      collectErrantGtids [] `shouldBe` []

    it "collects GTIDs from a single entry" $
      collectErrantGtids [GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]]
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)]

    it "expands range across single replica" $
      collectErrantGtids [GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 3)]]]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "deduplicates identical GTIDs from two replicas" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        ]
        `shouldBe` [mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)]

    it "collects GTIDs from multiple UUIDs" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]]
        , GtidSet [GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 2) (TransactionId 2)]]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid2") Nothing (TransactionId 2)
                    ]

    it "deduplicates partial overlap across replicas" $
      collectErrantGtids
        [ GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 2)]]
        , GtidSet [GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 2) (TransactionId 3)]]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 2)
                    , mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 3)
                    ]

    it "handles one replica with multiple UUIDs" $
      collectErrantGtids
        [ GtidSet
          [ GtidEntry (GtidUUID "uuid1") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]
          , GtidEntry (GtidUUID "uuid2") Nothing [GtidInterval (TransactionId 1) (TransactionId 1)]
          ]
        ]
        `shouldBe` [ mkSingleGtid (GtidUUID "uuid1") Nothing (TransactionId 1)
                    , mkSingleGtid (GtidUUID "uuid2") Nothing (TransactionId 1)
                    ]

  describe "dryRunFixErrantGtid" $ do

    it "returns Left when cluster not found" $ do
      tvar <- newDaemonState
      env  <- mkTestEnv tvar testCC testFC
      result <- runApp env dryRunFixErrantGtid
      result `shouldBe` Left "Cluster not found"

    it "returns 'no errant GTIDs' message when none found" $ do
      tvar <- newDaemonState
      let topo = buildClusterTopology 1 "main" clusterHealthy
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env dryRunFixErrantGtid
      case result of
        Right msg -> msg `shouldSatisfy` T.isPrefixOf "Dry run: no errant GTIDs"
        Left err  -> expectationFailure (show err)

    it "returns count and source host when errant GTIDs exist" $ do
      tvar <- newDaemonState
      let nodes = Map.fromList
            [ (NodeId "db1" 3306, healthySource)
            , (NodeId "db3" 3306, replicaWithErrantGtid)
            ]
          topo = buildClusterTopology 1 "main" nodes
      atomically $ updateClusterTopology tvar topo
      env <- mkTestEnv tvar testCC testFC
      result <- runApp env dryRunFixErrantGtid
      case result of
        Right msg -> do
          msg `shouldSatisfy` T.isPrefixOf "Dry run: would inject"
          msg `shouldSatisfy` T.isInfixOf "db1"
        Left err -> expectationFailure (show err)

testCC :: ClusterConfig
testCC = ClusterConfig
  { ccName                   = "main"
  , ccNodes                  = NodeConfig "db1" (Port 3306) :| []
  , ccCredentials            = Credentials "user" "/dev/null"
  , ccReplicationCredentials = Nothing
  , ccMonitoring             = MonitoringConfig (PositiveDuration 3) (PositiveDuration 5) 30 60 300 (AtLeastOne 1) 1
  , ccFailureDetection       = FailureDetectionConfig 3600 (AtLeastOne 3)
  , ccFailover               = FailoverConfig True 1 [] 60 False Nothing [] False
  , ccHooks                  = Nothing
  , ccTLS                    = Nothing
  }

testFC :: FailoverConfig
testFC = FailoverConfig
  { fcAutoFailover                   = True
  , fcMinReplicasForFailover         = 1
  , fcCandidatePriority              = []
  , fcWaitRelayLogTimeout            = 60
  , fcAutoFence                      = False
  , fcMaxReplicaLagForCandidate      = Nothing
  , fcNeverPromote                   = []
  , fcFailoverWithoutObservedHealthy = False
  }
