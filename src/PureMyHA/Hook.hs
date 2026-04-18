{-# LANGUAGE StrictData #-}
module PureMyHA.Hook
  ( runHook
  , runHookFireForget
  , runHookOrAbort
  , getCurrentTimestamp
  , HookEnv (..)
  , SourceChange (..)
  , HookRejection (..)
  , HookScriptStat (..)
  , validateHookScript
  , validateHookScriptIO
  , rejectionMessage
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (try, SomeException)
import Control.Monad (void)
import Data.Bits ((.&.))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (NominalDiffTime, getCurrentTime, formatTime, defaultTimeLocale)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)
import qualified System.Posix.Files as PF
import System.Posix.Signals (signalProcessGroup, sigKILL)
import System.Posix.Types (FileMode, UserID)
import qualified System.Posix.User as PU
import System.Process
  ( CreateProcess (..), ProcessHandle, createProcess, proc
  , waitForProcess, terminateProcess, getProcessExitCode, getPid
  )
import PureMyHA.Config (HooksConfig (..), PositiveDuration (..))
import PureMyHA.Types (ClusterName, unClusterName, HostInfo, hiHostName, HostName (..))

-- | Describes how the source role changed for a hook invocation.
--
-- The wire contract for external hook scripts is preserved exactly:
-- 'NoSourceChange'           -> neither PUREMYHA_NEW_SOURCE nor PUREMYHA_OLD_SOURCE is set.
-- 'InitialSourcePromotion'   -> only PUREMYHA_NEW_SOURCE is set (no prior source detected).
-- 'SourceChanged'            -> both PUREMYHA_NEW_SOURCE and PUREMYHA_OLD_SOURCE are set.
data SourceChange
  = NoSourceChange
  | InitialSourcePromotion { scNewSource :: HostInfo }
  | SourceChanged          { scOldSource :: HostInfo, scNewSource :: HostInfo }
  deriving (Eq, Show)

-- | Why a hook script was rejected before execution.
data HookRejection
  = NotAbsolutePath
  | NotRegularFile   -- ^ Symlink, directory, device, etc.
  | UntrustedOwner   -- ^ Not root and not the daemon user
  | WorldWritable    -- ^ Other-write bit (0o002) is set
  deriving (Eq, Show)

-- | Subset of stat(2) needed to decide whether a hook script is safe to run.
-- Extracted so 'validateHookScript' can stay pure and easy to test.
data HookScriptStat = HookScriptStat
  { hssIsRegularFile :: Bool
  , hssOwner         :: UserID
  , hssMode          :: FileMode
  } deriving (Eq, Show)

-- | Pure validator for a hook script. Rejects the script unless:
--
--   * path is absolute,
--   * it is a regular file (not a symlink, directory, or special file),
--   * its owner is root (UID 0) or the supplied daemon UID,
--   * its mode does not have the world-writable bit (0o002) set.
validateHookScript
  :: FilePath       -- ^ script path as configured
  -> HookScriptStat -- ^ stat information for the script
  -> UserID         -- ^ daemon's real UID
  -> Either HookRejection ()
validateHookScript path stat daemonUid
  | not (isAbsolute path)                           = Left NotAbsolutePath
  | not (hssIsRegularFile stat)                     = Left NotRegularFile
  | hssOwner stat /= 0 && hssOwner stat /= daemonUid = Left UntrustedOwner
  | hssMode stat .&. 0o002 /= 0                     = Left WorldWritable
  | otherwise                                       = Right ()

-- | Render a 'HookRejection' as an operator-facing error message that names
-- the offending script path.
rejectionMessage :: FilePath -> HookRejection -> Text
rejectionMessage path r = case r of
  NotAbsolutePath -> "Hook script path must be absolute: " <> T.pack path
  NotRegularFile  -> "Hook script is not a regular file (symlink/dir rejected): " <> T.pack path
  UntrustedOwner  -> "Hook script owner is neither root nor the daemon user: " <> T.pack path
  WorldWritable   -> "Hook script is world-writable (mode 0o002 set): " <> T.pack path

-- | IO wrapper around 'validateHookScript': stats the path (without following
-- symlinks) and looks up the daemon's real UID, then delegates to the pure
-- validator. Returns 'Left' with a human-readable message on any failure —
-- including stat failures such as ENOENT.
validateHookScriptIO :: FilePath -> IO (Either Text ())
validateHookScriptIO path
  | not (isAbsolute path) =
      pure $ Left (rejectionMessage path NotAbsolutePath)
  | otherwise = do
      eStat <- try @SomeException (PF.getSymbolicLinkStatus path)
      case eStat of
        Left err -> pure $ Left $
          "Hook script stat failed for " <> T.pack path <> ": " <> T.pack (show err)
        Right fs -> do
          daemonUid <- PU.getRealUserID
          let stat = HookScriptStat
                { hssIsRegularFile = PF.isRegularFile fs
                , hssOwner         = PF.fileOwner fs
                , hssMode          = PF.fileMode fs
                }
          pure $ case validateHookScript path stat daemonUid of
            Right ()  -> Right ()
            Left rej  -> Left (rejectionMessage path rej)

data HookEnv = HookEnv
  { hookClusterName  :: ClusterName
  , hookSourceChange :: SourceChange
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

-- | Execute a hook script and wait for it to complete, subject to a timeout.
--
-- Before launching the child process the script is validated via
-- 'validateHookScriptIO' (absolute path, regular file, trusted owner, not
-- world-writable). The child is started as a new process group leader so that
-- any sub-processes it forks can be killed on timeout. If the hook does not
-- exit within the timeout, the process group is sent SIGTERM, given a short
-- grace period, and then sent SIGKILL.
runHook :: NominalDiffTime -> FilePath -> HookEnv -> IO (Either Text ())
runHook hookTimeoutDur scriptPath hookEnv = do
  vres <- validateHookScriptIO scriptPath
  case vres of
    Left err -> pure (Left err)
    Right () -> runValidatedHook hookTimeoutDur scriptPath hookEnv

-- | Launch a validated hook script with the supplied timeout.
runValidatedHook :: NominalDiffTime -> FilePath -> HookEnv -> IO (Either Text ())
runValidatedHook hookTimeoutDur scriptPath hookEnv = do
  let sourceVars = case hookSourceChange hookEnv of
        NoSourceChange -> []
        InitialSourcePromotion newH ->
          [("PUREMYHA_NEW_SOURCE", T.unpack (unHostName (hiHostName newH)))]
        SourceChanged oldH newH ->
          [ ("PUREMYHA_NEW_SOURCE", T.unpack (unHostName (hiHostName newH)))
          , ("PUREMYHA_OLD_SOURCE", T.unpack (unHostName (hiHostName oldH)))
          ]
      envVars =
        [ ("PUREMYHA_CLUSTER", T.unpack (unClusterName (hookClusterName hookEnv)))
        ] ++
        sourceVars ++
        maybe [] (\ft -> [("PUREMYHA_FAILURE_TYPE", T.unpack ft)]) (hookFailureType hookEnv) ++
        maybe [] (\s  -> [("PUREMYHA_LAG_SECONDS", show s)]) (hookLagSeconds hookEnv) ++
        maybe [] (\n  -> [("PUREMYHA_NODE",        T.unpack n)]) (hookNode hookEnv) ++
        maybe [] (\dt -> [("PUREMYHA_DRIFT_TYPE",    T.unpack dt)]) (hookDriftType    hookEnv) ++
        maybe [] (\dd -> [("PUREMYHA_DRIFT_DETAILS", T.unpack dd)]) (hookDriftDetails hookEnv) ++
        [("PUREMYHA_TIMESTAMP", T.unpack (hookTimestamp hookEnv))]
      timeoutMicros = max 1 (round (realToFrac hookTimeoutDur * 1_000_000 :: Double)) :: Int
      graceMicros   = 2_000_000 :: Int
  result <- try @SomeException $ do
    (_, _, _, ph) <- createProcess
      (proc scriptPath [T.unpack (unClusterName (hookClusterName hookEnv))])
        { env          = Just envVars
        , create_group = True
        }
    mExit <- pollForExit ph timeoutMicros
    case mExit of
      Just ec -> pure (Right ec)
      Nothing -> do
        terminateProcess ph
        mExit2 <- pollForExit ph graceMicros
        case mExit2 of
          Just _  -> pure (Left timedOutMsg)
          Nothing -> do
            mPid <- getPid ph
            case mPid of
              Just pid -> signalProcessGroup sigKILL pid
              Nothing  -> pure ()
            _ <- waitForProcess ph
            pure (Left timedOutMsg)
  case result of
    Left err                      -> pure $ Left $ "Hook failed with exception: " <> T.pack (show err)
    Right (Left tmsg)             -> pure (Left tmsg)
    Right (Right ExitSuccess)     -> pure (Right ())
    Right (Right (ExitFailure n)) -> pure $ Left $ "Hook exited with code " <> T.pack (show n)
  where
    timedOutMsg =
      "Hook timed out after "
        <> T.pack (show (realToFrac hookTimeoutDur :: Double))
        <> "s; process group killed"

-- | Wait for the child process to exit, polling every 50ms up to the given
-- budget of microseconds. Using 'getProcessExitCode' (non-blocking) rather
-- than 'waitForProcess' avoids being trapped in an uninterruptible FFI call
-- when a timeout tries to abort us — an issue observed on macOS.
pollForExit :: ProcessHandle -> Int -> IO (Maybe ExitCode)
pollForExit ph budget
  | budget <= 0 = do
      mEC <- getProcessExitCode ph
      pure mEC
  | otherwise = do
      mEC <- getProcessExitCode ph
      case mEC of
        Just ec -> pure (Just ec)
        Nothing -> do
          let tick = 50_000
              step = min tick budget
          threadDelay step
          pollForExit ph (budget - step)

-- | Non-blocking fire-and-forget (post hooks, detection hooks)
runHookFireForget
  :: Maybe HooksConfig -> (HooksConfig -> Maybe FilePath) -> HookEnv -> IO ()
runHookFireForget Nothing _ _ = pure ()
runHookFireForget (Just hc) getter hookEnv =
  case getter hc of
    Nothing   -> pure ()
    Just path -> void $ async (runHook (unPositiveDuration (hcTimeout hc)) path hookEnv)

-- | Blocking: run hook and return Left if it fails, aborting the operation
runHookOrAbort
  :: Maybe HooksConfig -> (HooksConfig -> Maybe FilePath) -> HookEnv -> IO (Either Text ())
runHookOrAbort Nothing _ _ = pure (Right ())
runHookOrAbort (Just hc) getter hookEnv =
  case getter hc of
    Nothing   -> pure (Right ())
    Just path -> runHook (unPositiveDuration (hcTimeout hc)) path hookEnv
