-- | TLS support for MySQL connections.
--
-- Builds TLS client parameters from 'TLSConfig' and performs the TLS upgrade
-- over an existing raw socket (MySQL STARTTLS-like protocol).
module PureMyHA.MySQL.TLS
  ( buildClientParams
  ) where

import           Control.Exception               (throwIO)
import qualified Data.ByteString                 as B
import           Data.X509                       (HashALG (..))
import qualified Data.X509.CertificateStore      as X509Store
import qualified Data.X509.Validation            as XV
import qualified Network.TLS                     as TLS
import qualified Network.TLS.Extra.Cipher        as TLS
import           PureMyHA.Config                 (TLSConfig (..), TLSMode (..), TLSMinVersion (..))

-- | Build 'TLS.ClientParams' from a 'TLSConfig' and the server hostname.
-- The hostname is used for SNI and certificate hostname verification.
buildClientParams :: TLSConfig -> String -> IO TLS.ClientParams
buildClientParams cfg hostname = do
  store <- buildCertStore cfg
  creds <- buildCredentials cfg
  let base   = TLS.defaultParamsClient hostname B.empty
      shared = (TLS.clientShared base)
        { TLS.sharedCAStore      = store
        , TLS.sharedCredentials  = creds
        }
      hooks    = buildHooks (tlsMode cfg)
      versions = case tlsMinVersion cfg of
        Just TLSVersion13 -> [TLS.TLS13]
        _                 -> [TLS.TLS13, TLS.TLS12]
      supp   = (TLS.clientSupported base)
        { TLS.supportedCiphers   = TLS.ciphersuite_default
        , TLS.supportedVersions  = versions
        }
  return base
    { TLS.clientShared    = shared
    , TLS.clientHooks     = hooks
    , TLS.clientSupported = supp
    }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

buildCertStore :: TLSConfig -> IO X509Store.CertificateStore
buildCertStore cfg = case tlsMode cfg of
  TLSDisabled   -> return mempty
  TLSSkipVerify -> return mempty
  TLSVerifyCA   -> loadFileStore (tlsCACert cfg)
  TLSVerifyFull -> loadFileStore (tlsCACert cfg)

loadFileStore :: Maybe FilePath -> IO X509Store.CertificateStore
loadFileStore Nothing     = return mempty
loadFileStore (Just path) = do
  mStore <- X509Store.readCertificateStore path
  case mStore of
    Nothing    -> throwIO (userError ("Failed to load CA certificate: " ++ path))
    Just store -> return store

buildCredentials :: TLSConfig -> IO TLS.Credentials
buildCredentials cfg =
  case (tlsClientCert cfg, tlsClientKey cfg) of
    (Just certFile, Just keyFile) -> do
      result <- TLS.credentialLoadX509 certFile keyFile
      case result of
        Left err   -> throwIO (userError ("Failed to load client certificate: " ++ err))
        Right cred -> return (TLS.Credentials [cred])
    _ -> return mempty

buildHooks :: TLSMode -> TLS.ClientHooks
buildHooks TLSSkipVerify =
  TLS.defaultClientHooks
    { TLS.onServerCertificate = \_ _ _ _ -> return [] }
buildHooks TLSVerifyCA =
  TLS.defaultClientHooks
    { TLS.onServerCertificate = verifyCAOnly }
buildHooks _ = TLS.defaultClientHooks

-- | Validate the certificate chain against the CA store, but skip hostname check.
verifyCAOnly
  :: X509Store.CertificateStore
  -> TLS.ValidationCache
  -> XV.ServiceID
  -> TLS.CertificateChain
  -> IO [XV.FailedReason]
verifyCAOnly store cache serviceID chain =
  XV.validate HashSHA256 XV.defaultHooks
    (XV.defaultChecks { XV.checkFQHN = False })
    store cache serviceID chain
