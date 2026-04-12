module PureMyHA.MySQL.Connection
  ( withNodeConn
  , withNodeConnRetry
  , retryWithBackoff
  , makeConnectInfo
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracketOnError, catch, finally, try)
import Control.Monad (void)
import qualified Data.Binary as Binary
import qualified Data.Binary.Put as Binary
import qualified Data.ByteString as B
import Data.IORef (newIORef)
import Data.Word (Word8)
import Network.Socket (PortNumber)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (NominalDiffTime)
import qualified Data.Connection as TCP
import qualified System.IO.Streams.TCP as TCP
import Database.MySQL.Base (ConnectInfo (..), defaultConnectInfo, close, MySQLConn)
import Database.MySQL.Connection (MySQLConn (..), bUFSIZE, completeAuth,
                                  decodeInputStream, mkAuth, readPacket,
                                  waitCommandReply, writeCommand)
import Database.MySQL.Protocol.Auth (Greeting (..))
import Database.MySQL.Protocol.Command (Command (COM_QUIT))
import Database.MySQL.Protocol.Packet (decodeFromPacket, encodeToPacket)
import qualified Database.MySQL.TLS as MySQLTLS
import PureMyHA.Config (DbCredentials (..), TLSConfig (..), TLSMode (..))
import PureMyHA.MySQL.Auth (rsaFullAuth)
import PureMyHA.MySQL.TLS (buildClientParams)
import PureMyHA.Types (NodeId, nodePort, unPort, IPAddr (..), nodeIPAddr)

-- | Build ConnectInfo from NodeId and credentials
makeConnectInfo :: NodeId -> DbCredentials -> ConnectInfo
makeConnectInfo nid DbCredentials{..} = defaultConnectInfo
  { ciHost     = T.unpack (unIPAddr (nodeIPAddr nid))
  , ciPort     = fromIntegral (unPort (nodePort nid))
  , ciUser     = TE.encodeUtf8 dbUser
  , ciPassword = TE.encodeUtf8 dbPassword
  , ciDatabase = ""
  }

-- | Connect to MySQL with @caching_sha2_password@ RSA full-auth support
-- for plain TCP.  TLS connections use @Database.MySQL.TLS.connect@ which
-- handles full-auth by sending the plaintext password over the encrypted
-- channel.
connectMySQL :: Maybe TLSConfig -> ConnectInfo -> IO MySQLConn
connectMySQL mTls ci@(ConnectInfo host port db user pass charset) =
  case mTls of
    Just tlsCfg | tlsMode tlsCfg /= TLSDisabled -> do
      params <- buildClientParams tlsCfg host
      MySQLTLS.connect ci (params, host)
    _ -> connectWithRSAAuth host port db user pass charset

-- | Variant of @Database.MySQL.Base.connect@ that passes our RSA
-- full-auth callback to 'completeAuth' instead of 'plainFullAuth'.
connectWithRSAAuth
  :: String -> PortNumber -> B.ByteString -> B.ByteString -> B.ByteString -> Word8
  -> IO MySQLConn
connectWithRSAAuth host port db user pass charset =
    bracketOnError open TCP.close go
  where
    open = TCP.connectSocket host port
             >>= TCP.socketToConnection bUFSIZE

    go c = do
        let is = TCP.source c
        is' <- decodeInputStream is
        p   <- readPacket is'
        greet <- decodeFromPacket p :: IO Greeting

        let nonce = greetingSalt1 greet `B.append` greetingSalt2 greet
            auth  = mkAuth db user pass charset greet
            write pkt = TCP.send c (Binary.runPut (Binary.put pkt))
        write (encodeToPacket 1 auth)

        resp <- readPacket is'
        completeAuth is' write pass resp (rsaFullAuth nonce)

        consumed <- newIORef True
        let waitNotMandatoryOK =
                catch (void (waitCommandReply is'))
                      (const (pure ()) :: SomeException -> IO ())
            conn = MySQLConn
                       is'
                       write
                       (writeCommand COM_QUIT write
                        >> waitNotMandatoryOK
                        >> TCP.close c)
                       consumed
        pure conn

-- | Execute an action with a MySQL connection, ensuring cleanup
withNodeConn
  :: Maybe TLSConfig
  -> ConnectInfo
  -> (MySQLConn -> IO a)
  -> IO (Either Text a)
withNodeConn mTls ci action = do
  result <- try @SomeException $ do
    conn <- connectMySQL mTls ci
    action conn `finally` void (try @SomeException (close conn))
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
  -> Maybe TLSConfig
  -> ConnectInfo
  -> (MySQLConn -> IO a)
  -> IO (Either Text a)
withNodeConnRetry maxAttempts initialBackoff backoffCap logMsg mTls ci action =
  retryWithBackoff maxAttempts initialBackoff backoffCap logMsg
    (withNodeConn mTls ci action)
