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
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Control.Monad.IO.Class (liftIO)
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
getMonitoringConfig :: App MonitoringConfig
getMonitoringConfig = asks envMonitoring >>= liftIO . readTVarIO

getHooksConfig :: App (Maybe HooksConfig)
getHooksConfig = asks envHooks >>= liftIO . readTVarIO

getClusterName :: App ClusterName
getClusterName = asks (ccName . envCluster)

getMySQLUser :: App Text
getMySQLUser = asks (credUser . ccCredentials . envCluster)

getMonPassword :: App Text
getMonPassword = asks (cpPassword . envPasswords)

appLogInfo, appLogWarn, appLogError :: Text -> App ()
appLogInfo  msg = asks envLogger >>= \l -> liftIO (logInfo l msg)
appLogWarn  msg = asks envLogger >>= \l -> liftIO (logWarn l msg)
appLogError msg = asks envLogger >>= \l -> liftIO (logError l msg)
