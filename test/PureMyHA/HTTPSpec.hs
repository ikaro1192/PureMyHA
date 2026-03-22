module PureMyHA.HTTPSpec (spec) where

import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Data.Map.Strict as Map
import Test.Hspec

import Fixtures
import PureMyHA.HTTP.Server (renderMetrics)
import PureMyHA.Types

spec :: Spec
spec = describe "renderMetrics" $ do
  let ct = ClusterTopology
              { ctClusterName          = "test"
              , ctNodes                = clusterHealthy
              , ctSourceNodeId         = Just (NodeId "db1" 3306)
              , ctHealth               = Healthy
              , ctObservedHealthy      = True
              , ctRecoveryBlockedUntil = Nothing
              , ctLastFailoverAt       = Nothing
              , ctPaused               = False
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
