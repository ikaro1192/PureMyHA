module PureMyHA.Failover.Auto
  ( runAutoFailover
  ) where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import PureMyHA.Config
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

-- | Execute automatic failover for a cluster
runAutoFailover
  :: TVarDaemonState
  -> FailoverLock
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text              -- ^ password
  -> Maybe HooksConfig
  -> IO (Either Text ())
runAutoFailover tvar lock cc fc fdc password mHooks = do
  -- Try to acquire failover lock (prevent concurrent failovers)
  acquired <- atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> pure (Left "Failover already in progress")
    Just () -> do
      result <- doFailover tvar cc fc fdc password mHooks
      atomically $ putTMVar lock ()
      pure result

doFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> Maybe HooksConfig
  -> IO (Either Text ())
doFailover tvar cc fc fdc password mHooks = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> pure (Left "Cluster not found")
    Just topo -> do
      -- Check anti-flap
      now <- getCurrentTime
      case ctRecoveryBlockedUntil topo of
        Just deadline | now < deadline ->
          pure (Left "Failover blocked by anti-flap period")
        _ -> case ctHealth topo of
          DeadSource -> executeFailover tvar cc fc fdc password mHooks topo
          h          -> pure (Left $ "Cluster not in DeadSource state: " <> T.pack (show h))

executeFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> Maybe HooksConfig
  -> ClusterTopology
  -> IO (Either Text ())
executeFailover tvar cc fc fdc password mHooks topo = do
  let replicas = filter (not . nsIsSource) (Map.elems (ctNodes topo))
  if length replicas < fcMinReplicasForFailover fc
    then pure (Left $ "Not enough replicas for failover (need " <>
               T.pack (show (fcMinReplicasForFailover fc)) <> ")")
    else case selectCandidate (ctNodes topo) (fcCandidatePriority fc) Nothing of
      Left err -> pure (Left err)
      Right candidateId -> do
        let user          = credUser (ccCredentials cc)
            oldSourceHost = fmap nodeHost (ctSourceNodeId topo)

        runHookMaybe mHooks hcPreFailover cc oldSourceHost (Just (nodeHost candidateId))

        promoteResult <- promoteCandidate user password candidateId
        case promoteResult of
          Left err -> pure (Left $ "Promote failed: " <> err)
          Right () -> do
            let otherReplicas = filter
                  (\ns -> nsNodeId ns /= candidateId && not (nsIsSource ns))
                  (Map.elems (ctNodes topo))
            mapM_ (reconnectReplica user password candidateId) otherReplicas

            now <- getCurrentTime
            atomically $ do
              recordFailover tvar (ccName cc) now
              setRecoveryBlock tvar (ccName cc) now (fdcRecoveryBlockPeriod fdc)

            runHookMaybe mHooks hcPostFailover cc oldSourceHost (Just (nodeHost candidateId))
            pure (Right ())

promoteCandidate :: Text -> Text -> NodeId -> IO (Either Text ())
promoteCandidate user password nid = do
  let ci = makeConnectInfo nid user password
  result <- withNodeConn ci $ \conn -> do
    stopReplica conn
    resetReplicaAll conn
    setReadWrite conn
  pure $ case result of
    Left err -> Left err
    Right () -> Right ()

reconnectReplica :: Text -> Text -> NodeId -> NodeState -> IO ()
reconnectReplica user password newSourceId ns = do
  let ci = makeConnectInfo (nsNodeId ns) user password
  _ <- withNodeConn ci $ \conn -> do
    stopReplica conn
    changeReplicationSourceTo conn (nodeHost newSourceId) (nodePort newSourceId)
    startReplica conn
  pure ()

runHookMaybe
  :: Maybe HooksConfig
  -> (HooksConfig -> Maybe FilePath)
  -> ClusterConfig
  -> Maybe Text
  -> Maybe Text
  -> IO ()
runHookMaybe Nothing _ _ _ _ = pure ()
runHookMaybe (Just hc) getter cc oldSrc newSrc =
  case getter hc of
    Nothing -> pure ()
    Just path -> do
      _ <- runHook path HookEnv
        { hookClusterName = ccName cc
        , hookNewSource   = newSrc
        , hookOldSource   = oldSrc
        }
      pure ()
