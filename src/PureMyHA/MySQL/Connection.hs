module PureMyHA.MySQL.Connection
  ( withNodeConn
  , withNodeConnRetry
  , retryWithBackoff
  , makeConnectInfo
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try, SomeException)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (NominalDiffTime)
import Database.MySQL.Base (ConnectInfo (..), defaultConnectInfo, close, MySQLConn)
import PureMyHA.MySQL.Auth (connectWithAuth)
import PureMyHA.Types (NodeId (..))

-- | Build ConnectInfo from NodeId and credentials
makeConnectInfo :: NodeId -> Text -> Text -> ConnectInfo
makeConnectInfo NodeId{..} user password = defaultConnectInfo
  { ciHost     = T.unpack nodeHost
  , ciPort     = fromIntegral nodePort
  , ciUser     = TE.encodeUtf8 user
  , ciPassword = TE.encodeUtf8 password
  , ciDatabase = ""
  }

-- | Execute an action with a MySQL connection, ensuring cleanup
withNodeConn
  :: ConnectInfo
  -> (MySQLConn -> IO a)
  -> IO (Either Text a)
withNodeConn ci action = do
  result <- try @SomeException $ bracket (connectWithAuth ci) close action
  pure $ case result of
    Left err -> Left (T.pack (show err))
    Right v  -> Right v

-- | Retry helper: runs 'action' up to 'maxAttempts' times with exponential
-- backoff. Backoff doubles each attempt, capped at 'backoffCap'.
-- maxAttempts=1 means no retry (preserves current behavior).
retryWithBackoff
  :: Int              -- ^ total attempts (1 = no retry)
  -> NominalDiffTime  -- ^ initial backoff
  -> NominalDiffTime  -- ^ backoff cap
  -> (Text -> IO ())  -- ^ debug log callback
  -> IO (Either Text a)
  -> IO (Either Text a)
retryWithBackoff maxAttempts initialBackoff backoffCap logMsg action =
  go 1 initialBackoff
  where
    go attempt backoff = do
      result <- action
      case result of
        Right v  -> pure (Right v)
        Left err
          | attempt >= maxAttempts -> pure (Left err)
          | otherwise -> do
              logMsg $ "Retry " <> T.pack (show attempt) <> "/"
                     <> T.pack (show (maxAttempts - 1)) <> " after: " <> err
              threadDelay (round (backoff * 1_000_000) :: Int)
              go (attempt + 1) (min (backoff * 2) backoffCap)

-- | withNodeConn with configurable retry and exponential backoff.
-- Retry applies only to the connection phase; backoff is capped at backoffCap.
withNodeConnRetry
  :: Int              -- ^ total attempts (1 = no retry)
  -> NominalDiffTime  -- ^ initial backoff
  -> NominalDiffTime  -- ^ backoff cap (typically connect_timeout)
  -> (Text -> IO ())  -- ^ debug log callback
  -> ConnectInfo
  -> (MySQLConn -> IO a)
  -> IO (Either Text a)
withNodeConnRetry maxAttempts initialBackoff backoffCap logMsg ci action =
  retryWithBackoff maxAttempts initialBackoff backoffCap logMsg
    (withNodeConn ci action)
