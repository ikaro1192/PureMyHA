module Main (main) where

import Control.Concurrent.Async (async, waitAnyCancel, race_, cancel)
import Control.Concurrent.STM   (atomically, newTVarIO, newEmptyTMVarIO,
                                  putTMVar, takeTMVar, writeTVar)
import Control.Exception (try, SomeException)
import Control.Monad (void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (installHandler, sigTERM, sigINT, sigHUP, Handler(..))

import PureMyHA.Config
import PureMyHA.IPC.Server (startIPCServer, defaultSocketPath)
import PureMyHA.Logger (initLogger, logInfo, logWarn, closeLogger)
import PureMyHA.Monitor.Worker (startMonitorWorkers, startTopologyRefreshWorker)
import PureMyHA.Topology.Discovery (discoverTopology, buildInitialTopology)
import PureMyHA.Topology.State

data DaemonOptions = DaemonOptions
  { optConfigPath :: FilePath
  , optSocketPath :: FilePath
  }

daemonOptions :: Parser DaemonOptions
daemonOptions = DaemonOptions
  <$> strOption
        ( long "config"
        <> short 'c'
        <> metavar "FILE"
        <> value "/etc/purermyha/config.yaml"
        <> help "Path to configuration file" )
  <*> strOption
        ( long "socket"
        <> metavar "PATH"
        <> value defaultSocketPath
        <> help "Unix socket path" )

main :: IO ()
main = do
  opts <- execParser (info (daemonOptions <**> helper)
    (fullDesc <> progDesc "PureMyHA daemon" <> header "purermyhad"))

  eCfg <- loadConfig (optConfigPath opts)
  cfg <- case eCfg of
    Left err  -> die $ "Failed to load config: " <> err
    Right c   -> pure c

  let logFile = lcLogFile (cfgLogging cfg)
  logger <- initLogger logFile

  tvar <- newDaemonState

  -- TVar-wrapped config for hot-reload
  mcVar    <- newTVarIO (cfgMonitoring cfg)
  hooksVar <- newTVarIO (cfgHooks cfg)

  -- Shutdown signal
  shutdownVar <- newEmptyTMVarIO

  -- SIGTERM / SIGINT: graceful shutdown
  let shutdownHandler = CatchOnce (atomically (putTMVar shutdownVar ()))
  _ <- installHandler sigTERM shutdownHandler Nothing
  _ <- installHandler sigINT  shutdownHandler Nothing

  -- SIGHUP: hot-reload config
  _ <- installHandler sigHUP (Catch $ do
    eCfg' <- loadConfig (optConfigPath opts)
    case eCfg' of
      Left err   -> logWarn logger $ "SIGHUP: config reload failed: " <> T.pack err
      Right cfg' -> do
        atomically $ do
          writeTVar mcVar    (cfgMonitoring cfg')
          writeTVar hooksVar (cfgHooks cfg')
        logInfo logger "SIGHUP: config reloaded") Nothing

  clusterPasswords <- mapM (\cc -> (cc,) <$> loadPassword (ccCredentials cc)) (cfgClusters cfg)

  clusterEntries <- mapM (initCluster tvar cfg) clusterPasswords
  let clusterMap = Map.fromList
        [ (ccName cc, entry)
        | ((cc, _), entry) <- zip clusterPasswords clusterEntries
        ]

  -- Start monitor workers (returns registry per cluster)
  (registries, workerLists) <- fmap unzip $ mapM
    (\((cc, pw), _) -> startMonitorWorkers tvar cc mcVar hooksVar pw logger)
    (zip clusterPasswords clusterEntries)
  let monitorWorkers = concat workerLists

  -- Start topology refresh workers
  refreshWorkers <- mapM
    (\((cc, pw), reg) -> startTopologyRefreshWorker tvar cc mcVar hooksVar pw reg logger)
    (zip clusterPasswords registries)

  ipcAsync <- async $ startIPCServer tvar clusterMap (optSocketPath opts) logger

  logInfo logger "purermyhad started"

  let allWorkers = ipcAsync : monitorWorkers <> refreshWorkers

  -- Wait for shutdown signal or any worker death
  race_
    (atomically (takeTMVar shutdownVar))
    (void (waitAnyCancel allWorkers))

  logInfo logger "purermyhad shutting down"
  mapM_ cancel allWorkers
  closeLogger logger

initCluster
  :: TVarDaemonState
  -> Config
  -> (ClusterConfig, Text)
  -> IO (FailoverLock, ClusterConfig, FailoverConfig, FailureDetectionConfig, Text, Maybe HooksConfig)
initCluster tvar cfg (cc, password) = do
  let initTopo = buildInitialTopology cc
  atomically $ updateClusterTopology tvar initTopo
  topo <- discoverTopology cc password
  atomically $ updateClusterTopology tvar topo
  lock <- newFailoverLock
  pure (lock, cc, cfgFailover cfg, cfgFailureDetection cfg, password, cfgHooks cfg)

loadPassword :: Credentials -> IO Text
loadPassword creds = do
  result <- try @SomeException $ T.strip . T.pack <$> readFile (credPasswordFile creds)
  case result of
    Left err  -> die $ "Failed to read password file: " <> show err
    Right pwd -> pure pwd

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure
