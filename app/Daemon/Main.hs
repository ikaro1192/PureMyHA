module Main (main) where

import Control.Concurrent.Async (async, waitAnyCancel, race_, cancel)
import Control.Concurrent.STM   (TVar, atomically, newTVarIO, newEmptyTMVarIO,
                                  putTMVar, takeTMVar, writeTVar, readTVarIO, modifyTVar')
import Control.Exception (try, SomeException)
import Control.Monad (void, forM_)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (installHandler, sigTERM, sigINT, sigHUP, Handler(..))

import PureMyHA.Config
import PureMyHA.IPC.Server (startIPCServer, defaultSocketPath, DiscoveryAction)
import PureMyHA.Logger (Logger, initLogger, logInfo, logWarn, closeLogger)
import PureMyHA.Monitor.Worker (startMonitorWorkers, startTopologyRefreshWorker, WorkerRegistry, runWorker)
import PureMyHA.Topology.Discovery (discoverTopology, buildInitialTopology)
import PureMyHA.Topology.State
import PureMyHA.Types (ClusterTopology(..))

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
        <> value "/etc/puremyha/config.yaml"
        <> help "Path to configuration file" )
  <*> strOption
        ( long "socket"
        <> metavar "PATH"
        <> value defaultSocketPath
        <> help "Unix socket path" )

main :: IO ()
main = do
  opts <- execParser (info (daemonOptions <**> helper)
    (fullDesc <> progDesc "PureMyHA daemon" <> header "puremyhad"))

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

  clusterPasswords <- mapM (\cc -> (cc,) <$> loadClusterPasswords cc) (cfgClusters cfg)

  clusterEntries <- mapM (initCluster tvar cfg logger) clusterPasswords
  let clusterMap = Map.fromList
        [ (ccName cc, entry)
        | ((cc, _), entry) <- zip clusterPasswords clusterEntries
        ]

  -- Start monitor workers (returns registry per cluster)
  (registries, workerLists) <- fmap unzip $ mapM
    (\((cc, pws), (lock, _, fc, fdc, _, _)) ->
        startMonitorWorkers tvar cc mcVar hooksVar lock fc fdc pws logger)
    (zip clusterPasswords clusterEntries)
  let monitorWorkers = concat workerLists

  -- Start topology refresh workers
  refreshWorkers <- mapM
    (\((cc, pws), (lock, _, fc, fdc, _, _), reg) ->
        startTopologyRefreshWorker tvar cc mcVar hooksVar lock fc fdc pws reg logger)
    (zip3 clusterPasswords clusterEntries registries)

  -- Build discovery callbacks per cluster
  let discoveryMap = Map.fromList
        [ (ccName cc, makeDiscoveryAction tvar cc pws mcVar hooksVar lock fc fdc reg logger)
        | ((cc, pws), (lock, _, fc, fdc, _, _), reg) <- zip3 clusterPasswords clusterEntries registries
        ]

  ipcAsync <- async $ startIPCServer tvar clusterMap discoveryMap (optSocketPath opts) logger

  logInfo logger "puremyhad started"

  let allWorkers = ipcAsync : monitorWorkers <> refreshWorkers

  -- Wait for shutdown signal or any worker death
  race_
    (atomically (takeTMVar shutdownVar))
    (void (waitAnyCancel allWorkers))

  logInfo logger "puremyhad shutting down"
  mapM_ cancel allWorkers
  closeLogger logger

initCluster
  :: TVarDaemonState
  -> Config
  -> Logger
  -> (ClusterConfig, ClusterPasswords)
  -> IO (FailoverLock, ClusterConfig, FailoverConfig, FailureDetectionConfig, ClusterPasswords, Maybe HooksConfig)
initCluster tvar cfg logger (cc, pws) = do
  let initTopo = buildInitialTopology cc
  atomically $ updateClusterTopology tvar initTopo
  topo <- discoverTopology cc (cpPassword pws) logger
  logInfo logger $ "[" <> ccName cc <> "] Initial discovery found "
    <> T.pack (show (Map.size (ctNodes topo))) <> " node(s)"
  atomically $ updateClusterTopology tvar topo
  lock <- newFailoverLock
  pure (lock, cc, cfgFailover cfg, cfgFailureDetection cfg, pws, cfgHooks cfg)

loadClusterPasswords :: ClusterConfig -> IO ClusterPasswords
loadClusterPasswords cc = do
  monPw <- loadPassword (ccCredentials cc)
  let replCreds = fromMaybe (ccCredentials cc) (ccReplicationCredentials cc)
  replPw <- loadPassword replCreds
  pure $ ClusterPasswords monPw (credUser replCreds) replPw

loadPassword :: Credentials -> IO Text
loadPassword creds = do
  result <- try @SomeException $ T.strip . T.pack <$> readFile (credPasswordFile creds)
  case result of
    Left err  -> die $ "Failed to read password file: " <> show err
    Right pwd -> pure pwd

makeDiscoveryAction
  :: TVarDaemonState -> ClusterConfig -> ClusterPasswords
  -> TVar MonitoringConfig -> TVar (Maybe HooksConfig)
  -> FailoverLock -> FailoverConfig -> FailureDetectionConfig
  -> WorkerRegistry -> Logger -> DiscoveryAction
makeDiscoveryAction tvar cc pws mcVar hooksVar lock fc fdc reg logger = do
  newTopo <- discoverTopology cc (cpPassword pws) logger
  atomically $ updateClusterTopology tvar newTopo
  knownNodes <- Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes newTopo)
      newNodes   = Set.difference discovered knownNodes
  forM_ newNodes $ \nid -> do
    a <- async (runWorker tvar cc mcVar hooksVar lock fc fdc pws nid logger)
    atomically $ modifyTVar' reg (Map.insert nid a)
  pure $ Right $ "Discovery complete: " <> T.pack (show (Map.size (ctNodes newTopo)))
    <> " node(s) found, " <> T.pack (show (Set.size newNodes)) <> " new"

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure
