module PureMyHA.Failover.Switchover
  ( runSwitchover
  , switchoverReconnectTargets
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Database.MySQL.Base (ConnectInfo)
import PureMyHA.Config
import PureMyHA.Failover.Candidate (selectCandidate)
import PureMyHA.Hook
import PureMyHA.Logger (Logger, logInfo, logError)
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
  :: TVarDaemonState
  -> ClusterConfig
  -> FailoverConfig
  -> Text              -- ^ password
  -> Maybe Text        -- ^ --to host
  -> Maybe HooksConfig
  -> Logger
  -> IO (Either Text ())
runSwitchover tvar cc fc password mToHost mHooks logger = do
  mTopo <- getClusterTopology tvar (ccName cc)
  case mTopo of
    Nothing -> do
      logError logger $ "[" <> ccName cc <> "] Switchover failed: Cluster not found"
      pure (Left "Cluster not found")
    Just topo -> do
      -- Select target
      case selectCandidate (ctNodes topo) (fcCandidatePriority fc) mToHost of
        Left err -> do
          logError logger $ "[" <> ccName cc <> "] Switchover failed: " <> err
          pure (Left err)
        Right candidateId -> do
          let user         = credUser (ccCredentials cc)
              oldSourceId  = ctSourceNodeId topo
              oldSourceHost = fmap nodeHost oldSourceId

          logInfo logger $ "[" <> ccName cc <> "] Switchover started"

          -- Pre-switchover hook
          runHookMaybe mHooks hcPreSwitchover cc oldSourceHost (Just (nodeHost candidateId))

          -- Step 1: Set old source to read_only (if reachable)
          case oldSourceId of
            Nothing -> pure ()
            Just srcId -> do
              let srcCi = makeConnectInfo srcId user password
              _ <- withNodeConn srcCi setReadOnly
              pure ()

          -- Step 2: Get old source GTID set
          mOldGtid <- case oldSourceId of
            Nothing -> pure Nothing
            Just srcId -> do
              let srcCi = makeConnectInfo srcId user password
              result <- withNodeConn srcCi getGtidExecuted
              pure $ case result of
                Right gtid -> Just gtid
                Left _     -> Nothing

          -- Step 3: Wait for candidate to catch up
          let candidateCi = makeConnectInfo candidateId user password
          caught <- waitForCatchup candidateCi mOldGtid maxWaitSeconds

          if not caught
            then do
              logError logger $ "[" <> ccName cc <> "] Switchover failed: Candidate did not catch up within timeout"
              pure (Left "Candidate did not catch up within timeout")
            else do
              -- Step 4: Promote candidate
              promoteResult <- withNodeConn candidateCi $ \conn -> do
                stopReplica conn
                resetReplicaAll conn
                setReadWrite conn
              case promoteResult of
                Left err -> do
                  logError logger $ "[" <> ccName cc <> "] Switchover failed: Promote failed: " <> err
                  pure (Left $ "Promote failed: " <> err)
                Right () -> do
                  -- Step 5: Reconnect remaining replicas (including old source)
                  let others = switchoverReconnectTargets (ctNodes topo) candidateId
                  mapM_ (reconnectToNew user password candidateId) others

                  -- Post-switchover hook
                  runHookMaybe mHooks hcPostSwitchover cc oldSourceHost (Just (nodeHost candidateId))

                  logInfo logger $ "[" <> ccName cc <> "] Switchover completed: new source is " <> nodeHost candidateId
                  pure (Right ())

waitForCatchup :: ConnectInfo -> Maybe Text -> Int -> IO Bool
waitForCatchup _ Nothing _ = pure True
waitForCatchup ci (Just targetGtid) secondsLeft
  | secondsLeft <= 0 = pure False
  | otherwise = do
      result <- withNodeConn ci $ \conn -> do
        mRs <- showReplicaStatus conn
        case mRs of
          Nothing -> pure True
          Just rs -> gtidSubset conn (rsExecutedGtidSet rs) targetGtid
      case result of
        Left _      -> pure False
        Right True  -> pure True
        Right False -> do
          threadDelay 1_000_000
          waitForCatchup ci (Just targetGtid) (secondsLeft - 1)

reconnectToNew :: Text -> Text -> NodeId -> NodeState -> IO ()
reconnectToNew user password newSourceId ns = do
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
