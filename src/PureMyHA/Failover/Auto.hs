module PureMyHA.Failover.Auto
  ( runAutoFailover
  , checkAutoFailoverPreconditions
  ) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import PureMyHA.Config
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.Logger (Logger, logInfo, logError)
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
  -> Logger
  -> IO (Either Text ())
runAutoFailover tvar lock cc fc fdc password mHooks logger = do
  -- Try to acquire failover lock (prevent concurrent failovers)
  acquired <- atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> pure (Left "Failover already in progress")
    Just () -> do
      result <- doFailover tvar cc fc fdc password mHooks logger
      atomically $ putTMVar lock ()
      pure result

-- | Check preconditions for auto failover (pure)
checkAutoFailoverPreconditions
  :: UTCTime
  -> ClusterTopology
  -> Int               -- ^ fcMinReplicasForFailover
  -> Either Text ()
checkAutoFailoverPreconditions now topo minReplicas = do
  case ctRecoveryBlockedUntil topo of
    Just deadline | now < deadline ->
      Left "Failover blocked by anti-flap period"
    _ -> Right ()
  case ctHealth topo of
    DeadSource -> Right ()
    h          -> Left $ "Cluster not in DeadSource state: " <> T.pack (show h)
  let replicas = filter (not . nsIsSource) (Map.elems (ctNodes topo))
  if length replicas < minReplicas
    then Left $ "Not enough replicas for failover (need " <> T.pack (show minReplicas) <> ")"
    else Right ()

doFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> Maybe HooksConfig
  -> Logger
  -> IO (Either Text ())
doFailover tvar cc fc fdc password mHooks logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      logError logger $ "[" <> ccName cc <> "] Auto-failover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo -> do
      now <- getCurrentTime
      case checkAutoFailoverPreconditions now topo (fcMinReplicasForFailover fc) of
        Left err -> do
          logError logger $ "[" <> ccName cc <> "] Auto-failover failed: " <> err
          pure (Left err)
        Right () -> do
          logInfo logger $ "[" <> ccName cc <> "] Auto-failover started"
          executeFailover tvar cc fc fdc password mHooks logger topo

executeFailover
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> FailureDetectionConfig
  -> Text
  -> Maybe HooksConfig
  -> Logger
  -> ClusterTopology
  -> IO (Either Text ())
executeFailover tvar cc fc fdc password mHooks logger topo = do
  case selectCandidate (ctNodes topo) (fcCandidatePriority fc) Nothing of
    Left err -> do
      logError logger $ "[" <> ccName cc <> "] Auto-failover failed: " <> err
      pure (Left err)
    Right candidateId -> do
      let user          = credUser (ccCredentials cc)
          oldSourceHost = fmap nodeHost (ctSourceNodeId topo)

      ts <- getCurrentTimestamp
      let preEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost
                     (Just "DeadSource") ts
      preResult <- runHookOrAbort mHooks hcPreFailover preEnv
      case preResult of
        Left err -> do
          logError logger $ "[" <> ccName cc <> "] Pre-failover hook aborted failover: " <> err
          pure (Left $ "Pre-failover hook failed: " <> err)
        Right () -> do
          promoteResult <- promoteCandidate user password candidateId
          case promoteResult of
            Left err -> do
              logError logger $ "[" <> ccName cc <> "] Auto-failover failed: Promote failed: " <> err
              ts2 <- getCurrentTimestamp
              let failEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost
                              (Just "PromoteFailed") ts2
              runHookFireForget mHooks hcPostUnsuccessfulFailover failEnv
              pure (Left $ "Promote failed: " <> err)
            Right () -> do
              let otherReplicas = filter
                    (\ns -> nsNodeId ns /= candidateId && not (nsIsSource ns))
                    (Map.elems (ctNodes topo))
              mapM_ (reconnectReplica user password candidateId) otherReplicas

              now <- getCurrentTime
              atomically $ do
                recordFailover tvar (ccName cc) now
                setRecoveryBlock tvar (ccName cc) now (fdcRecoveryBlockPeriod fdc)

              ts3 <- getCurrentTimestamp
              let postEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost
                              (Just "DeadSource") ts3
              runHookFireForget mHooks hcPostFailover postEnv
              logInfo logger $ "[" <> ccName cc <> "] Auto-failover completed: new source is " <> nodeHost candidateId
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


