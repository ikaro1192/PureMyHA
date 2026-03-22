module PureMyHA.HTTP.Server
  ( startHTTPServer
  , renderMetrics
  ) where

import qualified Data.ByteString.Lazy as BSL
import Data.Aeson (encode, object, (.=))
import qualified Data.Map.Strict as Map
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (status200, status404, status503, status405, methodGet, Header)
import Network.Wai (Application, Request (..), Response, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)

import PureMyHA.Config (HttpConfig (..))
import PureMyHA.IPC.Protocol ()   -- ToJSON instances
import PureMyHA.IPC.Server (toClusterStatus, toClusterTopologyView)
import PureMyHA.Topology.State (TVarDaemonState, readDaemonState)
import PureMyHA.Types

jsonCT :: Header
jsonCT = ("Content-Type", "application/json")

prometheusCT :: Header
prometheusCT = ("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

startHTTPServer :: HttpConfig -> TVarDaemonState -> IO ()
startHTTPServer cfg tvar = do
  let settings = setHost (fromString (hcListenAddress cfg))
               $ setPort (hcPort cfg)
               $ defaultSettings
  runSettings settings (httpApp tvar)

httpApp :: TVarDaemonState -> Application
httpApp tvar req respond
  | requestMethod req /= methodGet =
      respond $ responseLBS status405 [jsonCT] (encode (object ["error" .= ("method not allowed" :: Text)]))
  | otherwise = case pathInfo req of
      ["health"]                    -> handleHealth tvar >>= respond
      ["cluster", name, "status"]   -> handleStatus tvar name >>= respond
      ["cluster", name, "topology"] -> handleTopology tvar name >>= respond
      ["metrics"]                   -> handleMetrics tvar >>= respond
      _ -> respond $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("not found" :: Text)]))

handleHealth :: TVarDaemonState -> IO Response
handleHealth tvar = do
  ds <- readDaemonState tvar
  let anyHealthy = any (\ct -> ctHealth ct == Healthy) (Map.elems (dsClusters ds))
  if anyHealthy
    then pure $ responseLBS status200 [jsonCT] (encode (object ["status" .= ("ok" :: Text)]))
    else pure $ responseLBS status503 [jsonCT] (encode (object ["status" .= ("degraded" :: Text)]))

handleStatus :: TVarDaemonState -> Text -> IO Response
handleStatus tvar name = do
  ds <- readDaemonState tvar
  case Map.lookup name (dsClusters ds) of
    Nothing -> pure $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("cluster not found" :: Text)]))
    Just ct -> pure $ responseLBS status200 [jsonCT] (encode (toClusterStatus ct))

handleTopology :: TVarDaemonState -> Text -> IO Response
handleTopology tvar name = do
  ds <- readDaemonState tvar
  case Map.lookup name (dsClusters ds) of
    Nothing -> pure $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("cluster not found" :: Text)]))
    Just ct -> pure $ responseLBS status200 [jsonCT] (encode (toClusterTopologyView ct))

handleMetrics :: TVarDaemonState -> IO Response
handleMetrics tvar = do
  ds <- readDaemonState tvar
  pure $ responseLBS status200 [prometheusCT] (renderMetrics ds)

-- | Render all cluster and node metrics in Prometheus text exposition format.
-- Each metric family emits exactly one HELP/TYPE header followed by all samples.
renderMetrics :: DaemonState -> BSL.ByteString
renderMetrics ds = BSL.fromStrict $ TE.encodeUtf8 $ T.unlines $
  metricBlock "puremyha_cluster_healthy" "gauge" "1 if the cluster is Healthy, 0 otherwise"
    [ (clusterLabels name, boolVal (ctHealth ct == Healthy))
    | (name, ct) <- Map.toAscList (dsClusters ds) ]
  ++
  metricBlock "puremyha_cluster_paused" "gauge" "1 if automatic failover is paused"
    [ (clusterLabels name, boolVal (ctPaused ct))
    | (name, ct) <- Map.toAscList (dsClusters ds) ]
  ++
  metricBlock "puremyha_node_healthy" "gauge" "1 if the node is Healthy, 0 otherwise"
    [ (nodeLabels name ns, boolVal (nsHealth ns == Healthy))
    | (name, ct) <- Map.toAscList (dsClusters ds)
    , ns <- Map.elems (ctNodes ct) ]
  ++
  metricBlock "puremyha_node_is_source" "gauge" "1 if the node is the source (primary), 0 if replica"
    [ (nodeLabels name ns, boolVal (isSource ns))
    | (name, ct) <- Map.toAscList (dsClusters ds)
    , ns <- Map.elems (ctNodes ct) ]
  ++
  metricBlock "puremyha_node_replication_lag_seconds" "gauge"
    "Replication lag in seconds (-1 if unknown or not applicable)"
    [ (nodeLabels name ns, lagVal (nsReplicaStatus ns))
    | (name, ct) <- Map.toAscList (dsClusters ds)
    , ns <- Map.elems (ctNodes ct) ]
  ++
  metricBlock "puremyha_node_consecutive_failures" "gauge"
    "Number of consecutive monitoring probe failures"
    [ (nodeLabels name ns, T.pack (show (nsConsecutiveFailures ns)))
    | (name, ct) <- Map.toAscList (dsClusters ds)
    , ns <- Map.elems (ctNodes ct) ]
  ++
  metricBlock "puremyha_node_paused" "gauge" "1 if replication is paused on this node"
    [ (nodeLabels name ns, boolVal (nsPaused ns))
    | (name, ct) <- Map.toAscList (dsClusters ds)
    , ns <- Map.elems (ctNodes ct) ]

-- | Emit a Prometheus metric family: one HELP line, one TYPE line, then one line per sample.
metricBlock :: Text -> Text -> Text -> [(Text, Text)] -> [Text]
metricBlock name typ help samples =
  [ "# HELP " <> name <> " " <> help
  , "# TYPE " <> name <> " " <> typ
  ] ++ [ name <> "{" <> labels <> "} " <> val | (labels, val) <- samples ]

clusterLabels :: Text -> Text
clusterLabels name = "cluster=" <> quoted name

nodeLabels :: Text -> NodeState -> Text
nodeLabels clusterName ns =
  "cluster=" <> quoted clusterName
  <> ",host=" <> quoted (nodeHost (nsNodeId ns))
  <> ",port=" <> quoted (T.pack (show (nodePort (nsNodeId ns))))

quoted :: Text -> Text
quoted t = "\"" <> t <> "\""

boolVal :: Bool -> Text
boolVal True  = "1"
boolVal False = "0"

lagVal :: Maybe ReplicaStatus -> Text
lagVal Nothing   = "-1"
lagVal (Just rs) = maybe "-1" (T.pack . show) (rsSecondsBehindSource rs)
