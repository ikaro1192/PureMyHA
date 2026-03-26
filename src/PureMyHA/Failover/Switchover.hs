module PureMyHA.Failover.Switchover
  ( runSwitchover
  , dryRunSwitchover
  , switchoverReconnectTargets
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (try, SomeException)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Database.MySQL.Base (ConnectInfo)
import PureMyHA.Config
import PureMyHA.Env
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
  ( runHookFireForget, runHookOrAbort, getCurrentTimestamp, HookEnv (..) )
import PureMyHA.MySQL.Connection (makeConnectInfo, withNodeConn)
import PureMyHA.MySQL.Query
import PureMyHA.Topology.State
import PureMyHA.Types

maxWaitSeconds :: Int
maxWaitSeconds = 60

-- | Nodes to reconnect after switchover: all nodes except the new source (pure)
switchoverReconnectTargets
  :: Map NodeId NodeState
  -> NodeId             -- ^ candidateId (promoted, excluded from result)
  -> [NodeState]
switchoverReconnectTargets nodes candidateId =
  filter (\ns -> nsNodeId ns /= candidateId) (Map.elems nodes)

-- | Execute a manual switchover
runSwitchover
  :: Maybe Text        -- ^ --to host
  -> App (Either Text ())
runSwitchover mToHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo ->
      case selectCandidate (fcNeverPromote fc) (fcMaxReplicaLagForCandidate fc) (ctNodes topo) (fcCandidatePriority fc) mToHost of
        Left err -> do
          appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: " <> err
          pure (Left err)
        Right candidateId -> do
          let oldSourceId   = ctSourceNodeId topo
              oldSourceHost = fmap nodeHost oldSourceId

          appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Switchover started"

          -- Pre-switchover hook (blocking: non-zero exit aborts)
          mHooks <- getHooksConfig
          ts <- liftIO getCurrentTimestamp
          let preEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost Nothing ts Nothing
          preResult <- liftIO $ runHookOrAbort mHooks hcPreSwitchover preEnv
          case preResult of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] Pre-switchover hook aborted: " <> err
              pure (Left $ "Pre-switchover hook failed: " <> err)
            Right () ->
              doSwitchover candidateId oldSourceId oldSourceHost topo

doSwitchover
  :: NodeId
  -> Maybe NodeId
  -> Maybe Text
  -> ClusterTopology
  -> App (Either Text ())
doSwitchover candidateId oldSourceId oldSourceHost topo = do
  cc    <- asks envCluster
  creds <- getMonCredentials
  mTls  <- getTLSConfig
  -- Step 1: Set old source to read_only (abort on failure to prevent split-brain)
  readOnlyResult <- liftIO $ case oldSourceId of
    Nothing -> pure (Right ())
    Just srcId -> do
      let srcCi = makeConnectInfo srcId creds
      withNodeConn mTls srcCi setReadOnly
  case readOnlyResult of
    Left err -> do
      appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover aborted: cannot set old source read_only: " <> err
      pure (Left $ "Cannot set old source read_only: " <> err)
    Right () -> do
      -- Step 2: Get old source GTID set
      mOldGtid <- liftIO $ case oldSourceId of
        Nothing -> pure Nothing
        Just srcId -> do
          let srcCi = makeConnectInfo srcId creds
          result <- withNodeConn mTls srcCi getGtidExecuted
          pure $ case result of
            Right gtid -> Just gtid
            Left _     -> Nothing

      -- Step 3: Wait for candidate to catch up
      let candidateCi = makeConnectInfo candidateId creds
      caught <- liftIO $ waitForCatchup mTls candidateCi mOldGtid maxWaitSeconds

      if not caught
        then do
          appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: Candidate did not catch up within timeout"
          pure (Left "Candidate did not catch up within timeout")
        else do
          -- Step 4: Promote candidate
          promoteResult <- liftIO $ withNodeConn mTls candidateCi $ \conn -> do
            stopReplica conn
            resetReplicaAll conn
            setReadWrite conn
          case promoteResult of
            Left err -> do
              appLogError $ "[" <> unClusterName (ccName cc) <> "] Switchover failed: Promote failed: " <> err
              pure (Left $ "Promote failed: " <> err)
            Right () -> do
              -- Step 5: Update topology roles atomically
              tvar <- asks envDaemonState
              liftIO $ atomically $ do
                case oldSourceId of
                  Just srcId ->
                    case Map.lookup srcId (ctNodes topo) of
                      Just srcNs -> updateNodeState tvar (ccName cc) (srcNs { nsRole = Replica })
                      Nothing -> pure ()
                  Nothing -> pure ()
                case Map.lookup candidateId (ctNodes topo) of
                  Just candNs -> updateNodeState tvar (ccName cc) (candNs { nsRole = Source })
                  Nothing -> pure ()
              -- Step 6: Reconnect remaining replicas (including old source)
              let others = switchoverReconnectTargets (ctNodes topo) candidateId
              mapM_ (reconnectToNew candidateId) others

              -- Post-switchover hook (fire-and-forget)
              mHooks <- getHooksConfig
              ts <- liftIO getCurrentTimestamp
              let postEnv = HookEnv (ccName cc) (Just (nodeHost candidateId)) oldSourceHost Nothing ts Nothing
              liftIO $ runHookFireForget mHooks hcPostSwitchover postEnv

              appLogInfo $ "[" <> unClusterName (ccName cc) <> "] Switchover completed: new source is " <> nodeHost candidateId
              pure (Right ())

waitForCatchup :: Maybe TLSConfig -> ConnectInfo -> Maybe Text -> Int -> IO Bool
waitForCatchup _ _ Nothing _ = pure True
waitForCatchup mTls ci (Just targetGtid) secondsLeft
  | secondsLeft <= 0 = pure False
  | otherwise = do
      result <- withNodeConn mTls ci $ \conn -> do
        mRs <- showReplicaStatus conn
        case mRs of
          Nothing -> pure True
          Just rs -> gtidSubset conn targetGtid (rsExecutedGtidSet rs)
      case result of
        Left _      -> do
          threadDelay 1_000_000
          waitForCatchup mTls ci (Just targetGtid) (secondsLeft - 1)
        Right True  -> pure True
        Right False -> do
          threadDelay 1_000_000
          waitForCatchup mTls ci (Just targetGtid) (secondsLeft - 1)

reconnectToNew :: NodeId -> NodeState -> App ()
reconnectToNew newSourceId ns = do
  monCreds  <- getMonCredentials
  replCreds <- getReplCredentials
  mTls      <- getTLSConfig
  let ci = makeConnectInfo (nsNodeId ns) monCreds
  liftIO $ do
    _ <- withNodeConn mTls ci $ \conn -> do
      _ <- try @SomeException (stopReplica conn)
      changeReplicationSourceTo conn (nodeHost newSourceId) (nodePort newSourceId) replCreds mTls
      setReadOnly conn
      startReplica conn
    pure ()

-- | Dry-run switchover: validate and select candidate without executing SQL
dryRunSwitchover
  :: Maybe Text          -- ^ --to host
  -> App (Either Text Text)
dryRunSwitchover mToHost = do
  tvar <- asks envDaemonState
  cc   <- asks envCluster
  fc   <- asks envFailover
  mTopo <- liftIO $ getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing   -> pure (Left "Cluster not found")
    Just topo ->
      case selectCandidate (fcNeverPromote fc) (fcMaxReplicaLagForCandidate fc) (ctNodes topo) (fcCandidatePriority fc) mToHost of
        Left  err         -> pure (Left err)
        Right candidateId ->
          pure (Right ("Dry run: would promote " <> nodeHost candidateId <> " to source"))
