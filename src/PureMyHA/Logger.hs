module PureMyHA.Logger
  ( Logger
  , initLogger
  , closeLogger
  , reopenLogger
  , logDebug
  , logInfo
  , logWarn
  , logError
  , nullLogger
  ) where

import Data.Text (Text)
import Katip
import PureMyHA.Config (LogLevel (..))
import System.IO (BufferMode (..), IOMode (..), hSetBuffering, openFile)

newtype Logger = Logger LogEnv

logLevelToSeverity :: LogLevel -> Severity
logLevelToSeverity LogLevelDebug = DebugS
logLevelToSeverity LogLevelInfo  = InfoS
logLevelToSeverity LogLevelWarn  = WarningS
logLevelToSeverity LogLevelError = ErrorS

initLogger :: FilePath -> LogLevel -> IO Logger
initLogger logFile level = do
  h <- openFile logFile AppendMode
  hSetBuffering h LineBuffering
  scribe <- mkHandleScribe ColorIfTerminal h (permitItem (logLevelToSeverity level)) V2
  le <- initLogEnv "puremyha" "production"
  le' <- registerScribe "file" scribe defaultScribeSettings le
  pure (Logger le')

closeLogger :: Logger -> IO ()
closeLogger (Logger le) = do
  _ <- closeScribes le
  pure ()

reopenLogger :: FilePath -> LogLevel -> Logger -> IO Logger
reopenLogger logFile level old = do
  closeLogger old
  initLogger logFile level

logAt :: Logger -> Severity -> Text -> IO ()
logAt (Logger le) sev msg =
  runKatipT le $ logMsg "puremyha" sev (logStr msg)

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
  pure (Logger le)
