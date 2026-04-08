{-# LANGUAGE BangPatterns #-}
module PureMyHA.Supervisor.StateManager
  ( newEventQueue
  , submitEvent
  , stateManager
  , executeHookAction
  ) where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM
import Control.Monad (forever, forM_, void)
import qualified Data.Text as T
import PureMyHA.Config
import PureMyHA.Env (ClusterEnv (..), runApp)
import PureMyHA.Failover.Auto (runAutoFailover, runAutoFence)
import PureMyHA.Hook (runHookFireForget, getCurrentTimestamp, HookEnv (..), SourceChange (..))
import PureMyHA.Logger (logInfo, logWarn)
import PureMyHA.Supervisor.Event (MonitorEvent, StateEffect (..), applyEvent)
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
    case applyEvent fdc fc mc old event of
      (!new, !effs) -> do
        writeTVar ctVar new
        pure effs
  -- Dispatch ALL effects asynchronously — never block the event loop
  forM_ effects $ \eff -> case eff of
    FireHookEffect hookEvent mNodeId ->
      void $ async $ do
        mHooks <- readTVarIO (envHooks env)
        executeHookAction mHooks (ccName (envCluster env)) mNodeId hookEvent
    TriggerActionEffect action ->
      void $ async $ case action of
        TriggerAutoFailover          -> void $ runApp env runAutoFailover
        TriggerAutoFence             -> runApp env runAutoFence
        TriggerEmergencyReplicaCheck -> emergencyCheck
        FireHook _                   -> pure ()  -- already handled by FireHookEffect
    LogHealthTransition _clusterName msg -> do
      let !prefix = "[" <> unClusterName (ccName (envCluster env)) <> "] "
          !line   = prefix <> msg
          !warn   = isWarnMessage msg
      void $ async $ do
        logger <- readTVarIO (envLogger env)
        if warn
          then logWarn logger line
          else logInfo logger line

-- | Execute a single hook action by dispatching to the appropriate hook script.
executeHookAction :: Maybe HooksConfig -> ClusterName -> Maybe NodeId -> HookEvent -> IO ()
executeHookAction mHooks clusterName mNid event = do
  ts <- getCurrentTimestamp
  let base = HookEnv { hookClusterName  = clusterName
                      , hookSourceChange = NoSourceChange
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
