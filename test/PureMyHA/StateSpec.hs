module PureMyHA.StateSpec (spec) where

import Control.Concurrent.STM
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import Data.Time (addUTCTime)
import Test.Hspec

import Fixtures (fixedTime, healthySource, healthyReplica)
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

    it "preserves ctLastFailoverAt from previous topology" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ recordFailover tvar "test" fixedTime
      atomically $ updateClusterTopology tvar emptyTopo  -- ctLastFailoverAt = Nothing
      mct <- getClusterTopology tvar "test"
      fmap ctLastFailoverAt mct `shouldBe` Just (Just fixedTime)

  describe "readDaemonState" $
    it "reads multiple clusters" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      seedCluster tvar emptyTopo { ctClusterName = "other" }
      ds <- readDaemonState tvar
      Map.size (dsClusters ds) `shouldBe` 2

  describe "updateNodeState" $ do
    it "inserts a new node into existing cluster" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      let ns = healthySource
      atomically $ updateNodeState tvar "test" ns
      mct <- getClusterTopology tvar "test"
      fmap (Map.size . ctNodes) mct `shouldBe` Just 1

    it "updates an existing node" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ updateNodeState tvar "test" healthySource
      let updated = healthySource { nsHealth = NodeUnreachable "err" }
      atomically $ updateNodeState tvar "test" updated
      mct <- getClusterTopology tvar "test"
      case mct of
        Nothing -> expectationFailure "cluster not found"
        Just ct -> case Map.lookup (NodeId "db1" 3306) (ctNodes ct) of
          Nothing -> expectationFailure "node not found"
          Just ns -> nsHealth ns `shouldBe` NodeUnreachable "err"

    it "does nothing for unknown cluster" $ do
      tvar <- newDaemonState
      atomically $ updateNodeState tvar "nonexistent" healthySource
      ds <- readDaemonState tvar
      Map.null (dsClusters ds) `shouldBe` True

  describe "updateNodeStatePreserveRole" $ do
    it "preserves nsPaused from current topology" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      let paused = healthySource { nsPaused = True }
      atomically $ updateNodeState tvar "test" paused
      let probe = healthySource { nsPaused = False }
      atomically $ updateNodeStatePreserveRole tvar "test" probe
      mct <- getClusterTopology tvar "test"
      case mct >>= Map.lookup (NodeId "db1" 3306) . ctNodes of
        Nothing -> expectationFailure "node not found"
        Just ns -> nsPaused ns `shouldBe` True

    it "preserves nsRole during recovery block" $ do
      tvar <- newDaemonState
      let blocked = emptyTopo { ctRecoveryBlockedUntil = Just (addUTCTime 3600 fixedTime) }
      seedCluster tvar blocked
      atomically $ updateNodeState tvar "test" healthySource  -- Source role
      let probeAsReplica = healthySource { nsRole = Replica }
      atomically $ updateNodeStatePreserveRole tvar "test" probeAsReplica
      mct <- getClusterTopology tvar "test"
      case mct >>= Map.lookup (NodeId "db1" 3306) . ctNodes of
        Nothing -> expectationFailure "node not found"
        Just ns -> nsRole ns `shouldBe` Source

    it "uses new nsRole when no recovery block" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo  -- no recovery block
      atomically $ updateNodeState tvar "test" healthySource
      let probeAsReplica = healthySource { nsRole = Replica }
      atomically $ updateNodeStatePreserveRole tvar "test" probeAsReplica
      mct <- getClusterTopology tvar "test"
      case mct >>= Map.lookup (NodeId "db1" 3306) . ctNodes of
        Nothing -> expectationFailure "node not found"
        Just ns -> nsRole ns `shouldBe` Replica

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

  describe "setRecoveryBlock / clearRecoveryBlock" $
    it "sets and then clears the recovery block" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ setRecoveryBlock tvar "test" fixedTime 3600
      mct1 <- getClusterTopology tvar "test"
      fmap ctRecoveryBlockedUntil mct1 `shouldBe` Just (Just (addUTCTime 3600 fixedTime))
      atomically $ clearRecoveryBlock tvar "test"
      mct2 <- getClusterTopology tvar "test"
      fmap ctRecoveryBlockedUntil mct2 `shouldBe` Just Nothing

  describe "recordFailover" $
    it "sets ctLastFailoverAt" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ recordFailover tvar "test" fixedTime
      mct <- getClusterTopology tvar "test"
      fmap ctLastFailoverAt mct `shouldBe` Just (Just fixedTime)

  describe "updateClusterHealthFields" $ do
    it "updates health, sourceNodeId, and observedHealthy" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      let srcId = Just (NodeId "db1" 3306)
      atomically $ updateClusterHealthFields tvar "test" Healthy srcId True
      mct <- getClusterTopology tvar "test"
      fmap ctHealth mct `shouldBe` Just Healthy
      fmap ctSourceNodeId mct `shouldBe` Just srcId
      fmap ctObservedHealthy mct `shouldBe` Just True

    it "preserves ctObservedHealthy=True via OR semantics" $ do
      tvar <- newDaemonState
      seedCluster tvar healthyTopo  -- observedHealthy = True
      atomically $ updateClusterHealthFields tvar "test" DeadSource Nothing False
      mct <- getClusterTopology tvar "test"
      fmap ctObservedHealthy mct `shouldBe` Just True

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

  describe "setClusterPause / clearClusterPause" $
    it "sets and clears ctPaused" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ setClusterPause tvar "test"
      mct1 <- getClusterTopology tvar "test"
      fmap ctPaused mct1 `shouldBe` Just True
      atomically $ clearClusterPause tvar "test"
      mct2 <- getClusterTopology tvar "test"
      fmap ctPaused mct2 `shouldBe` Just False

  describe "updateClusterTopologyDrift" $
    it "sets and clears ctTopologyDrift" $ do
      tvar <- newDaemonState
      seedCluster tvar emptyTopo
      atomically $ updateClusterTopologyDrift tvar "test" True
      mct1 <- getClusterTopology tvar "test"
      fmap ctTopologyDrift mct1 `shouldBe` Just True
      atomically $ updateClusterTopologyDrift tvar "test" False
      mct2 <- getClusterTopology tvar "test"
      fmap ctTopologyDrift mct2 `shouldBe` Just False
