module PureMyHA.Failover.ErrantGtid
  ( runFixErrantGtid
  , expandGtidEntry
  , collectErrantGtids
  ) where

import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Bifunctor (first)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import PureMyHA.Config (ClusterConfig (..))
import PureMyHA.Env (App, ClusterEnv (..), getMonCredentials, getTLSConfig)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (GtidEntry (..), GtidInterval (..), GtidUUID (..), TransactionId (..), parseGtidIntervals)
import PureMyHA.MySQL.Query (injectEmptyTransaction)
import PureMyHA.Topology.State (getClusterTopology)
import PureMyHA.Types

-- | Expand one GtidEntry to individual "uuid:N" strings
expandGtidEntry :: GtidEntry -> [Text]
expandGtidEntry GtidEntry{..} =
  [ getGtidUUID geUuid <> ":" <> T.pack (show (getTransactionId n))
  | GtidInterval{..} <- geIntervals
  , n <- [giStart .. giEnd]
  ]

-- | Collect and deduplicate individual GTID strings from multiple replicas' parsed entries
collectErrantGtids :: [[GtidEntry]] -> [Text]
collectErrantGtids = nub . concatMap (concatMap expandGtidEntry)

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
        errantNodes = filter (\ns -> nsErrantGtids ns /= "") allNodes
    case errantNodes of
      [] -> pure ()
      _  -> do
        entryLists <- ExceptT . pure $
          first (\e -> "GTID parse error: " <> T.pack e) $
            traverse (parseGtidIntervals . nsErrantGtids) errantNodes
        let gtids = collectErrantGtids entryLists
            srcCi = makeConnectInfo srcId creds
        ExceptT $
          first ("Connection to source failed: " <>) <$>
            withNodeConn mTls srcCi (\conn -> mapM_ (injectEmptyTransaction conn) gtids)
