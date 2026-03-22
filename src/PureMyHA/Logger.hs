module PureMyHA.Logger
  ( Logger
  , initLogger
  , closeLogger
  , reopenLogger
  , setLogLevel
  , logDebug
  , logInfo
  , logWarn
  , logError
  , nullLogger
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Data.Text (Text)
import Katip
import PureMyHA.Config (LogLevel (..))
import System.IO (BufferMode (..), IOMode (..), hSetBuffering, openFile)

data Logger = Logger LogEnv (TVar Severity)

logLevelToSeverity :: LogLevel -> Severity
logLevelToSeverity LogLevelDebug = DebugS
logLevelToSeverity LogLevelInfo  = InfoS
logLevelToSeverity LogLevelWarn  = WarningS
logLevelToSeverity LogLevelError = ErrorS

initLogger :: FilePath -> LogLevel -> IO Logger
initLogger logFile level = do
  h <- openFile logFile AppendMode
  hSetBuffering h LineBuffering
  scribe <- mkHandleScribe ColorIfTerminal h (permitItem DebugS) V2
  le <- initLogEnv "puremyha" "production"
  le' <- registerScribe "file" scribe defaultScribeSettings le
  sevVar <- newTVarIO (logLevelToSeverity level)
  pure (Logger le' sevVar)

closeLogger :: Logger -> IO ()
closeLogger (Logger le _) = do
  _ <- closeScribes le
  pure ()

-- | Reopen the log file (e.g. after log rotation via SIGUSR1).
-- Reuses the existing severity TVar so any runtime log level override is preserved.
reopenLogger :: FilePath -> Logger -> IO Logger
reopenLogger logFile old@(Logger _ sevVar) = do
  closeLogger old
  h <- openFile logFile AppendMode
  hSetBuffering h LineBuffering
  scribe <- mkHandleScribe ColorIfTerminal h (permitItem DebugS) V2
  le <- initLogEnv "puremyha" "production"
  le' <- registerScribe "file" scribe defaultScribeSettings le
  pure (Logger le' sevVar)

-- | Atomically update the minimum log level. Takes effect immediately on the
-- next log call without reopening or closing the log file.
setLogLevel :: Logger -> LogLevel -> IO ()
setLogLevel (Logger _ sevVar) level =
  atomically $ writeTVar sevVar (logLevelToSeverity level)

logAt :: Logger -> Severity -> Text -> IO ()
logAt (Logger le sevVar) sev msg = do
  minSev <- readTVarIO sevVar
  if sev >= minSev
    then runKatipT le $ logMsg "puremyha" sev (logStr msg)
    else pure ()

logDebug :: Logger -> Text -> IO ()
logDebug l = logAt l DebugS

logInfo :: Logger -> Text -> IO ()
logInfo l = logAt l InfoS

logWarn :: Logger -> Text -> IO ()
logWarn l = logAt l WarningS

logError :: Logger -> Text -> IO ()
logError l = logAt l ErrorS

nullLogger :: IO Logger
nullLogger = do
  le <- initLogEnv "test" "test"
  sevVar <- newTVarIO InfoS
  pure (Logger le sevVar)
