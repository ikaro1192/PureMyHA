module PureMyHA.HTTP.Server
  ( startHTTPServer
  , renderMetrics
  , httpApp
  ) where

import qualified Data.ByteString.Lazy as BSL
import Data.Aeson (encode, object, (.=))
import qualified Data.Map.Strict as Map
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (status200, status404, status405, methodGet, Header)
import Network.Wai (Application, Request (..), Response, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)

import PureMyHA.Config (HttpConfig (..), Port (..))
import PureMyHA.IPC.Protocol ()   -- ToJSON instances
import PureMyHA.IPC.Server (toClusterStatus, toClusterTopologyView)
import PureMyHA.Topology.State (TVarDaemonState, readDaemonState)
import PureMyHA.Types

-- | Metric name in Prometheus exposition format.
newtype MetricName = MetricName { unMetricName :: Text }

-- | Human-readable help string for a metric family.
newtype MetricHelp = MetricHelp { unMetricHelp :: Text }

-- | Prometheus metric type.
data MetricType = Gauge | Counter

renderMetricType :: MetricType -> Text
renderMetricType Gauge   = "gauge"
renderMetricType Counter = "counter"

-- | A single Prometheus sample with labels and a value.
data MetricSample = MetricSample
  { msLabels :: Text
  , msValue  :: Text
  }

-- | Accumulated Prometheus text lines.  Monoid instance enables @foldMap@ / @<>@.
newtype MetricOutput = MetricOutput { unMetricOutput :: [Text] }

instance Semigroup MetricOutput where
  MetricOutput a <> MetricOutput b = MetricOutput (a <> b)

instance Monoid MetricOutput where
  mempty = MetricOutput []

-- | Descriptor for a metric whose samples are keyed by cluster.
data ClusterMetric = ClusterMetric
  { cmName  :: MetricName
  , cmHelp  :: MetricHelp
  , cmValue :: ClusterName -> ClusterTopology -> Text
  }

-- | Descriptor for a metric whose samples are keyed by (cluster, node).
data NodeMetric = NodeMetric
  { nmName  :: MetricName
  , nmHelp  :: MetricHelp
  , nmValue :: ClusterName -> NodeState -> Text
  }

clusterMetrics :: [ClusterMetric]
clusterMetrics =
  [ ClusterMetric
      (MetricName "puremyha_cluster_healthy")
      (MetricHelp "1 if the cluster is Healthy, 0 otherwise")
      (\_ ct -> boolVal (ctHealth ct == Healthy))
  , ClusterMetric
      (MetricName "puremyha_cluster_paused")
      (MetricHelp "1 if automatic failover is paused")
      (\_ ct -> boolVal (ctPaused ct))
  ]

nodeMetrics :: [NodeMetric]
nodeMetrics =
  [ NodeMetric
      (MetricName "puremyha_node_healthy")
      (MetricHelp "1 if the node is Healthy, 0 otherwise")
      (\_ ns -> boolVal (nsHealth ns == Healthy))
  , NodeMetric
      (MetricName "puremyha_node_is_source")
      (MetricHelp "1 if the node is the source (primary), 0 if replica")
      (\_ ns -> boolVal (isSource ns))
  , NodeMetric
      (MetricName "puremyha_node_replication_lag_seconds")
      (MetricHelp "Replication lag in seconds (-1 if unknown or not applicable)")
      (\_ ns -> lagVal (nsProbeResult ns))
  , NodeMetric
      (MetricName "puremyha_node_consecutive_failures")
      (MetricHelp "Number of consecutive monitoring probe failures")
      (\_ ns -> T.pack (show (nsConsecutiveFailures ns)))
  , NodeMetric
      (MetricName "puremyha_node_paused")
      (MetricHelp "1 if replication is paused on this node")
      (\_ ns -> boolVal (nsPaused ns))
  ]

jsonCT :: Header
jsonCT = ("Content-Type", "application/json")

prometheusCT :: Header
prometheusCT = ("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

startHTTPServer :: HttpConfig -> TVarDaemonState -> IO ()
startHTTPServer cfg tvar = do
  let settings = setHost (fromString (hcListenAddress cfg))
               $ setPort (unPort (hcPort cfg))
               $ defaultSettings
  runSettings settings (httpApp tvar)

httpApp :: TVarDaemonState -> Application
httpApp tvar req respond
  | requestMethod req /= methodGet =
      respond $ responseLBS status405 [jsonCT] (encode (object ["error" .= ("method not allowed" :: Text)]))
  | otherwise = case pathInfo req of
      ["health"]                    -> handleHealth >>= respond
      ["cluster", name, "status"]   -> handleStatus tvar name >>= respond
      ["cluster", name, "topology"] -> handleTopology tvar name >>= respond
      ["metrics"]                   -> handleMetrics tvar >>= respond
      _ -> respond $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("not found" :: Text)]))

handleHealth :: IO Response
handleHealth =
  pure $ responseLBS status200 [jsonCT] (encode (object ["status" .= ("ok" :: Text)]))

handleStatus :: TVarDaemonState -> Text -> IO Response
handleStatus tvar name = do
  ds <- readDaemonState tvar
  case Map.lookup (ClusterName name) (dsClusters ds) of
    Nothing -> pure $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("cluster not found" :: Text)]))
    Just ct -> pure $ responseLBS status200 [jsonCT] (encode (toClusterStatus ct))

handleTopology :: TVarDaemonState -> Text -> IO Response
handleTopology tvar name = do
  ds <- readDaemonState tvar
  case Map.lookup (ClusterName name) (dsClusters ds) of
    Nothing -> pure $ responseLBS status404 [jsonCT] (encode (object ["error" .= ("cluster not found" :: Text)]))
    Just ct -> pure $ responseLBS status200 [jsonCT] (encode (toClusterTopologyView ct))

handleMetrics :: TVarDaemonState -> IO Response
handleMetrics tvar = do
  ds <- readDaemonState tvar
  pure $ responseLBS status200 [prometheusCT] (renderMetrics ds)

-- | Render all cluster and node metrics in Prometheus text exposition format.
-- Each metric family emits exactly one HELP/TYPE header followed by all samples.
renderMetrics :: DaemonState -> BSL.ByteString
renderMetrics ds = BSL.fromStrict $ TE.encodeUtf8 $ T.unlines $ unMetricOutput $
  let clusters = Map.toAscList (dsClusters ds)
  in  foldMap (renderClusterMetric clusters) clusterMetrics
   <> foldMap (renderNodeMetric clusters) nodeMetrics

renderClusterMetric :: [(ClusterName, ClusterTopology)] -> ClusterMetric -> MetricOutput
renderClusterMetric clusters cm =
  metricBlock (cmName cm) Gauge (cmHelp cm)
    [ MetricSample (clusterLabels name) (cmValue cm name ct)
    | (name, ct) <- clusters ]

renderNodeMetric :: [(ClusterName, ClusterTopology)] -> NodeMetric -> MetricOutput
renderNodeMetric clusters nm =
  metricBlock (nmName nm) Gauge (nmHelp nm)
    [ MetricSample (nodeLabels name ns) (nmValue nm name ns)
    | (name, ct) <- clusters
    , ns <- Map.elems (ctNodes ct) ]

-- | Emit a Prometheus metric family: one HELP line, one TYPE line, then one line per sample.
metricBlock :: MetricName -> MetricType -> MetricHelp -> [MetricSample] -> MetricOutput
metricBlock name typ help samples = MetricOutput $
  [ "# HELP " <> unMetricName name <> " " <> unMetricHelp help
  , "# TYPE " <> unMetricName name <> " " <> renderMetricType typ
  ] ++ [ unMetricName name <> "{" <> msLabels s <> "} " <> msValue s | s <- samples ]

clusterLabels :: ClusterName -> Text
clusterLabels name = "cluster=" <> quoted (unClusterName name)

nodeLabels :: ClusterName -> NodeState -> Text
nodeLabels clusterName ns =
  "cluster=" <> quoted (unClusterName clusterName)
  <> ",host=" <> quoted (unHostName (nodeHost (nsNodeId ns)))
  <> ",port=" <> quoted (T.pack (show (nodePort (nsNodeId ns))))

quoted :: Text -> Text
quoted t = "\"" <> t <> "\""

boolVal :: Bool -> Text
boolVal True  = "1"
boolVal False = "0"

lagVal :: ProbeResult -> Text
lagVal ProbeSuccess{prReplicaStatus = Just rs} = maybe "-1" (T.pack . show) (rsSecondsBehindSource rs)
lagVal _ = "-1"
