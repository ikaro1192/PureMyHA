module PureMyHA.StateSpec (spec) where

import Control.Concurrent.STM
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import Test.Hspec

import Fixtures (healthySource, healthyReplica)
import PureMyHA.Topology.State
import PureMyHA.Types

-- | A minimal empty ClusterTopology for seeding tests
emptyTopo :: ClusterTopology
emptyTopo = ClusterTopology
  { ctClusterName          = "test"
  , ctNodes                = Map.empty
  , ctSourceNodeId         = Nothing
  , ctHealth               = NeedsAttention "Initializing"
  , ctObservedHealthy      = False
  , ctRecoveryBlockedUntil = Nothing
  , ctLastFailoverAt       = Nothing
  , ctPaused               = False
  , ctTopologyDrift        = False
  }

healthyTopo :: ClusterTopology
healthyTopo = emptyTopo
  { ctNodes          = Map.fromList [(NodeId "db1" 3306, healthySource), (NodeId "db2" 3306, healthyReplica)]
  , ctSourceNodeId   = Just (NodeId "db1" 3306)
  , ctHealth         = Healthy
  , ctObservedHealthy = True
  }

-- | Seed a TVarDaemonState with a single cluster topology
seedCluster :: TVarDaemonState -> ClusterTopology -> IO ()
seedCluster tvar ct = atomically $ updateClusterTopology tvar ct

spec :: Spec
spec = do

  describe "newDaemonState" $
    it "creates an empty DaemonState" $ do
      tvar <- newDaemonState
      ds <- readDaemonState tvar
      Map.null (dsClusters ds) `shouldBe` True

  describe "updateClusterTopology" $ do
    it "inserts a new cluster on first call" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      mct <- getClusterTopology tvar "test"
      fmap ctClusterName mct `shouldBe` Just "test"

    it "preserves ctObservedHealthy=True on update (OR semantics)" $ do
      tvar <- newDaemonState
      seedCluster tvar healthyTopo  -- ctObservedHealthy = True
      let updateTopo = emptyTopo { ctObservedHealthy = False }
      atomically $ updateClusterTopology tvar updateTopo
      mct <- getClusterTopology tvar "test"
      fmap ctObservedHealthy mct `shouldBe` Just True

    it "preserves ctPaused from previous topology" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo { ctPaused = True }
      atomically $ updateClusterTopology tvar emptyTopo { ctPaused = False }
      mct <- getClusterTopology tvar "test"
      fmap ctPaused mct `shouldBe` Just True

    it "preserves ctHealth from previous topology (monitoring workers own health)" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo { ctHealth = DeadSource }
      -- topology refresh brings in a topology with stale NeedsAttention health
      atomically $ updateClusterTopology tvar emptyTopo { ctHealth = NeedsAttention "stale" }
      mct <- getClusterTopology tvar "test"
      fmap ctHealth mct `shouldBe` Just DeadSource

    it "preserves ctSourceNodeId from previous topology" $ do
      tvar <- newDaemonState
      seedCluster tvar healthyTopo  -- ctSourceNodeId = Just (NodeId "db1" 3306)
      atomically $ updateClusterTopology tvar emptyTopo  -- ctSourceNodeId = Nothing
      mct <- getClusterTopology tvar "test"
      fmap ctSourceNodeId mct `shouldBe` Just (Just (NodeId "db1" 3306))

  describe "readDaemonState" $
    it "reads multiple clusters" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      seedCluster tvar emptyTopo { ctClusterName = "other" }
      ds <- readDaemonState tvar
      Map.size (dsClusters ds) `shouldBe` 2

  describe "getClusterTopology" $ do
    it "returns Nothing for unknown cluster" $ do
      tvar <- newDaemonState
      mct <- getClusterTopology tvar "nonexistent"
      mct `shouldSatisfy` isNothing

    it "returns Just for existing cluster" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      mct <- getClusterTopology tvar "test"
      fmap ctClusterName mct `shouldBe` Just "test"

  describe "newFailoverLock / acquireFailoverLock" $ do
    it "first acquire returns True" $ do
      lock <- newFailoverLock
      result <- atomically $ acquireFailoverLock lock
      result `shouldBe` True

    it "second acquire returns False (already locked)" $ do
      lock <- newFailoverLock
      _ <- atomically $ acquireFailoverLock lock
      result <- atomically $ acquireFailoverLock lock
      result `shouldBe` False
