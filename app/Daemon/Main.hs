module Main (main) where

import Control.Concurrent.Async (Async, async, waitAnyCancel, race_, cancel)
import Control.Concurrent.MVar  (MVar, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM   (TMVar, TVar, atomically, newTVarIO, newEmptyTMVarIO,
                                  putTMVar, takeTMVar, writeTVar, readTVarIO, modifyTVar')
import Control.Exception (try, SomeException)
import Control.Monad (forever, void, forM_, when)
import Data.Foldable (find)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (installHandler, sigTERM, sigINT, sigHUP, sigUSR1, Handler(..))

import PureMyHA.Config
import PureMyHA.Env (ClusterEnv (..), runApp)
import PureMyHA.HTTP.Server (startHTTPServer)
import PureMyHA.IPC.Server (startIPCServer, defaultSocketPath, DiscoveryAction (..), ClusterMap (..), DiscoveryMap (..))
import PureMyHA.Logger (Logger, initLogger, closeLogger, reopenLogger, setLogLevel, logInfo, logWarn)
import qualified PureMyHA.PasswordFile as PasswordFile
import PureMyHA.Supervisor.StateManager (newEventQueue, stateManager)
import PureMyHA.Supervisor.Worker (startMonitorWorkers, startTopologyRefreshWorker, WorkerRegistry (..), runWorker, emergencyReplicaCheck)
import PureMyHA.Topology.Discovery (discoverTopology, buildInitialTopology)
import PureMyHA.Topology.State
import PureMyHA.Types (ClusterTopology(..), unClusterName)

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
  cfg       <- loadAndValidateConfig (optConfigPath opts)
  let logCfg = cfgLogging cfg
  loggerVar <- newTVarIO =<< initLogger (lcLogFile logCfg) (lcLogLevel logCfg)

  tvar        <- newDaemonState
  shutdownVar <- installShutdownHandlers

  clusterPasswords <- mapM (\cc -> (cc,) <$> loadClusterPasswords cc) (NE.toList (cfgClusters cfg))
  clusterEnvs      <- mapM (initCluster tvar loggerVar) clusterPasswords

  httpAsyncVar <- newTVarIO Nothing
  hupVar  <- installHUPSignaller
  usr1Var <- installUSR1Signaller

  baseWorkers    <- startAllWorkers clusterEnvs (optSocketPath opts) tvar loggerVar
  reloadAsync    <- async
    (configReloadWorker hupVar (optConfigPath opts) clusterEnvs loggerVar httpAsyncVar tvar)
  logReopenAsync <- async (logReopenWorker usr1Var (lcLogFile logCfg) loggerVar)
  let allWorkers = reloadAsync : logReopenAsync : baseWorkers
  case hcEnabled (cfgHttp cfg) of
    HttpEnabled -> do
      a <- async (startHTTPServer (cfgHttp cfg) tvar)
      atomically $ writeTVar httpAsyncVar (Just a)
    HttpDisabled -> pure ()

  logger <- readTVarIO loggerVar
  logInfo logger "puremyhad started"
  awaitShutdownAndCleanup loggerVar shutdownVar allWorkers httpAsyncVar

loadAndValidateConfig :: FilePath -> IO Config
loadAndValidateConfig path = do
  eCfg <- loadConfig path
  case eCfg of
    Left err -> die $ "Failed to load config: " <> err
    Right c  -> pure c

installShutdownHandlers :: IO (TMVar ())
installShutdownHandlers = do
  shutdownVar <- newEmptyTMVarIO
  let h = CatchOnce (atomically (putTMVar shutdownVar ()))
  _ <- installHandler sigTERM h Nothing
  _ <- installHandler sigINT  h Nothing
  pure shutdownVar

-- | Minimal async-signal-safe SIGHUP handler: only flips an MVar flag.
-- The actual reload runs on a normal worker thread (see 'configReloadWorker').
installHUPSignaller :: IO (MVar ())
installHUPSignaller = do
  hupVar <- newEmptyMVar
  _ <- installHandler sigHUP (Catch (void (tryPutMVar hupVar ()))) Nothing
  pure hupVar

reloadConfigOnce
  :: FilePath
  -> [ClusterEnv]
  -> TVar Logger
  -> TVar (Maybe (Async ()))
  -> TVarDaemonState
  -> IO ()
reloadConfigOnce configPath clusterEnvs loggerVar httpAsyncVar tvar = do
  logger <- readTVarIO loggerVar
  eCfg' <- loadConfig configPath
  case eCfg' of
    Left err   -> logWarn logger $ "SIGHUP: config reload failed: " <> T.pack err
    Right cfg' -> do
      forM_ clusterEnvs $ \env -> do
        let name = ccName (envCluster env)
        case find (\cc -> ccName cc == name) (NE.toList (cfgClusters cfg')) of
          Nothing -> logWarn logger $ "SIGHUP: cluster " <> unClusterName name <> " not found in new config"
          Just cc -> do
            atomically $ do
              writeTVar (envMonitoring env) (ccMonitoring cc)
              writeTVar (envHooks env)      (ccHooks cc)
            when (isSkipVerify (ccTLS cc)) $
              logWarn logger (skipVerifyWarningMessage (ccName cc))
      mOld <- readTVarIO httpAsyncVar
      forM_ mOld cancel
      case hcEnabled (cfgHttp cfg') of
        HttpEnabled -> do
          a <- async (startHTTPServer (cfgHttp cfg') tvar)
          atomically $ writeTVar httpAsyncVar (Just a)
        HttpDisabled -> atomically $ writeTVar httpAsyncVar Nothing
      setLogLevel logger (lcLogLevel (cfgLogging cfg'))
      logInfo logger "SIGHUP: config reloaded"

configReloadWorker
  :: MVar ()
  -> FilePath
  -> [ClusterEnv]
  -> TVar Logger
  -> TVar (Maybe (Async ()))
  -> TVarDaemonState
  -> IO ()
configReloadWorker hupVar configPath clusterEnvs loggerVar httpAsyncVar tvar = forever $ do
  takeMVar hupVar
  r <- try @SomeException (reloadConfigOnce configPath clusterEnvs loggerVar httpAsyncVar tvar)
  case r of
    Right () -> pure ()
    Left e -> do
      logger <- readTVarIO loggerVar
      logWarn logger $ "SIGHUP: reload worker caught exception: " <> T.pack (show e)

installUSR1Signaller :: IO (MVar ())
installUSR1Signaller = do
  usr1Var <- newEmptyMVar
  _ <- installHandler sigUSR1 (Catch (void (tryPutMVar usr1Var ()))) Nothing
  pure usr1Var

logReopenWorker :: MVar () -> FilePath -> TVar Logger -> IO ()
logReopenWorker usr1Var logFile loggerVar = forever $ do
  takeMVar usr1Var
  r <- try @SomeException $ do
    old <- readTVarIO loggerVar
    new <- reopenLogger logFile old
    atomically $ writeTVar loggerVar new
    logInfo new "SIGUSR1: log file reopened"
  case r of
    Right () -> pure ()
    Left e -> do
      logger <- readTVarIO loggerVar
      logWarn logger $ "SIGUSR1: log reopen worker caught exception: " <> T.pack (show e)

startAllWorkers :: [ClusterEnv] -> FilePath -> TVarDaemonState -> TVar Logger -> IO [Async ()]
startAllWorkers clusterEnvs socketPath tvar loggerVar = do
  let clusterMap = ClusterMap $ Map.fromList
        [ (ccName (envCluster env), env)
        | env <- clusterEnvs
        ]

  -- Spawn stateManager threads (one per cluster, before monitor workers)
  stateManagerAsyncs <- mapM (\env -> do
    let clName = ccName (envCluster env)
    mCtVar <- lookupClusterTVar tvar clName
    case mCtVar of
      Nothing    -> error $ "BUG: cluster TVar not found for " <> show (unClusterName clName)
      Just ctVar -> async $ stateManager (envEventQueue env) ctVar env
                              (runApp env emergencyReplicaCheck)
    ) clusterEnvs

  (registries, workerLists) <- fmap unzip $ mapM
    (\env -> runApp env startMonitorWorkers)
    clusterEnvs
  let monitorWorkers = concat workerLists

  refreshWorkers <- mapM
    (\(env, reg) -> runApp env (startTopologyRefreshWorker reg))
    (zip clusterEnvs registries)

  let discoveryMap = DiscoveryMap $ Map.fromList
        [ (ccName (envCluster env), makeDiscoveryAction env reg)
        | (env, reg) <- zip clusterEnvs registries
        ]

  ipcAsync <- async $ startIPCServer tvar clusterMap discoveryMap socketPath loggerVar

  pure $ ipcAsync : stateManagerAsyncs <> monitorWorkers <> refreshWorkers

awaitShutdownAndCleanup :: TVar Logger -> TMVar () -> [Async ()] -> TVar (Maybe (Async ())) -> IO ()
awaitShutdownAndCleanup loggerVar shutdownVar allWorkers httpAsyncVar = do
  race_
    (atomically (takeTMVar shutdownVar))
    (void (waitAnyCancel allWorkers))
  logger <- readTVarIO loggerVar
  logInfo logger "puremyhad shutting down"
  mapM_ cancel allWorkers
  mHttp <- readTVarIO httpAsyncVar
  forM_ mHttp cancel
  closeLogger logger

initCluster
  :: TVarDaemonState
  -> TVar Logger
  -> (ClusterConfig, ClusterPasswords)
  -> IO ClusterEnv
initCluster tvar loggerVar (cc, pws) = do
  let initTopo = buildInitialTopology cc
  atomically $ updateClusterTopology tvar initTopo
  lock     <- newFailoverLock
  mcVar    <- newTVarIO (ccMonitoring cc)
  hooksVar <- newTVarIO (ccHooks cc)
  let nodeCount = length (NE.toList (ccNodes cc))
  queue    <- newEventQueue nodeCount
  let env = ClusterEnv
        { envDaemonState = tvar
        , envCluster     = cc
        , envFailover    = ccFailover cc
        , envDetection   = ccFailureDetection cc
        , envPasswords   = pws
        , envMonitoring  = mcVar
        , envHooks       = hooksVar
        , envLock        = lock
        , envLogger      = loggerVar
        , envTLS         = ccTLS cc
        , envEventQueue  = queue
        }
  topo <- runApp env discoverTopology
  logger <- readTVarIO loggerVar
  when (isSkipVerify (ccTLS cc)) $
    logWarn logger (skipVerifyWarningMessage (ccName cc))
  logInfo logger $ "[" <> unClusterName (ccName cc) <> "] Initial discovery found "
    <> T.pack (show (Map.size (ctNodes topo))) <> " node(s)"
  atomically $ updateClusterTopology tvar topo
  pure env

loadClusterPasswords :: ClusterConfig -> IO ClusterPasswords
loadClusterPasswords cc = do
  monPw <- loadPassword (ccCredentials cc)
  let replCreds = fromMaybe (ccCredentials cc) (ccReplicationCredentials cc)
  replPw <- loadPassword replCreds
  pure $ ClusterPasswords
    { cpMonCredentials  = DbCredentials (credUser (ccCredentials cc)) monPw
    , cpReplCredentials = DbCredentials (credUser replCreds) replPw
    }

loadPassword :: Credentials -> IO Text
loadPassword creds = do
  result <- PasswordFile.loadPassword (credPasswordFile creds)
  case result of
    Left err  -> die $ T.unpack err
    Right pwd -> pure pwd

makeDiscoveryAction :: ClusterEnv -> WorkerRegistry -> DiscoveryAction
makeDiscoveryAction env (WorkerRegistry regTVar) = DiscoveryAction $ do
  let tvar = envDaemonState env
  newTopo <- runApp env discoverTopology
  atomically $ updateClusterTopology tvar newTopo
  knownNodes <- Map.keysSet <$> readTVarIO regTVar
  let discovered = Map.keysSet (ctNodes newTopo)
      newNodes   = Set.difference discovered knownNodes
  forM_ newNodes $ \nid -> do
    a <- async (runApp env (runWorker nid))
    atomically $ modifyTVar' regTVar (Map.insert nid a)
  pure $ Right $ "Discovery complete: " <> T.pack (show (Map.size (ctNodes newTopo)))
    <> " node(s) found, " <> T.pack (show (Set.size newNodes)) <> " new"

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure
