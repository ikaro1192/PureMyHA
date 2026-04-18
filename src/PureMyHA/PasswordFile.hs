{-# LANGUAGE StrictData #-}
module PureMyHA.PasswordFile
  ( PasswordFileRejection (..)
  , PasswordFileStat (..)
  , validatePasswordFile
  , validatePasswordFileIO
  , loadPassword
  , rejectionMessage
  ) where

import Control.Exception (SomeException, try)
import Data.Bits ((.&.))
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.Posix.Files as PF
import System.Posix.Types (FileMode, UserID)
import qualified System.Posix.User as PU

-- | Why a password file was refused during startup validation.
--
-- A password file holds MySQL credentials that a daemon must be able to read;
-- leaving it world- or group-accessible leaks those credentials to every local
-- user. These checks mirror the stance already enforced for hook scripts in
-- "PureMyHA.Hook", but with a stricter mode policy (only the owner may read).
data PasswordFileRejection
  = NotRegularFile          -- ^ Symlink, directory, device, etc.
  | UntrustedOwner          -- ^ Owner is neither root (UID 0) nor the daemon's UID.
  | GroupOrOtherAccessible  -- ^ Any bit in @mode & 0o077@ is set.
  deriving (Eq, Show)

-- | Subset of stat(2) required to decide whether a password file is safe to
-- read. Extracted so 'validatePasswordFile' stays pure and easy to unit-test.
data PasswordFileStat = PasswordFileStat
  { pfsIsRegularFile :: Bool
  , pfsOwner         :: UserID
  , pfsMode          :: FileMode
  } deriving (Eq, Show)

-- | Pure validator. Rejects the file unless:
--
--   * it is a regular file (symlinks/dirs/special files are refused),
--   * its owner is root (UID 0) or the supplied daemon UID,
--   * @mode & 0o077@ is zero (no group- or other-permission bit is set).
--
-- The first clause to fire wins, so tests can rely on a stable ordering.
validatePasswordFile
  :: FilePath              -- ^ path as configured (unused for decisions; kept for symmetry with Hook)
  -> PasswordFileStat      -- ^ stat info for the path
  -> UserID                -- ^ daemon's real UID
  -> Either PasswordFileRejection ()
validatePasswordFile _path stat daemonUid
  | not (pfsIsRegularFile stat)                          = Left NotRegularFile
  | pfsOwner stat /= 0 && pfsOwner stat /= daemonUid     = Left UntrustedOwner
  | pfsMode stat .&. 0o077 /= 0                          = Left GroupOrOtherAccessible
  | otherwise                                            = Right ()

-- | Render a rejection as an operator-facing message that names the offending
-- path. Used both by the IO wrappers and by the daemon when aborting startup.
rejectionMessage :: FilePath -> PasswordFileRejection -> Text
rejectionMessage path r = case r of
  NotRegularFile ->
    "Password file is not a regular file (symlink/dir rejected): " <> T.pack path
  UntrustedOwner ->
    "Password file owner is neither root nor the daemon user: " <> T.pack path
  GroupOrOtherAccessible ->
    "Password file is accessible to group or other (require mode 0600 or 0400): " <> T.pack path

-- | IO wrapper around 'validatePasswordFile': stats the path without following
-- symlinks, looks up the daemon's real UID, then delegates to the pure
-- validator. Returns 'Left' with a human-readable message on any failure —
-- including stat failures such as ENOENT.
validatePasswordFileIO :: FilePath -> IO (Either Text ())
validatePasswordFileIO path = do
  eStat <- try @SomeException (PF.getSymbolicLinkStatus path)
  case eStat of
    Left err -> pure $ Left $
      "Password file stat failed for " <> T.pack path <> ": " <> T.pack (show err)
    Right fs -> do
      daemonUid <- PU.getRealUserID
      let stat = PasswordFileStat
            { pfsIsRegularFile = PF.isRegularFile fs
            , pfsOwner         = PF.fileOwner fs
            , pfsMode          = PF.fileMode fs
            }
      pure $ case validatePasswordFile path stat daemonUid of
        Right ()  -> Right ()
        Left rej  -> Left (rejectionMessage path rej)

-- | Validate the path, then read the password. The returned text is stripped
-- of surrounding whitespace (matching the prior daemon behaviour). Any error —
-- validation or I/O — becomes 'Left' with an operator-facing message.
loadPassword :: FilePath -> IO (Either Text Text)
loadPassword path = do
  valid <- validatePasswordFileIO path
  case valid of
    Left err -> pure (Left err)
    Right () -> do
      result <- try @SomeException (readFile path)
      pure $ case result of
        Left err  -> Left $ "Failed to read password file " <> T.pack path
                          <> ": " <> T.pack (show err)
        Right raw -> Right (T.strip (T.pack raw))
