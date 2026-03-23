module PureMyHA.Env
  ( ClusterEnv (..)
  , App
  , runApp
  , getMonitoringConfig
  , getHooksConfig
  , getClusterName
  , getMonCredentials
  , getReplCredentials
  , appLogInfo
  , appLogWarn
  , appLogError
  , recordAppEvent
  ) where

import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import PureMyHA.Config
import PureMyHA.Event (EventBuffer, recordEvent)
import PureMyHA.Logger (Logger, logInfo, logWarn, logError)
import PureMyHA.Topology.State (TVarDaemonState, FailoverLock)
import PureMyHA.Types (ClusterName, Event (..), EventType)

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
  , envEventBuffer :: EventBuffer
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

appLogInfo, appLogWarn, appLogError :: (MonadReader ClusterEnv m, MonadIO m) => Text -> m ()
appLogInfo  = withLogger logInfo
appLogWarn  = withLogger logWarn
appLogError = withLogger logError

withLogger :: (MonadReader ClusterEnv m, MonadIO m) => (Logger -> Text -> IO ()) -> Text -> m ()
withLogger logFn msg = asks envLogger >>= liftIO . readTVarIO >>= \l -> liftIO (logFn l msg)

recordAppEvent :: (MonadReader ClusterEnv m, MonadIO m) => EventType -> Maybe Text -> Text -> m ()
recordAppEvent evType mNode details = do
  buf <- asks envEventBuffer
  cn  <- getClusterName
  now <- liftIO getCurrentTime
  liftIO $ recordEvent buf (Event now cn evType mNode details)
