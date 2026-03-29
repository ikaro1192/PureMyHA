module PureMyHA.Clone
  ( runClone
  , selectDonorAuto
  , parseHostPort
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.List (maximumBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import PureMyHA.Env
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.GTID (gtidTransactionCount)
import PureMyHA.MySQL.Query (checkClonePlugin, setCloneValidDonorList, cloneInstanceFrom)
import PureMyHA.Topology.State (getClusterTopology)
import PureMyHA.Types

-- | Parse a "host:port" or "host" spec into (host, port).
-- Defaults to port 3306 when no port is specified or the port is invalid.
parseHostPort :: Text -> (Text, Int)
parseHostPort spec =
  case T.splitOn ":" spec of
    [h, p] -> case reads (T.unpack p) of
                [(n, "")] -> (h, n)
                _         -> (spec, 3306)
    _      -> (spec, 3306)

-- | Auto-select the best donor from the cluster topology.
-- Picks the reachable replica (excluding the recipient) with the highest
-- GTID transaction count, minimising the amount of catch-up replication
-- needed after the clone completes.
selectDonorAuto
  :: Map NodeId NodeState
  -> NodeId              -- ^ recipient node (excluded from candidates)
  -> Either Text NodeId
selectDonorAuto nodes recipientId =
  let candidates = [ ns
                   | ns <- Map.elems nodes
                   , not (isSource ns)
                   , nsIsReachable ns
                   , nsNodeId ns /= recipientId
                   ]
  in case candidates of
    [] -> Left "No suitable donor found (no reachable replicas other than recipient)"
    _  -> Right . nsNodeId . maximumBy (comparing nodeGtidScore) $ candidates
  where
    nodeGtidScore ns = case nsProbeResult ns of
      ProbeSuccess{prGtidExecuted = g} -> gtidTransactionCount g
      _                                -> 0

-- | Re-seed a replica using the MySQL CLONE plugin.
-- Connects to the recipient and issues CLONE INSTANCE FROM <donor>.
-- The recipient MySQL process will restart after cloning completes.
runClone :: HostName -> Maybe HostName -> App (Either Text ())
runClone recipientSpec_ mDonorSpec_ = do
  let recipientSpec = unHostName recipientSpec_
      mDonorSpec    = fmap unHostName mDonorSpec_
  tvar          <- asks envDaemonState
  clusterName   <- getClusterName
  let clName    = unClusterName clusterName
  mTopo <- liftIO $ getClusterTopology tvar clusterName
  case mTopo of
    Nothing   -> pure $ Left "Cluster not found"
    Just topo -> do
      let nodes = ctNodes topo
          (recipientHost, _) = parseHostPort recipientSpec
      case findNodeByHost (HostName recipientHost) nodes of
        Nothing -> pure $ Left $ "Recipient not found in cluster: " <> recipientHost
        Just recipientNs -> do
          let recipientId = nsNodeId recipientNs
          -- Safety guard: refuse to clone onto the primary
          case ctSourceNodeId topo of
            Just sourceId | sourceId == recipientId ->
              pure $ Left "Cannot clone onto primary node"
            _ -> do
              -- Resolve donor: explicit or auto-selected
              eDonorId <- case mDonorSpec of
                Just donorSpec -> do
                  let (donorHost, _) = parseHostPort donorSpec
                  case findNodeByHost (HostName donorHost) nodes of
                    Nothing -> pure $ Left $ "Donor not found in cluster: " <> donorHost
                    Just donorNs
                      | nsNodeId donorNs == recipientId ->
                          pure $ Left "Donor and recipient must be different"
                      | otherwise -> pure $ Right (nsNodeId donorNs)
                Nothing -> pure $ selectDonorAuto nodes recipientId
              case eDonorId of
                Left err -> pure $ Left err
                Right donorId -> do
                  mTls  <- getTLSConfig
                  creds <- getMonCredentials
                  let donorHost     = unHostName (nodeHost donorId)
                      donorPort     = nodePort donorId
                      donorCi       = makeConnectInfo donorId creds
                      recipientCi   = makeConnectInfo recipientId creds
                  -- Check CLONE plugin on donor
                  donorCheck <- liftIO $ withNodeConn mTls donorCi checkClonePlugin
                  case donorCheck of
                    Left err    -> pure $ Left $ "Cannot connect to donor " <> donorHost <> ": " <> err
                    Right False -> pure $ Left $ "CLONE plugin is not active on donor: " <> donorHost
                    Right True  -> do
                      -- Check CLONE plugin on recipient
                      recipientCheck <- liftIO $ withNodeConn mTls recipientCi checkClonePlugin
                      case recipientCheck of
                        Left err    -> pure $ Left $ "Cannot connect to recipient " <> recipientHost <> ": " <> err
                        Right False -> pure $ Left $ "CLONE plugin is not active on recipient: " <> recipientHost
                        Right True  -> do
                          appLogInfo $ "[" <> clName <> "] Cloning " <> recipientHost
                                     <> " from donor " <> donorHost
                          cloneResult <- liftIO $ withNodeConn mTls recipientCi $
                            \conn -> do
                              setCloneValidDonorList conn donorHost donorPort
                              cloneInstanceFrom conn donorHost donorPort creds
                          case cloneResult of
                            Left err -> do
                              appLogError $ "[" <> clName <> "] CLONE failed: " <> err
                              pure $ Left $ "CLONE failed: " <> err
                            Right () -> do
                              appLogInfo $ "[" <> clName <> "] CLONE completed successfully"
                              pure $ Right ()
