module PureMyHA.MySQL.Connection
  ( withNodeConn
  , makeConnectInfo
  ) where

import Control.Exception (bracket, try, SomeException)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
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
