module PureMyHA.Failover.Auto
  ( runAutoFailover
  , checkAutoFailoverPreconditions
  ) where

import Control.Concurrent.STM
import Control.Monad (when)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Class (lift)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.Logger (logInfo, logError)
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

-- | Execute automatic failover for a cluster
runAutoFailover :: App (Either Text ())
runAutoFailover = do
  lock <- asks envLock
  acquired <- liftIO $ atomically $ tryTakeTMVar lock
  case acquired of
    Nothing -> pure (Left "Failover already in progress")
    Just () -> do
      result <- doFailover
      liftIO $ atomically $ putTMVar lock ()
      pure result

-- | Check preconditions for auto failover (pure)
checkAutoFailoverPreconditions
  :: UTCTime
  -> ClusterTopology
  -> Int               -- ^ fcMinReplicasForFailover
  -> Either Text ()
checkAutoFailoverPreconditions now topo minReplicas = do
  when (ctPaused topo) $ Left "Failover paused by operator (pause-failover)"
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

doFailover :: App (Either Text ())
doFailover = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      appLogError $ "[" <> ccName cc <> "] Auto-failover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo -> do
      now <- liftIO getCurrentTime
      case checkAutoFailoverPreconditions now topo (fcMinReplicasForFailover fc) of
        Left err -> do
          appLogError $ "[" <> ccName cc <> "] Auto-failover failed: " <> err
          pure (Left err)
        Right () -> do
          appLogInfo $ "[" <> ccName cc <> "] Auto-failover started"
          recordAppEvent EvFailoverStarted Nothing "Auto-failover started"
          executeFailover topo

executeFailover :: ClusterTopology -> App (Either Text ())
executeFailover topo = runExceptT $ do
  cc <- lift $ asks envCluster
  fc <- lift $ asks envFailover
  let prefix = "[" <> ccName cc <> "] "
  candidateId <- ExceptT $ do
    case selectCandidate (ctNodes topo) (fcCandidatePriority fc) Nothing of
      Left err -> do
        appLogError (prefix <> "Auto-failover failed: " <> err)
        pure (Left err)
      Right c -> pure (Right c)
  let oldSourceHost = fmap nodeHost (ctSourceNodeId topo)
      waitTimeout   = truncate (fcWaitRelayLogTimeout fc) :: Int
  ExceptT $ runPreFailoverHook candidateId oldSourceHost
  lift $ appLogInfo $ prefix <> "Waiting for relay log apply on " <> nodeHost candidateId <> "..."
  ExceptT $ promoteWithOnFailureHook candidateId waitTimeout oldSourceHost
  lift $ reconnectOtherReplicas candidateId topo
  now <- liftIO getCurrentTime
  lift $ commitFailoverState topo now
  ts <- liftIO getCurrentTimestamp
  mHooks <- lift getHooksConfig
  let postEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  liftIO $ runHookFireForget mHooks hcPostFailover postEnv
  lift $ appLogInfo $ prefix <> "Auto-failover completed: new source is " <> nodeHost candidateId
  lift $ recordAppEvent EvFailoverCompleted (Just (nodeHost candidateId))
    ("Auto-failover completed: new source is " <> nodeHost candidateId)

runPreFailoverHook :: NodeId -> Maybe Text -> App (Either Text ())
runPreFailoverHook candidateId oldSourceHost = do
  cc     <- asks envCluster
  mHooks <- getHooksConfig
  ts <- liftIO getCurrentTimestamp
  let preEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost (Just "DeadSource") ts
  preResult <- liftIO $ runHookOrAbort mHooks hcPreFailover preEnv
  case preResult of
    Left err -> do
      appLogError $ "[" <> ccName cc <> "] Pre-failover hook aborted failover: " <> err
      pure (Left $ "Pre-failover hook failed: " <> err)
    Right () -> pure (Right ())

promoteWithOnFailureHook :: NodeId -> Int -> Maybe Text -> App (Either Text ())
promoteWithOnFailureHook candidateId waitTimeout oldSourceHost = do
  clusterName <- getClusterName
  promoteResult <- promoteCandidate candidateId waitTimeout
  case promoteResult of
    Left err -> do
      appLogError $ "[" <> clusterName <> "] Auto-failover failed: Promote failed: " <> err
      recordAppEvent EvFailoverFailed (Just (nodeHost candidateId)) ("Auto-failover failed: Promote failed: " <> err)
      ts <- liftIO getCurrentTimestamp
      mHooks <- getHooksConfig
      let failEnv = HookEnv clusterName (Just (nodeHost candidateId)) oldSourceHost (Just "PromoteFailed") ts
      liftIO $ runHookFireForget mHooks hcPostUnsuccessfulFailover failEnv
      pure (Left $ "Promote failed: " <> err)
    Right () -> pure (Right ())

reconnectOtherReplicas :: NodeId -> ClusterTopology -> App ()
reconnectOtherReplicas candidateId topo = do
  let otherReplicas = filter
        (\ns -> nsNodeId ns /= candidateId && not (nsIsSource ns))
        (Map.elems (ctNodes topo))
  mapM_ (reconnectReplica candidateId) otherReplicas

commitFailoverState :: ClusterTopology -> UTCTime -> App ()
commitFailoverState topo now = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fdc  <- asks envDetection
  let oldSources = filter nsIsSource (Map.elems (ctNodes topo))
  liftIO $ atomically $ do
    recordFailover tvar (ccName cc) now
    setRecoveryBlock tvar (ccName cc) now (fdcRecoveryBlockPeriod fdc)
    mapM_ (\ns -> updateNodeState tvar (ccName cc) (ns { nsIsSource = False })) oldSources

promoteCandidate :: NodeId -> Int -> App (Either Text ())
promoteCandidate nid waitTimeout = do
  user <- getMySQLUser
  password <- getMonPassword
  clusterName <- getClusterName
  logger <- asks envLogger >>= liftIO . readTVarIO
  let ci = makeConnectInfo nid user password
  liftIO $ do
    result <- withNodeConn ci $ \conn -> do
      caughtUp <- waitForRelayLogApply conn waitTimeout
      if caughtUp
        then logInfo logger $ "[" <> clusterName <> "] Relay log apply completed on " <> nodeHost nid
        else logError logger $ "[" <> clusterName <> "] WARNING: Relay log apply timed out on " <> nodeHost nid <> ", proceeding with promotion"
      stopReplica conn
      resetReplicaAll conn
      setReadWrite conn
    pure $ case result of
      Left err -> Left err
      Right () -> Right ()

reconnectReplica :: NodeId -> NodeState -> App ()
reconnectReplica newSourceId ns = do
  user <- getMySQLUser
  password <- getMonPassword
  pws <- asks envPasswords
  let ci = makeConnectInfo (nsNodeId ns) user password
  liftIO $ do
    _ <- withNodeConn ci $ \conn -> do
      stopReplica conn
      changeReplicationSourceTo conn (nodeHost newSourceId) (nodePort newSourceId) (cpReplUser pws) (cpReplPassword pws)
      setReadOnly conn
      startReplica conn
    pure ()
