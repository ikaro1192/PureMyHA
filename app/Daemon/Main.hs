module Main (main) where

import Control.Concurrent.Async (Async, async, waitAnyCancel, race_, cancel)
import Control.Concurrent.STM   (TMVar, TVar, atomically, newTVarIO, newEmptyTMVarIO,
                                  putTMVar, takeTMVar, writeTVar, readTVarIO, modifyTVar')
import Control.Exception (try, SomeException)
import Control.Monad (void, when, forM_)
import Data.List (find)
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
import PureMyHA.IPC.Server (startIPCServer, defaultSocketPath, DiscoveryAction)
import PureMyHA.Logger (Logger, initLogger, closeLogger, reopenLogger, setLogLevel, logInfo, logWarn)
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
  cfg       <- loadAndValidateConfig (optConfigPath opts)
  let logCfg = cfgLogging cfg
  loggerVar <- newTVarIO =<< initLogger (lcLogFile logCfg) (lcLogLevel logCfg)

  tvar        <- newDaemonState
  shutdownVar <- installShutdownHandlers

  clusterPasswords <- mapM (\cc -> (cc,) <$> loadClusterPasswords cc) (cfgClusters cfg)
  clusterEnvs      <- mapM (initCluster tvar loggerVar) clusterPasswords

  httpAsyncVar <- newTVarIO Nothing
  installHUPHandler (optConfigPath opts) clusterEnvs loggerVar httpAsyncVar tvar
  installUSR1Handler (lcLogFile (cfgLogging cfg)) loggerVar

  allWorkers <- startAllWorkers clusterEnvs (optSocketPath opts) tvar loggerVar
  when (hcEnabled (cfgHttp cfg)) $ do
    a <- async (startHTTPServer (cfgHttp cfg) tvar)
    atomically $ writeTVar httpAsyncVar (Just a)

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

installHUPHandler :: FilePath -> [ClusterEnv] -> TVar Logger -> TVar (Maybe (Async ())) -> TVarDaemonState -> IO ()
installHUPHandler configPath clusterEnvs loggerVar httpAsyncVar tvar = do
  _ <- installHandler sigHUP (Catch $ do
    logger <- readTVarIO loggerVar
    eCfg' <- loadConfig configPath
    case eCfg' of
      Left err   -> logWarn logger $ "SIGHUP: config reload failed: " <> T.pack err
      Right cfg' -> do
        forM_ clusterEnvs $ \env -> do
          let name = ccName (envCluster env)
          case find (\cc -> ccName cc == name) (cfgClusters cfg') of
            Nothing -> logWarn logger $ "SIGHUP: cluster " <> name <> " not found in new config"
            Just cc -> atomically $ do
              writeTVar (envMonitoring env) (ccMonitoring cc)
              writeTVar (envHooks env)      (ccHooks cc)
        mOld <- readTVarIO httpAsyncVar
        forM_ mOld cancel
        if hcEnabled (cfgHttp cfg')
          then do
            a <- async (startHTTPServer (cfgHttp cfg') tvar)
            atomically $ writeTVar httpAsyncVar (Just a)
          else atomically $ writeTVar httpAsyncVar Nothing
        setLogLevel logger (lcLogLevel (cfgLogging cfg'))
        logInfo logger "SIGHUP: config reloaded"
        ) Nothing
  pure ()

installUSR1Handler :: FilePath -> TVar Logger -> IO ()
installUSR1Handler logFile loggerVar = do
  _ <- installHandler sigUSR1 (Catch $ do
    old <- readTVarIO loggerVar
    new <- reopenLogger logFile old
    atomically $ writeTVar loggerVar new
    logInfo new "SIGUSR1: log file reopened") Nothing
  pure ()

startAllWorkers :: [ClusterEnv] -> FilePath -> TVarDaemonState -> TVar Logger -> IO [Async ()]
startAllWorkers clusterEnvs socketPath tvar loggerVar = do
  let clusterMap = Map.fromList
        [ (ccName (envCluster env), env)
        | env <- clusterEnvs
        ]

  (registries, workerLists) <- fmap unzip $ mapM
    (\env -> runApp env startMonitorWorkers)
    clusterEnvs
  let monitorWorkers = concat workerLists

  refreshWorkers <- mapM
    (\(env, reg) -> runApp env (startTopologyRefreshWorker reg))
    (zip clusterEnvs registries)

  let discoveryMap = Map.fromList
        [ (ccName (envCluster env), makeDiscoveryAction env reg)
        | (env, reg) <- zip clusterEnvs registries
        ]

  ipcAsync <- async $ startIPCServer tvar clusterMap discoveryMap socketPath loggerVar

  pure $ ipcAsync : monitorWorkers <> refreshWorkers

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
        }
  topo <- runApp env discoverTopology
  logger <- readTVarIO loggerVar
  logInfo logger $ "[" <> ccName cc <> "] Initial discovery found "
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
  result <- try @SomeException $ T.strip . T.pack <$> readFile (credPasswordFile creds)
  case result of
    Left err  -> die $ "Failed to read password file: " <> show err
    Right pwd -> pure pwd

makeDiscoveryAction :: ClusterEnv -> WorkerRegistry -> DiscoveryAction
makeDiscoveryAction env reg = do
  let tvar = envDaemonState env
  newTopo <- runApp env discoverTopology
  atomically $ updateClusterTopology tvar newTopo
  knownNodes <- Map.keysSet <$> readTVarIO reg
  let discovered = Map.keysSet (ctNodes newTopo)
      newNodes   = Set.difference discovered knownNodes
  forM_ newNodes $ \nid -> do
    a <- async (runApp env (runWorker nid))
    atomically $ modifyTVar' reg (Map.insert nid a)
  pure $ Right $ "Discovery complete: " <> T.pack (show (Map.size (ctNodes newTopo)))
    <> " node(s) found, " <> T.pack (show (Set.size newNodes)) <> " new"

die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitFailure
