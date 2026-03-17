module PureMyHA.Failover.ErrantGtid
  ( runFixErrantGtid
  , expandGtidEntry
  , collectErrantGtids
  ) where

import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import PureMyHA.Config (ClusterConfig (..), Credentials (..))
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (GtidEntry (..), GtidInterval (..), parseGtidIntervals)
import PureMyHA.MySQL.Query (injectEmptyTransaction)
import PureMyHA.Topology.State (TVarDaemonState, getClusterTopology)
import PureMyHA.Types

-- | Expand one GtidEntry to individual "uuid:N" strings
expandGtidEntry :: GtidEntry -> [Text]
expandGtidEntry GtidEntry{..} =
  [ geUuid <> ":" <> T.pack (show n)
  | GtidInterval{..} <- geIntervals
  , n <- [giStart .. giEnd]
  ]

-- | Collect and deduplicate individual GTID strings from multiple replicas' parsed entries
collectErrantGtids :: [[GtidEntry]] -> [Text]
collectErrantGtids = nub . concatMap (concatMap expandGtidEntry)

-- | Fix errant GTIDs by injecting empty transactions on the source
runFixErrantGtid :: TVarDaemonState -> ClusterConfig -> Text -> IO (Either Text ())
runFixErrantGtid tvar cc password = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo ->
      case ctSourceNodeId topo of
        Nothing -> pure (Left "No source node found in cluster topology")
        Just srcId -> do
          let user        = credUser (ccCredentials cc)
              allNodes    = Map.elems (ctNodes topo)
              errantNodes = filter (\ns -> nsErrantGtids ns /= "") allNodes
          case errantNodes of
            [] -> pure (Right ())
            _  -> do
              let parseResults = map (parseGtidIntervals . nsErrantGtids) errantNodes
              case sequence parseResults of
                Left err -> pure (Left ("GTID parse error: " <> T.pack err))
                Right entryLists -> do
                  let gtids = collectErrantGtids entryLists
                  let srcCi = makeConnectInfo srcId user password
                  result <- withNodeConn srcCi $ \conn ->
                    mapM_ (injectEmptyTransaction conn) gtids
                  case result of
                    Left err -> pure (Left ("Connection to source failed: " <> err))
                    Right () -> pure (Right ())
