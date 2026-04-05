module PureMyHA.Monitor.StateManager
  ( newEventQueue
  , submitEvent
  , stateManager
  , executeHookAction
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM
import Control.Monad (forever, forM_)
import qualified Data.Text as T
import PureMyHA.Config
import PureMyHA.Env (ClusterEnv (..), runApp)
import PureMyHA.Failover.Auto (runAutoFailover, runAutoFence)
import PureMyHA.Hook (runHookFireForget, getCurrentTimestamp, HookEnv (..))
import PureMyHA.Logger (logInfo, logWarn)
import PureMyHA.Monitor.Event (MonitorEvent, StateEffect (..), applyEvent)
import PureMyHA.Types

-- | Create a new bounded event queue with capacity = nodeCount * 2.
-- TBQueue provides backpressure to prevent space leaks: if the queue is full,
-- producers block via STM retry until the stateManager drains an event.
newEventQueue :: Int -> IO (TBQueue MonitorEvent)
newEventQueue nodeCount = newTBQueueIO (fromIntegral (max 4 (nodeCount * 2)))

-- | Submit an event to the queue (STM, may retry if full).
submitEvent :: TBQueue MonitorEvent -> MonitorEvent -> STM ()
submitEvent = writeTBQueue

-- | Single-writer state manager thread.
-- Dequeues events, applies the pure reducer to update the TVar, and dispatches
-- side effects asynchronously. This thread is the ONLY writer to the TVar.
--
-- The @onEmergencyReplicaCheck@ callback avoids a circular import with Worker.hs.
stateManager
  :: TBQueue MonitorEvent
  -> TVar ClusterTopology    -- ^ inner TVar for this cluster
  -> ClusterEnv
  -> IO ()                   -- ^ emergency replica check action
  -> IO ()
stateManager queue ctVar env emergencyCheck = forever $ do
  -- Atomically: dequeue one event, apply reducer, write new state
  effects <- atomically $ do
    event <- readTBQueue queue
    old   <- readTVar ctVar
    let fdc = envDetection env
        fc  = envFailover env
    mc <- readTVar (envMonitoring env)
    let (new, effs) = applyEvent fdc fc mc old event
    writeTVar ctVar new
    pure effs
  -- Dispatch ALL effects asynchronously — never block the event loop
  forM_ effects $ \eff -> case eff of
    FireHookEffect hookEvent mNodeId -> do
      _ <- async $ do
        mHooks <- readTVarIO (envHooks env)
        executeHookAction mHooks (ccName (envCluster env)) mNodeId hookEvent
      pure ()
    TriggerActionEffect action -> do
      _ <- async $ case action of
        TriggerAutoFailover          -> do { _ <- runApp env runAutoFailover; pure () }
        TriggerAutoFence             -> runApp env runAutoFence
        TriggerEmergencyReplicaCheck -> emergencyCheck
        FireHook _                   -> pure ()  -- already handled by FireHookEffect
      pure ()
    LogHealthTransition _clusterName msg -> do
      _ <- async $ do
        logger <- readTVarIO (envLogger env)
        let prefix = "[" <> unClusterName (ccName (envCluster env)) <> "] "
        if isWarnMessage msg
          then logWarn logger (prefix <> msg)
          else logInfo logger (prefix <> msg)
      pure ()

-- | Execute a single hook action by dispatching to the appropriate hook script.
executeHookAction :: Maybe HooksConfig -> ClusterName -> Maybe NodeId -> HookEvent -> IO ()
executeHookAction mHooks clusterName mNid event = do
  ts <- getCurrentTimestamp
  let base = HookEnv { hookClusterName  = clusterName
                      , hookNewSource    = Nothing
                      , hookOldSource    = Nothing
                      , hookFailureType  = Nothing
                      , hookTimestamp    = ts
                      , hookLagSeconds   = Nothing
                      , hookNode         = fmap (unHostName . nodeHost) mNid
                      , hookDriftType    = Nothing
                      , hookDriftDetails = Nothing
                      }
  case event of
    OnFailureDetection ft ->
      runHookFireForget mHooks hcOnFailureDetection
        base { hookFailureType = Just ft }
    OnTopologyDrift dt dd ->
      runHookFireForget mHooks hcOnTopologyDrift
        base { hookDriftType = Just dt, hookDriftDetails = Just dd }
    OnLagThresholdExceeded lag ->
      runHookFireForget mHooks hcOnLagThresholdExceeded
        base { hookLagSeconds = Just lag }
    OnLagThresholdRecovered ->
      runHookFireForget mHooks hcOnLagThresholdRecovered base

-- | Determine log severity from message content
isWarnMessage :: T.Text -> Bool
isWarnMessage msg = T.isInfixOf "unreachable" msg || T.isInfixOf "initial connect failed" msg
