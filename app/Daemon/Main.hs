module Main (main) where

import Control.Concurrent.Async (async, waitAnyCancel)
import Control.Concurrent.STM (atomically)
import Control.Exception (try, SomeException)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import PureMyHA.Config
import PureMyHA.IPC.Server (startIPCServer, defaultSocketPath)
import PureMyHA.Logger (initLogger, logInfo)
import PureMyHA.Monitor.Worker (startMonitorWorkers)
import PureMyHA.Topology.Discovery (discoverTopology, buildInitialTopology)
import PureMyHA.Topology.State
import PureMyHA.Types

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

  clusterPasswords <- mapM (\cc -> (cc,) <$> loadPassword (ccCredentials cc)) (cfgClusters cfg)

  clusterEntries <- mapM (initCluster tvar cfg) clusterPasswords
  let clusterMap = Map.fromList
        [ (ccName cc, entry)
        | ((cc, _), entry) <- zip clusterPasswords clusterEntries
        ]

  allWorkers <- fmap concat $ mapM
    (\((cc, pw), _) -> startMonitorWorkers tvar cc (cfgMonitoring cfg) pw logger)
    (zip clusterPasswords clusterEntries)

  ipcAsync <- async $ startIPCServer tvar clusterMap (optSocketPath opts) logger

  logInfo logger "purermyhad started"
  _ <- waitAnyCancel (ipcAsync : allWorkers)
  pure ()

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
