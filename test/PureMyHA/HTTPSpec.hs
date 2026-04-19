module PureMyHA.HTTPSpec (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (void)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.IORef
import qualified Data.Map.Strict as Map
import Network.HTTP.Types (methodGet, methodPost, status200, status404, status405)
import Network.Wai (defaultRequest, Request (..), Response, responseHeaders, responseStatus)
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

import Fixtures
import PureMyHA.HTTP.Server (renderMetrics, httpApp, securedHttpApp, securityHeaders)
import PureMyHA.Topology.State (newDaemonState, updateClusterTopology)
import PureMyHA.Types

-- | Helper: run a WAI Application with a given Request, capture the Response
runApp :: (Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived)
       -> Request -> IO Response
runApp app req = do
  ref <- newIORef (error "no response")
  void $ app req (\resp -> writeIORef ref resp >> pure ResponseReceived)
  readIORef ref

postReq :: Request
postReq = defaultRequest { requestMethod = methodPost, pathInfo = ["health"] }

spec :: Spec
spec = do

  describe "renderMetrics" $ do
    let ct = ClusterTopology
                { ctClusterName          = "test"
                , ctNodes                = clusterHealthy
                , ctSourceNodeId         = Just (unsafeNodeId "db1" 3306)
                , ctHealth               = Healthy
                , ctObservedHealthy      = HasBeenObservedHealthy
                , ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt       = Nothing
                , ctPaused               = Running
                , ctTopologyDrift        = NoDrift
                , ctLastEmergencyCheckAt = Nothing
                }
        ds     = DaemonState (Map.singleton "test" ct)
        output = BSL8.unpack (renderMetrics ds)
        ls     = lines output

    it "emits HELP header for cluster_healthy exactly once" $
      length (filter (== "# HELP puremyha_cluster_healthy 1 if the cluster is Healthy, 0 otherwise") ls)
        `shouldBe` 1

    it "emits TYPE header for cluster_healthy exactly once" $
      length (filter (== "# TYPE puremyha_cluster_healthy gauge") ls)
        `shouldBe` 1

    it "reports healthy cluster as 1" $
      output `shouldContain` "puremyha_cluster_healthy{cluster=\"test\"} 1"

    it "reports unpaused cluster as 0" $
      output `shouldContain` "puremyha_cluster_paused{cluster=\"test\"} 0"

    it "reports source node as is_source=1" $
      output `shouldContain` "puremyha_node_is_source{cluster=\"test\",host=\"db1\",port=\"3306\"} 1"

    it "reports replica node as is_source=0" $
      output `shouldContain` "puremyha_node_is_source{cluster=\"test\",host=\"db2\",port=\"3306\"} 0"

    it "reports replication lag=0 for healthy replica" $
      output `shouldContain` "puremyha_node_replication_lag_seconds{cluster=\"test\",host=\"db2\",port=\"3306\"} 0"

    it "reports replication lag=-1 for source (no replica status)" $
      output `shouldContain` "puremyha_node_replication_lag_seconds{cluster=\"test\",host=\"db1\",port=\"3306\"} -1"

    it "reports consecutive_failures=0 for healthy nodes" $
      output `shouldContain` "puremyha_node_consecutive_failures{cluster=\"test\",host=\"db1\",port=\"3306\"} 0"

    it "reports unhealthy cluster as 0" $ do
      let deadCt = ct { ctHealth = DeadSource
                      , ctNodes  = clusterWithDeadSource }
          ds'    = DaemonState (Map.singleton "test" deadCt)
          out    = BSL8.unpack (renderMetrics ds')
      out `shouldContain` "puremyha_cluster_healthy{cluster=\"test\"} 0"

    it "reports topology_drift=0 when no drift" $
      output `shouldContain` "puremyha_cluster_topology_drift{cluster=\"test\"} 0"

    it "reports topology_drift=1 when drift is detected" $ do
      let driftCt = ct { ctTopologyDrift = DriftDetected }
          ds'     = DaemonState (Map.singleton "test" driftCt)
          out     = BSL8.unpack (renderMetrics ds')
      out `shouldContain` "puremyha_cluster_topology_drift{cluster=\"test\"} 1"

  describe "httpApp routing" $ do

    it "returns 405 for POST request" $ do
      tvar <- newDaemonState
      resp <- runApp (httpApp tvar) postReq
      responseStatus resp `shouldBe` status405

    it "returns 404 for unknown path" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["nonexistent"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status404

    it "returns 200 for /health when daemon is running" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["health"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status200

    it "returns 200 for /health even when no cluster is healthy" $ do
      tvar <- newDaemonState
      let ct = ClusterTopology
                { ctClusterName = "test", ctNodes = clusterWithDeadSource
                , ctSourceNodeId = Nothing, ctHealth = DeadSource
                , ctObservedHealthy = NeverObservedHealthy, ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing, ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
      atomically $ updateClusterTopology tvar ct
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["health"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status200

    it "returns 200 for /cluster/<name>/status when cluster exists" $ do
      tvar <- newDaemonState
      let ct = ClusterTopology
                { ctClusterName = "test", ctNodes = clusterHealthy
                , ctSourceNodeId = Just (unsafeNodeId "db1" 3306), ctHealth = Healthy
                , ctObservedHealthy = HasBeenObservedHealthy, ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing, ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
      atomically $ updateClusterTopology tvar ct
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "test", "status"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status200

    it "returns 404 for /cluster/<name>/status when cluster missing" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "missing", "status"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status404

    it "returns 200 for /cluster/<name>/topology when cluster exists" $ do
      tvar <- newDaemonState
      let ct = ClusterTopology
                { ctClusterName = "test", ctNodes = clusterHealthy
                , ctSourceNodeId = Just (unsafeNodeId "db1" 3306), ctHealth = Healthy
                , ctObservedHealthy = HasBeenObservedHealthy, ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing, ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
      atomically $ updateClusterTopology tvar ct
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "test", "topology"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status200

    it "returns 404 for /cluster/<name>/topology when cluster missing" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "missing", "topology"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status404

    it "returns 200 for GET /metrics" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["metrics"] }
      resp <- runApp (httpApp tvar) req
      responseStatus resp `shouldBe` status200

  describe "securityHeaders constant" $ do
    it "contains exactly the three expected headers in order" $
      securityHeaders `shouldBe`
        [ ("X-Content-Type-Options", "nosniff")
        , ("X-Frame-Options", "DENY")
        , ("Cache-Control", "no-store")
        ]

  describe "securedHttpApp adds security headers" $ do
    let expectAllSecurityHeaders resp = do
          let hs = responseHeaders resp
          lookup "X-Content-Type-Options" hs `shouldBe` Just "nosniff"
          lookup "X-Frame-Options"        hs `shouldBe` Just "DENY"
          lookup "Cache-Control"          hs `shouldBe` Just "no-store"

    it "adds headers on /health (200)" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["health"] }
      resp <- runApp (securedHttpApp tvar) req
      responseStatus resp `shouldBe` status200
      expectAllSecurityHeaders resp

    it "adds headers on unknown path (404)" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["nope"] }
      resp <- runApp (securedHttpApp tvar) req
      responseStatus resp `shouldBe` status404
      expectAllSecurityHeaders resp

    it "adds headers on POST (405)" $ do
      tvar <- newDaemonState
      resp <- runApp (securedHttpApp tvar) postReq
      responseStatus resp `shouldBe` status405
      expectAllSecurityHeaders resp

    it "adds headers on /metrics and preserves Prometheus Content-Type" $ do
      tvar <- newDaemonState
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["metrics"] }
      resp <- runApp (securedHttpApp tvar) req
      responseStatus resp `shouldBe` status200
      expectAllSecurityHeaders resp
      lookup "Content-Type" (responseHeaders resp)
        `shouldBe` Just "text/plain; version=0.0.4; charset=utf-8"

    it "adds headers on /cluster/<name>/status (200)" $ do
      tvar <- newDaemonState
      let ct = ClusterTopology
                { ctClusterName = "test", ctNodes = clusterHealthy
                , ctSourceNodeId = Just (unsafeNodeId "db1" 3306), ctHealth = Healthy
                , ctObservedHealthy = HasBeenObservedHealthy, ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing, ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
      atomically $ updateClusterTopology tvar ct
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "test", "status"] }
      resp <- runApp (securedHttpApp tvar) req
      responseStatus resp `shouldBe` status200
      expectAllSecurityHeaders resp

    it "adds headers on /cluster/<name>/topology (200)" $ do
      tvar <- newDaemonState
      let ct = ClusterTopology
                { ctClusterName = "test", ctNodes = clusterHealthy
                , ctSourceNodeId = Just (unsafeNodeId "db1" 3306), ctHealth = Healthy
                , ctObservedHealthy = HasBeenObservedHealthy, ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing, ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
      atomically $ updateClusterTopology tvar ct
      let req = defaultRequest { requestMethod = methodGet, pathInfo = ["cluster", "test", "topology"] }
      resp <- runApp (securedHttpApp tvar) req
      responseStatus resp `shouldBe` status200
      expectAllSecurityHeaders resp

  describe "lagVal edge case" $
    it "reports replication lag=-1 when rsSecondsBehindSource is Nothing" $ do
      let rs = (mkReplicaStatus "db1" 3306 IOYes "uuid1:1") { rsSecondsBehindSource = Nothing }
          ns = mkNodeState (unsafeNodeId "db2" 3306) Replica (Just rs) Healthy
          ct = ClusterTopology
                { ctClusterName = "test"
                , ctNodes = Map.singleton (unsafeNodeId "db2" 3306) ns
                , ctSourceNodeId = Nothing
                , ctHealth = Healthy
                , ctObservedHealthy = HasBeenObservedHealthy
                , ctRecoveryBlockedUntil = Nothing
                , ctLastFailoverAt = Nothing
                , ctPaused = Running
                , ctTopologyDrift = NoDrift
                , ctLastEmergencyCheckAt = Nothing }
          ds = DaemonState (Map.singleton "test" ct)
          out = BSL8.unpack (renderMetrics ds)
      out `shouldContain` "puremyha_node_replication_lag_seconds{cluster=\"test\",host=\"db2\",port=\"3306\"} -1"
