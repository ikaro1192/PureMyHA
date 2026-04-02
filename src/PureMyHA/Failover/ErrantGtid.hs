module PureMyHA.Failover.ErrantGtid
  ( runFixErrantGtid
  , collectErrantGtids
  ) where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Bifunctor (first)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getTLSConfig)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (GtidEntry (..), GtidSet (..), isEmptyGtidSet, expandGtidEntry)
import PureMyHA.MySQL.Query (injectEmptyTransaction)
import PureMyHA.Topology.State (getClusterTopology)
import PureMyHA.Types

-- | Collect and deduplicate individual GtidEntries from multiple GtidSets
collectErrantGtids :: [GtidSet] -> [GtidEntry]
collectErrantGtids = nub . concatMap (concatMap expandGtidEntry . getGtidEntries)

-- | Fix errant GTIDs by injecting empty transactions on the source
runFixErrantGtid :: App (Either Text ())
runFixErrantGtid = do
  tvar  <- asks envDaemonState
  cc    <- asks envCluster
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  liftIO $ runExceptT $ do
    topo <- ExceptT $
      maybe (Left "Cluster not found") Right
        <$> getClusterTopology tvar (ccName cc)
    srcId <- ExceptT . pure $
      maybe (Left "No source node found in cluster topology") Right
        (ctSourceNodeId topo)
    let allNodes    = Map.elems (ctNodes topo)
        errantNodes = filter (not . isEmptyGtidSet . nsErrantGtids) allNodes
    case errantNodes of
      [] -> pure ()
      _  -> do
        let gtids = collectErrantGtids (map nsErrantGtids errantNodes)
            srcCi = makeConnectInfo srcId creds
        ExceptT $
          first ("Connection to source failed: " <>) <$>
            withNodeConn mTls srcCi (\conn -> mapM_ (injectEmptyTransaction conn) gtids)
