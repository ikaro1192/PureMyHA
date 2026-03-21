module PureMyHA.Env
  ( ClusterEnv (..)
  , App
  , runApp
  , getMonitoringConfig
  , getHooksConfig
  , getClusterName
  , getMySQLUser
  , getMonPassword
  , appLogInfo
  , appLogWarn
  , appLogError
  ) where

import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import PureMyHA.Config
import PureMyHA.Logger (Logger, logInfo, logWarn, logError)
import PureMyHA.Topology.State (TVarDaemonState, FailoverLock)
import PureMyHA.Types (ClusterName)

data ClusterEnv = ClusterEnv
  { envDaemonState :: TVarDaemonState
  , envCluster     :: ClusterConfig
  , envFailover    :: FailoverConfig
  , envDetection   :: FailureDetectionConfig
  , envPasswords   :: ClusterPasswords
  , envMonitoring  :: TVar MonitoringConfig
  , envHooks       :: TVar (Maybe HooksConfig)
  , envLock        :: FailoverLock
  , envLogger      :: Logger
  }

type App a = ReaderT ClusterEnv IO a

runApp :: ClusterEnv -> App a -> IO a
runApp = flip runReaderT

-- Helpers
getMonitoringConfig :: (MonadReader ClusterEnv m, MonadIO m) => m MonitoringConfig
getMonitoringConfig = asks envMonitoring >>= liftIO . readTVarIO

getHooksConfig :: (MonadReader ClusterEnv m, MonadIO m) => m (Maybe HooksConfig)
getHooksConfig = asks envHooks >>= liftIO . readTVarIO

getClusterName :: MonadReader ClusterEnv m => m ClusterName
getClusterName = asks (ccName . envCluster)

getMySQLUser :: MonadReader ClusterEnv m => m Text
getMySQLUser = asks (credUser . ccCredentials . envCluster)

getMonPassword :: MonadReader ClusterEnv m => m Text
getMonPassword = asks (cpPassword . envPasswords)

appLogInfo, appLogWarn, appLogError :: (MonadReader ClusterEnv m, MonadIO m) => Text -> m ()
appLogInfo  msg = asks envLogger >>= \l -> liftIO (logInfo l msg)
appLogWarn  msg = asks envLogger >>= \l -> liftIO (logWarn l msg)
appLogError msg = asks envLogger >>= \l -> liftIO (logError l msg)
