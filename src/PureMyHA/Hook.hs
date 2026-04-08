{-# LANGUAGE StrictData #-}
module PureMyHA.Hook
  ( runHook
  , runHookFireForget
  , runHookOrAbort
  , getCurrentTimestamp
  , HookEnv (..)
  ) where

import Control.Concurrent.Async (async)
import Control.Exception (try, SomeException)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime, formatTime, defaultTimeLocale)
import System.Exit (ExitCode (..))
import System.Process (createProcess, proc, waitForProcess, env)
import PureMyHA.Config (HooksConfig (..))
import PureMyHA.Types (ClusterName, unClusterName, HostInfo, hiHostName, HostName (..))

data HookEnv = HookEnv
  { hookClusterName  :: ClusterName
  , hookNewSource    :: Maybe HostInfo
  , hookOldSource    :: Maybe HostInfo
  , hookFailureType  :: Maybe Text   -- e.g. "DeadSource", "PromoteFailed"
  , hookTimestamp    :: Text         -- ISO-8601 UTC: "2026-03-17T12:00:00Z"
  , hookLagSeconds   :: Maybe Int    -- e.g. 45 when on_lag_threshold_exceeded fires
  , hookNode         :: Maybe Text   -- hostname of the replica for lag threshold hooks
  , hookDriftType    :: Maybe Text   -- e.g. "missing_node" for on_topology_drift
  , hookDriftDetails :: Maybe Text   -- human-readable description of the drift
  }

getCurrentTimestamp :: IO Text
getCurrentTimestamp =
  T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

-- | Execute a hook script and wait for it to complete.
-- Returns Left with error message if the hook fails.
runHook :: FilePath -> HookEnv -> IO (Either Text ())
runHook scriptPath hookEnv = do
  let envVars =
        [ ("PUREMYHA_CLUSTER", T.unpack (unClusterName (hookClusterName hookEnv)))
        ] ++
        maybe [] (\h -> [("PUREMYHA_NEW_SOURCE", T.unpack (unHostName (hiHostName h)))]) (hookNewSource hookEnv) ++
        maybe [] (\h -> [("PUREMYHA_OLD_SOURCE", T.unpack (unHostName (hiHostName h)))]) (hookOldSource hookEnv) ++
        maybe [] (\ft -> [("PUREMYHA_FAILURE_TYPE", T.unpack ft)]) (hookFailureType hookEnv) ++
        maybe [] (\s  -> [("PUREMYHA_LAG_SECONDS", show s)]) (hookLagSeconds hookEnv) ++
        maybe [] (\n  -> [("PUREMYHA_NODE",        T.unpack n)]) (hookNode hookEnv) ++
        maybe [] (\dt -> [("PUREMYHA_DRIFT_TYPE",    T.unpack dt)]) (hookDriftType    hookEnv) ++
        maybe [] (\dd -> [("PUREMYHA_DRIFT_DETAILS", T.unpack dd)]) (hookDriftDetails hookEnv) ++
        [("PUREMYHA_TIMESTAMP", T.unpack (hookTimestamp hookEnv))]
  result <- try @SomeException $ do
    (_, _, _, ph) <- createProcess (proc scriptPath [T.unpack (unClusterName (hookClusterName hookEnv))])
      { env = Just envVars }
    exitCode <- waitForProcess ph
    pure exitCode
  case result of
    Left err ->
      pure $ Left $ "Hook failed with exception: " <> T.pack (show err)
    Right ExitSuccess ->
      pure $ Right ()
    Right (ExitFailure n) ->
      pure $ Left $ "Hook exited with code " <> T.pack (show n)

-- | Non-blocking fire-and-forget (post hooks, detection hooks)
runHookFireForget
  :: Maybe HooksConfig -> (HooksConfig -> Maybe FilePath) -> HookEnv -> IO ()
runHookFireForget Nothing _ _ = pure ()
runHookFireForget (Just hc) getter hookEnv =
  case getter hc of
    Nothing   -> pure ()
    Just path -> void $ async (runHook path hookEnv)

-- | Blocking: run hook and return Left if it fails, aborting the operation
runHookOrAbort
  :: Maybe HooksConfig -> (HooksConfig -> Maybe FilePath) -> HookEnv -> IO (Either Text ())
runHookOrAbort Nothing _ _ = pure (Right ())
runHookOrAbort (Just hc) getter hookEnv =
  case getter hc of
    Nothing   -> pure (Right ())
    Just path -> runHook path hookEnv
