-- | RSA full-authentication callback for @caching_sha2_password@ over
-- non-TLS connections.
--
-- mysql-haskell 1.2.0 supports @caching_sha2_password@ but its built-in
-- 'plainFullAuth' rejects non-TLS full authentication.  This module provides
-- 'rsaFullAuth', which requests the server's RSA public key, encrypts the
-- password with RSA-OAEP, and completes the handshake — the same protocol
-- that @libmysqlclient@ uses when @--get-server-public-key@ is set.
module PureMyHA.MySQL.Auth (rsaFullAuth) where

import           Control.Exception               (throwIO)
import           Data.Bits                       (xor)
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as BL
import qualified Crypto.PubKey.RSA               as RSA
import qualified Crypto.PubKey.RSA.OAEP          as OAEP
import           Crypto.Hash.Algorithms          (SHA1 (..))
import qualified Crypto.Number.Serialize         as Serialize
import qualified Data.ASN1.Encoding              as ASN1E
import qualified Data.ASN1.BinaryEncoding        as ASN1B
import qualified Data.ASN1.Types                 as ASN1
import qualified Data.ASN1.BitArray              as ASN1BA
import qualified Data.PEM                        as PEM
import           Data.Int                        (Int64)
import           Data.Word                       (Word8)
import           Database.MySQL.Connection       (ERRException (..), readPacket)
import           Database.MySQL.Protocol.Packet  (Packet (..), decodeFromPacket,
                                                  isOK)
import           System.IO.Streams               (InputStream)

-- | Full-authentication callback for @caching_sha2_password@ over a plain
-- TCP connection.  Closes over the server nonce so it can XOR the password
-- before RSA encryption.
--
-- Intended to be passed to 'Database.MySQL.Connection.completeAuth'.
rsaFullAuth
    :: ByteString   -- ^ full nonce (salt1 ++ salt2) from Greeting
    -> Word8        -- ^ sequence number
    -> ByteString   -- ^ plaintext password
    -> (Packet -> IO ())      -- ^ packet writer
    -> InputStream Packet     -- ^ packet input stream
    -> IO ()
rsaFullAuth nonce seqN pass writePacket is = do
    -- Request the server's RSA public key (0x02).
    let reqBody = BL.singleton 0x02
        reqPkt  = Packet 1 seqN reqBody
    writePacket reqPkt
    -- Read the key packet (body: 0x01 <PEM bytes>).
    keyPkt <- readPacket is
    pemKey <- case BL.uncons (pBody keyPkt) of
        Just (_, body) -> pure (BL.toStrict body)
        Nothing -> throwIO
            (userError "malformed auth packet: empty RSA key body")
    -- Encrypt and send.
    doRSAAuth writePacket (pSeqN keyPkt + 1) pass nonce pemKey
    -- Read the final OK / ERR.
    q <- readPacket is
    if isOK q
        then pure ()
        else decodeFromPacket q >>= throwIO . ERRException

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- | XOR @(password ++ NUL)@ with a cyclically-extended nonce.
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
    pubKey <- either (\e -> throwIO (userError ("RSA key parse: " ++ e))) pure
                     (parseRSAPublicKey pemKey)
    result <- OAEP.encrypt (OAEP.defaultOAEPParams SHA1) pubKey
                           (xorPasswordNonce pass nonce)
    ct <- either (\e -> throwIO (userError ("RSA encrypt: " ++ show e))) pure result
    let body = BL.fromStrict ct
        pkt  = Packet (fromIntegral (B.length ct) :: Int64) seqN body
    writePacket pkt

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

    spkiBitString = extractSpki

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
