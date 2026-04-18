module PureMyHA.PasswordFileSpec (spec) where

import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import System.IO (hClose, hPutStrLn)
import System.IO.Temp (withSystemTempFile)
import System.Posix.Files (setFileMode)
import Test.Hspec

import PureMyHA.PasswordFile
  ( PasswordFileRejection (..)
  , PasswordFileStat (..)
  , loadPassword
  , rejectionMessage
  , validatePasswordFile
  , validatePasswordFileIO
  )

-- | Baseline stat value representing a well-formed password file:
-- regular file, owned by root, mode 0600.
rootOwned0600 :: PasswordFileStat
rootOwned0600 = PasswordFileStat
  { pfsIsRegularFile = True
  , pfsOwner         = 0
  , pfsMode          = 0o600
  }

spec :: Spec
spec = do
  describe "validatePasswordFile" $ do
    it "accepts root-owned 0o600" $
      validatePasswordFile "/etc/puremyha/mysql.pass" rootOwned0600 1000
        `shouldBe` Right ()

    it "accepts daemon-owned 0o600" $ do
      let stat = rootOwned0600 { pfsOwner = 1000 }
      validatePasswordFile "/home/puremyha/mysql.pass" stat 1000
        `shouldBe` Right ()

    it "accepts root-owned 0o400" $ do
      let stat = rootOwned0600 { pfsMode = 0o400 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Right ()

    it "accepts daemon-owned 0o400" $ do
      let stat = rootOwned0600 { pfsOwner = 1000, pfsMode = 0o400 }
      validatePasswordFile "/home/puremyha/mysql.pass" stat 1000
        `shouldBe` Right ()

    it "rejects 0o644 (world-readable)" $ do
      let stat = rootOwned0600 { pfsMode = 0o644 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects 0o666 (world-writable)" $ do
      let stat = rootOwned0600 { pfsMode = 0o666 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects 0o640 (group-readable)" $ do
      let stat = rootOwned0600 { pfsMode = 0o640 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects 0o660 (group-writable)" $ do
      let stat = rootOwned0600 { pfsMode = 0o660 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects 0o606 (other-writable only)" $ do
      let stat = rootOwned0600 { pfsMode = 0o606 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects 0o604 (other-readable only)" $ do
      let stat = rootOwned0600 { pfsMode = 0o604 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left GroupOrOtherAccessible

    it "rejects a non-regular file (symlink/dir/device)" $ do
      let stat = rootOwned0600 { pfsIsRegularFile = False }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left NotRegularFile

    it "rejects a file owned by an untrusted user" $ do
      let stat = rootOwned0600 { pfsOwner = 9999 }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left UntrustedOwner

    it "prefers NotRegularFile over mode/owner failures" $ do
      let stat = PasswordFileStat
            { pfsIsRegularFile = False
            , pfsOwner         = 9999
            , pfsMode          = 0o777
            }
      validatePasswordFile "/etc/puremyha/mysql.pass" stat 1000
        `shouldBe` Left NotRegularFile

  describe "rejectionMessage" $ do
    it "names the offending path for each rejection" $ do
      rejectionMessage "/etc/puremyha/mysql.pass" NotRegularFile
        `shouldSatisfy` T.isInfixOf (T.pack "/etc/puremyha/mysql.pass")
      rejectionMessage "/etc/puremyha/mysql.pass" UntrustedOwner
        `shouldSatisfy` T.isInfixOf (T.pack "/etc/puremyha/mysql.pass")
      rejectionMessage "/etc/puremyha/mysql.pass" GroupOrOtherAccessible
        `shouldSatisfy` T.isInfixOf (T.pack "/etc/puremyha/mysql.pass")

  describe "validatePasswordFileIO" $ do
    it "rejects a non-existent path with a stat error" $ do
      result <- validatePasswordFileIO "/nonexistent/puremyha/mysql-xyz.pass"
      result `shouldSatisfy` isLeft

    it "accepts a temp file owned by the current user with mode 0o600" $ do
      withSystemTempFile "puremyha-pass-ok.pass" $ \path h -> do
        hPutStrLn h "hunter2"
        hClose h
        setFileMode path 0o600
        result <- validatePasswordFileIO path
        result `shouldBe` Right ()

    it "accepts mode 0o400" $ do
      withSystemTempFile "puremyha-pass-ro.pass" $ \path h -> do
        hPutStrLn h "hunter2"
        hClose h
        setFileMode path 0o400
        result <- validatePasswordFileIO path
        result `shouldBe` Right ()

    it "rejects a temp file after it is chmodded world-readable" $ do
      withSystemTempFile "puremyha-pass-644.pass" $ \path h -> do
        hPutStrLn h "hunter2"
        hClose h
        setFileMode path 0o644
        result <- validatePasswordFileIO path
        result `shouldSatisfy` isLeft

    it "rejects a temp file after it is chmodded group-readable" $ do
      withSystemTempFile "puremyha-pass-640.pass" $ \path h -> do
        hPutStrLn h "hunter2"
        hClose h
        setFileMode path 0o640
        result <- validatePasswordFileIO path
        result `shouldSatisfy` isLeft

  describe "loadPassword" $ do
    it "returns the stripped content for a well-permissioned file" $ do
      withSystemTempFile "puremyha-pass-load.pass" $ \path h -> do
        hPutStrLn h "  hunter2  "   -- trailing newline + surrounding space
        hClose h
        setFileMode path 0o600
        result <- loadPassword path
        result `shouldBe` Right (T.pack "hunter2")

    it "fails for a 0o644 file" $ do
      withSystemTempFile "puremyha-pass-reject.pass" $ \path h -> do
        hPutStrLn h "hunter2"
        hClose h
        setFileMode path 0o644
        result <- loadPassword path
        result `shouldSatisfy` isLeft

    it "fails for a missing file" $ do
      result <- loadPassword "/nonexistent/puremyha/nope.pass"
      result `shouldSatisfy` isLeft

    it "accepts a password with internal whitespace (only strips the edges)" $ do
      withSystemTempFile "puremyha-pass-inner.pass" $ \path h -> do
        hPutStrLn h "  hun ter 2  "
        hClose h
        setFileMode path 0o600
        result <- loadPassword path
        result `shouldSatisfy` isRight
        case result of
          Right pwd -> pwd `shouldBe` T.pack "hun ter 2"
          Left _    -> expectationFailure "expected Right"
