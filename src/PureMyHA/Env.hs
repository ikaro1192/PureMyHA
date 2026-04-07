{-# LANGUAGE StrictData #-}
module PureMyHA.Env
  ( ClusterEnv (..)
  , App
  , runApp
  , getMonitoringConfig
  , getHooksConfig
  , getClusterName
  , getMonCredentials
  , getReplCredentials
  , getTLSConfig
  , appLogInfo
  , appLogWarn
  , appLogError
  ) where

import Control.Concurrent.STM (TBQueue, TVar, readTVarIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import PureMyHA.Config
import PureMyHA.Logger (Logger, logInfo, logWarn, logError)
import PureMyHA.Supervisor.Event (MonitorEvent)
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
  , envLogger      :: TVar Logger
  , envTLS         :: Maybe TLSConfig
  , envEventQueue  :: TBQueue MonitorEvent
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

getMonCredentials :: MonadReader ClusterEnv m => m DbCredentials
getMonCredentials = asks (cpMonCredentials . envPasswords)

getReplCredentials :: MonadReader ClusterEnv m => m DbCredentials
getReplCredentials = asks (cpReplCredentials . envPasswords)

getTLSConfig :: MonadReader ClusterEnv m => m (Maybe TLSConfig)
getTLSConfig = asks envTLS

appLogInfo, appLogWarn, appLogError :: (MonadReader ClusterEnv m, MonadIO m) => Text -> m ()
appLogInfo  = withLogger logInfo
appLogWarn  = withLogger logWarn
appLogError = withLogger logError

withLogger :: (MonadReader ClusterEnv m, MonadIO m) => (Logger -> Text -> IO ()) -> Text -> m ()
withLogger logFn msg = asks envLogger >>= liftIO . readTVarIO >>= \l -> liftIO (logFn l msg)
