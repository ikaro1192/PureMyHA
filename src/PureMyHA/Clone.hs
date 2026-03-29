module PureMyHA.Clone
  ( runClone
  , selectDonorAuto
  , parseHostPort
  ) where

import Control.Monad.Except (ExceptT (..), MonadError, runExceptT, throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Class (lift)
import Data.List (maximumBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Database.MySQL.Base (ConnectInfo)
import PureMyHA.Config (TLSConfig)
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

resolveRecipient
  :: Monad m
  => Text -> ClusterTopology -> ExceptT Text m NodeState
resolveRecipient spec topo = do
  let (host, _) = parseHostPort spec
  ns <- ExceptT . pure $
    maybe (Left ("Recipient not found in cluster: " <> host)) Right $
      findNodeByHost (HostName host) (ctNodes topo)
  case ctSourceNodeId topo of
    Just sid | sid == nsNodeId ns -> throwError "Cannot clone onto primary node"
    _                             -> pure ns

resolveDonor
  :: Monad m
  => Maybe Text -> Map NodeId NodeState -> NodeId -> ExceptT Text m NodeId
resolveDonor Nothing nodes recipientId =
  ExceptT . pure $ selectDonorAuto nodes recipientId
resolveDonor (Just spec) nodes recipientId = do
  let (host, _) = parseHostPort spec
  ns <- ExceptT . pure $
    maybe (Left ("Donor not found in cluster: " <> host)) Right $
      findNodeByHost (HostName host) nodes
  if nsNodeId ns == recipientId
    then throwError "Donor and recipient must be different"
    else pure (nsNodeId ns)

checkCloneActive
  :: (MonadIO m, MonadError Text m)
  => Maybe TLSConfig -> ConnectInfo -> Text -> Text -> m ()
checkCloneActive mTls ci role host = do
  result <- liftIO $ withNodeConn mTls ci checkClonePlugin
  case result of
    Left err    -> throwError $ "Cannot connect to " <> role <> " " <> host <> ": " <> err
    Right False -> throwError $ "CLONE plugin is not active on " <> role <> ": " <> host
    Right True  -> pure ()

-- | Re-seed a replica using the MySQL CLONE plugin.
-- Connects to the recipient and issues CLONE INSTANCE FROM <donor>.
-- The recipient MySQL process will restart after cloning completes.
runClone :: HostName -> Maybe HostName -> App (Either Text ())
runClone recipientSpec_ mDonorSpec_ = runExceptT $ do
  let recipientSpec = unHostName recipientSpec_
      mDonorSpec    = fmap unHostName mDonorSpec_
  tvar        <- lift $ asks envDaemonState
  clusterName <- lift getClusterName
  let clName  = unClusterName clusterName
  topo        <- ExceptT . liftIO $
    maybe (Left "Cluster not found") Right <$>
      getClusterTopology tvar clusterName
  recipientNs <- resolveRecipient recipientSpec topo
  let (recipientHost, _) = parseHostPort recipientSpec
      recipientId        = nsNodeId recipientNs
      nodes              = ctNodes topo
  donorId     <- resolveDonor mDonorSpec nodes recipientId
  mTls        <- lift getTLSConfig
  creds       <- lift getMonCredentials
  let donorHost   = unIPAddr (nodeIPAddr donorId)
      donorPort   = nodePort donorId
      donorCi     = makeConnectInfo donorId creds
      recipientCi = makeConnectInfo recipientId creds
  checkCloneActive mTls donorCi "donor" donorHost
  checkCloneActive mTls recipientCi "recipient" recipientHost
  lift $ appLogInfo $ "[" <> clName <> "] Cloning " <> recipientHost
                    <> " from donor " <> donorHost
  result <- liftIO $ withNodeConn mTls recipientCi $ \conn -> do
    setCloneValidDonorList conn donorHost donorPort
    cloneInstanceFrom conn donorHost donorPort creds
  case result of
    Left err -> do
      lift $ appLogError $ "[" <> clName <> "] CLONE failed: " <> err
      throwError $ "CLONE failed: " <> err
    Right () ->
      lift $ appLogInfo $ "[" <> clName <> "] CLONE completed successfully"
