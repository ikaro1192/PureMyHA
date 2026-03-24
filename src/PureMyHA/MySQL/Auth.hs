-- | Custom MySQL connection with @caching_sha2_password@ support
-- (MySQL 8.4 default).
module PureMyHA.MySQL.Auth (connectWithAuth) where

import           Control.Exception               (SomeException, bracketOnError, catch,
                                                  throwIO)
import           Control.Monad                   (replicateM_, void)
import           Data.Bits
import qualified Data.Binary                     as Binary
import qualified Data.Binary.Put                 as Binary
import qualified Data.ByteArray                  as BA
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as BL
import qualified Crypto.Hash                     as Crypto
import qualified Crypto.PubKey.RSA               as RSA
import qualified Crypto.PubKey.RSA.OAEP          as OAEP
import           Crypto.Hash.Algorithms          (SHA1 (..))
import qualified Crypto.Number.Serialize         as Serialize
import           Data.IORef                      (newIORef)
import           Data.Word
import qualified Data.ASN1.Encoding              as ASN1E
import qualified Data.ASN1.BinaryEncoding        as ASN1B
import qualified Data.ASN1.Types                 as ASN1
import qualified Data.ASN1.BitArray              as ASN1BA
import qualified Data.PEM                        as PEM
import           Database.MySQL.Connection       (MySQLConn (..), ConnectInfo (..),
                                                  NetworkException (..),
                                                  ERRException (..), UnexpectedPacket (..),
                                                  bUFSIZE, decodeInputStream, readPacket,
                                                  waitCommandReply, writeCommand)
import           Database.MySQL.Protocol.Auth    (Greeting (..),
                                                  clientCap, clientMaxPacketSize)
import           Database.MySQL.Protocol.Command (Command (COM_QUIT))
import           Database.MySQL.Protocol.Packet  (Packet (..), decodeFromPacket,
                                                  isOK, putToPacket)
import           System.IO.Streams               (InputStream)
import qualified Data.Connection                 as TCP
import qualified System.IO.Streams.TCP           as TCP
import           PureMyHA.Config                 (TLSConfig (..), TLSMode (..))
import           PureMyHA.MySQL.TLS              (buildClientParams, upgradeTLS)

-- | CLIENT_PLUGIN_AUTH capability flag (not included in mysql-haskell's clientCap).
clientPluginAuth :: Word32
clientPluginAuth = 0x00080000

-- | CLIENT_SSL capability flag — requests TLS upgrade before authentication.
clientSSL :: Word32
clientSSL = 0x00000800

-- | Serialise an SSL_REQUEST packet (32-byte prefix of HandshakeResponse41, no credentials).
putSSLRequest :: Word32 -> Word32 -> Word8 -> Binary.Put
putSSLRequest caps maxPkt charset = do
    Binary.putWord32le caps
    Binary.putWord32le maxPkt
    Binary.putWord8 charset
    replicateM_ 23 (Binary.putWord8 0x00)

-- | SHA-256 scramble for the @caching_sha2_password@ fast-auth path.
--
-- @token = SHA256(password) XOR SHA256(SHA256(SHA256(password)) ++ nonce)@
scrambleSHA256 :: ByteString -> ByteString -> ByteString
scrambleSHA256 pass nonce
    | B.null pass = B.empty
    | otherwise   = B.pack (B.zipWith xor a c)
  where
    sha256 :: ByteString -> ByteString
    sha256 = BA.convert . (Crypto.hash :: ByteString -> Crypto.Digest Crypto.SHA256)
    a = sha256 pass                         -- SHA256(password)
    c = sha256 (sha256 a `B.append` nonce)  -- SHA256(SHA256(SHA256(pass)) ++ nonce)

-- | Serialise a HandshakeResponse41, appending the plugin name when
-- @CLIENT_PLUGIN_AUTH@ is set.
putAuthPacket
    :: Word32           -- ^ capability flags
    -> Word32           -- ^ max packet size
    -> Word8            -- ^ charset
    -> ByteString       -- ^ username
    -> ByteString       -- ^ scrambled password (auth response)
    -> ByteString       -- ^ default database
    -> Maybe ByteString -- ^ auth plugin name (Nothing = omit)
    -> Binary.Put
putAuthPacket cap maxPkt charset user authResp db mPlugin = do
    Binary.putWord32le cap
    Binary.putWord32le maxPkt
    Binary.putWord8 charset
    replicateM_ 23 (Binary.putWord8 0x00)
    Binary.putByteString user >> Binary.putWord8 0x00
    Binary.putWord8 $ fromIntegral (B.length authResp)
    Binary.putByteString authResp
    Binary.putByteString db >> Binary.putWord8 0x00
    case mPlugin of
        Nothing   -> return ()
        Just name -> Binary.putByteString name >> Binary.putWord8 0x00

-- | Parse a PEM-encoded SubjectPublicKeyInfo RSA public key (PKCS#8 / RFC 5480).
parseRSAPublicKey :: ByteString -> Either String RSA.PublicKey
parseRSAPublicKey pemBytes =
    either (Left . show) Right (PEM.pemParseBS pemBytes)
    >>= firstPEM
    >>= decodeDER
    >>= spkiBitString
    >>= decodeDER
    >>= rsaKey
  where
    firstPEM []    = Left "empty PEM"
    firstPEM (x:_) = Right (PEM.pemContent x)

    decodeDER bs = either (Left . show) Right (ASN1E.decodeASN1' ASN1B.DER bs)

    -- Extract DER-encoded RSAPublicKey from a SubjectPublicKeyInfo structure.
    spkiBitString asn1 = extractSpki asn1

    extractSpki (ASN1.Start ASN1.Sequence
                 : ASN1.Start ASN1.Sequence
                 : ASN1.OID _
                 : ASN1.Null
                 : ASN1.End ASN1.Sequence
                 : ASN1.BitString bs
                 : ASN1.End ASN1.Sequence
                 : [])
        = Right (ASN1BA.bitArrayGetData bs)
    extractSpki xs = Left ("unexpected SPKI ASN1: " ++ show xs)

    -- Build RSA.PublicKey from parsed RSAPublicKey ASN1.
    rsaKey (ASN1.Start ASN1.Sequence
            : ASN1.IntVal n
            : ASN1.IntVal e
            : ASN1.End ASN1.Sequence
            : [])
        = Right RSA.PublicKey
            { RSA.public_size = B.length (Serialize.i2osp n :: ByteString)
            , RSA.public_n    = n
            , RSA.public_e    = e
            }
    rsaKey xs = Left ("unexpected RSA key ASN1: " ++ show xs)

-- | XOR @(password ++ NUL)@ with a cyclically-extended nonce, as required
-- by the @caching_sha2_password@ RSA encryption step.
xorPasswordNonce :: ByteString -> ByteString -> ByteString
xorPasswordNonce pass nonce =
    let msg      = pass `B.snoc` 0x00
        nonceLen = B.length nonce
        cycled   = B.pack [nonce `B.index` (i `mod` nonceLen) | i <- [0 .. B.length msg - 1]]
    in B.pack (B.zipWith xor msg cycled)

-- | Encrypt password with the server's RSA public key and send it.
doRSAAuth
    :: (Packet -> IO ())  -- ^ packet writer
    -> Word8              -- ^ sequence number
    -> ByteString         -- ^ password
    -> ByteString         -- ^ nonce (full salt)
    -> ByteString         -- ^ PEM-encoded RSA public key from server
    -> IO ()
doRSAAuth writePacket seqN pass nonce pemKey = do
    pubKey <- either (\e -> throwIO (userError ("RSA key parse: " ++ e))) return
                     (parseRSAPublicKey pemKey)
    result <- OAEP.encrypt (OAEP.defaultOAEPParams SHA1) pubKey
                           (xorPasswordNonce pass nonce)
    ct <- either (\e -> throwIO (userError ("RSA encrypt: " ++ show e))) return result
    writePacket (putToPacket seqN (Binary.putByteString ct))

-- | Handle server packets in the auth exchange after the initial
-- HandshakeResponse.
--
-- Handles:
--   @0x00@ OK                 → success
--   @0xFF@ ERR                → 'ERRException'
--   @0xFE@ AUTH_SWITCH_REQUEST → re-scramble with new plugin/nonce
--   @0x01 0x03@ AUTH_MORE_DATA → fast-auth OK, wait for OK
--   @0x01 0x04@ AUTH_MORE_DATA → full-auth, do RSA round-trip
handleAuthResponse
    :: InputStream Packet
    -> (Packet -> IO ())
    -> ByteString          -- ^ full nonce (salt1 ++ salt2)
    -> ByteString          -- ^ plaintext password
    -> IO ()
handleAuthResponse is writePacket nonce pass = loop
  where
    loop = do
        p <- readPacket is
        case BL.uncons (pBody p) of
            Nothing -> throwIO NetworkException
            Just (tag, rest)
                | tag == 0x00 -> return ()
                | tag == 0xFF -> decodeFromPacket p >>= throwIO . ERRException
                | tag == 0xFE -> handleSwitch p
                | tag == 0x01 -> handleMoreData rest (pSeqN p)
                | otherwise   -> throwIO (UnexpectedPacket p)

    handleMoreData rest serverSeqN =
        case BL.uncons rest of
            Nothing -> throwIO NetworkException
            Just (status, _)
                | status == 0x03 -> do
                    -- Fast-auth succeeded; server will send an OK packet next.
                    p' <- readPacket is
                    if isOK p'
                        then return ()
                        else decodeFromPacket p' >>= throwIO . ERRException
                | status == 0x04 -> do
                    -- Full-auth required; request server's RSA public key.
                    writePacket (putToPacket (serverSeqN + 1) (Binary.putWord8 0x02))
                    keyPkt <- readPacket is
                    -- Key packet body: 0x01 <PEM bytes>
                    let pemKey = BL.toStrict (BL.tail (pBody keyPkt))
                    doRSAAuth writePacket (pSeqN keyPkt + 1) pass nonce pemKey
                    p' <- readPacket is
                    if isOK p'
                        then return ()
                        else decodeFromPacket p' >>= throwIO . ERRException
                | otherwise -> throwIO NetworkException

    handleSwitch p = do
        -- AUTH_SWITCH_REQUEST body: 0xFE <plugin\0> <new_nonce>
        let bs           = BL.toStrict (BL.tail (pBody p))
            (pluginName, afterNul) = B.break (== 0x00) bs
            newNonce     = B.drop 1 afterNul
        if pluginName == "caching_sha2_password"
            then do
                let response = scrambleSHA256 pass newNonce
                writePacket (putToPacket (pSeqN p + 1) (Binary.putByteString response))
                loop
            else throwIO (userError ("unsupported auth plugin: "
                                     ++ show pluginName))

-- | Drop-in replacement for 'Database.MySQL.Base.connect' with
-- @caching_sha2_password@ (MySQL 8.4 default) support and optional TLS.
--
-- When 'TLSConfig' is provided (and mode is not 'TLSDisabled'), the function
-- performs the MySQL STARTTLS-like protocol: it sends an SSL_REQUEST packet
-- before the normal auth handshake, performs the TLS handshake over the raw
-- socket, then continues with @caching_sha2_password@ / @mysql_native_password@
-- authentication over the encrypted channel.
connectWithAuth :: Maybe TLSConfig -> ConnectInfo -> IO MySQLConn
connectWithAuth mTls (ConnectInfo host port db user pass charset) =
    bracketOnError open TCP.close go
  where
    open = TCP.connectSocket host port >>= TCP.socketToConnection bUFSIZE

    go c = do
        let is = TCP.source c
        is' <- decodeInputStream is
        p   <- readPacket is'
        greet <- decodeFromPacket p :: IO Greeting

        let plugin   = greetingAuthPlugin greet
            nonce    = greetingSalt1 greet `B.append` greetingSalt2 greet
            authResp = scrambleSHA256 pass nonce
            baseCaps = clientCap .|. clientPluginAuth

        -- Perform TLS upgrade if configured and not disabled
        (writeP, readIS, authSeqN, authCaps) <- case mTls of
          Just tlsCfg | tlsMode tlsCfg /= TLSDisabled -> do
            let sslCaps = baseCaps .|. clientSSL
                sslPkt  = putToPacket 1
                            (putSSLRequest sslCaps clientMaxPacketSize charset)
            TCP.send c (Binary.runPut (Binary.put sslPkt))
            params <- buildClientParams tlsCfg host
            let (sock, _) = TCP.connExtraInfo c
            (tlsIs, tlsSend) <- upgradeTLS params sock
            tlsIS' <- decodeInputStream tlsIs
            let writePacket pkt = tlsSend (Binary.runPut (Binary.put pkt))
            return (writePacket, tlsIS', 2 :: Word8, sslCaps)
          _ -> do
            let writePacket pkt = TCP.send c (Binary.runPut (Binary.put pkt))
            return (writePacket, is', 1 :: Word8, baseCaps)

        let authPkt = putToPacket authSeqN
                        (putAuthPacket authCaps clientMaxPacketSize charset
                                       user authResp db (Just plugin))
        writeP authPkt
        handleAuthResponse readIS writeP nonce pass

        consumed <- newIORef True
        let waitNotMandatoryOK =
                catch (void (waitCommandReply readIS))
                      ((\_ -> return ()) :: SomeException -> IO ())
            conn = MySQLConn
                       readIS
                       writeP
                       (writeCommand COM_QUIT writeP
                        >> waitNotMandatoryOK
                        >> TCP.close c)
                       consumed
        return conn
