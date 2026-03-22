module PureMyHA.HTTP.Server
  ( startHTTPServer
  ) where

import Data.Aeson (encode, object, (.=))
import qualified Data.Map.Strict as Map
import Data.String (fromString)
import Data.Text (Text)
import Network.HTTP.Types (status200, status404, status503, status405, methodGet, Header)
import Network.Wai (Application, Request (..), Response, responseLBS)
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)

import PureMyHA.Config (HttpConfig (..))
import PureMyHA.IPC.Protocol ()   -- ToJSON instances
import PureMyHA.IPC.Server (toClusterStatus, toClusterTopologyView)
import PureMyHA.Topology.State (TVarDaemonState, readDaemonState)
import PureMyHA.Types (NodeHealth (..), DaemonState (..), ClusterTopology (..))

jsonCT :: Header
jsonCT = ("Content-Type", "application/json")

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
