module PureMyHA.HookSpec (spec) where

import Data.Either (isLeft)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import System.IO (hClose, hPutStrLn)
import System.IO.Temp (withSystemTempFile)
import System.Posix.Files (setFileMode)
import Test.Hspec
import PureMyHA.Hook
  ( HookEnv (..)
  , HookRejection (..)
  , HookScriptStat (..)
  , SourceChange (..)
  , runHook
  , validateHookScript
  , validateHookScriptIO
  )
import PureMyHA.Types (ClusterName (..))

-- | Minimal HookEnv suitable for driving 'runHook' in tests.
testHookEnv :: HookEnv
testHookEnv = HookEnv
  { hookClusterName  = ClusterName "test"
  , hookSourceChange = NoSourceChange
  , hookFailureType  = Nothing
  , hookTimestamp    = T.pack "1970-01-01T00:00:00Z"
  , hookLagSeconds   = Nothing
  , hookNode         = Nothing
  , hookDriftType    = Nothing
  , hookDriftDetails = Nothing
  }

spec :: Spec
spec = do
  describe "validateHookScript" $ do
    let rootOwned644 = HookScriptStat
          { hssIsRegularFile = True
          , hssOwner         = 0
          , hssMode          = 0o644
          }

    it "accepts absolute path + regular file + root owner + 0o644" $
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" rootOwned644 1000
        `shouldBe` Right ()

    it "accepts file owned by the daemon UID" $ do
      let stat = rootOwned644 { hssOwner = 1000, hssMode = 0o700 }
      validateHookScript "/home/puremyha/hook.sh" stat 1000
        `shouldBe` Right ()

    it "rejects relative paths" $
      validateHookScript "hooks/pre_failover.sh" rootOwned644 1000
        `shouldBe` Left NotAbsolutePath

    it "rejects non-regular files (symlink / directory)" $ do
      let stat = rootOwned644 { hssIsRegularFile = False }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Left NotRegularFile

    it "rejects files owned by an untrusted user" $ do
      let stat = rootOwned644 { hssOwner = 9999 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Left UntrustedOwner

    it "rejects world-writable files (mode 0o666)" $ do
      let stat = rootOwned644 { hssMode = 0o666 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Left WorldWritable

    it "rejects world-writable files (mode 0o777)" $ do
      let stat = rootOwned644 { hssMode = 0o777 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Left WorldWritable

    it "rejects files with the lone world-write bit set (0o602)" $ do
      let stat = rootOwned644 { hssMode = 0o602 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Left WorldWritable

    it "accepts world-readable but not writable (0o755)" $ do
      let stat = rootOwned644 { hssMode = 0o755 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Right ()

    it "accepts setuid + world-readable, no world-write (0o4755)" $ do
      let stat = rootOwned644 { hssMode = 0o4755 }
      validateHookScript "/etc/puremyha/hooks/pre_failover.sh" stat 1000
        `shouldBe` Right ()

  describe "validateHookScriptIO" $ do
    it "rejects a relative path without touching the filesystem" $ do
      result <- validateHookScriptIO "hooks/pre.sh"
      result `shouldSatisfy` isLeft

    it "rejects a non-existent absolute path with a stat error" $ do
      result <- validateHookScriptIO "/nonexistent/puremyha/hook-xyz.sh"
      result `shouldSatisfy` isLeft

    it "accepts a temp file owned by the current user with mode 0o700" $ do
      withSystemTempFile "puremyha-hook-ok.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "exit 0"
        hClose h
        setFileMode path 0o700
        result <- validateHookScriptIO path
        result `shouldBe` Right ()

    it "rejects a temp file after it is chmodded world-writable" $ do
      withSystemTempFile "puremyha-hook-ww.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "exit 0"
        hClose h
        setFileMode path 0o606
        result <- validateHookScriptIO path
        result `shouldSatisfy` isLeft

  describe "runHook" $ do
    it "returns Right () for a quick-exit script" $ do
      withSystemTempFile "puremyha-hook-exit0.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "exit 0"
        hClose h
        setFileMode path 0o700
        result <- runHook 5 path testHookEnv
        result `shouldBe` Right ()

    it "propagates a non-zero exit code as Left" $ do
      withSystemTempFile "puremyha-hook-exit1.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "exit 7"
        hClose h
        setFileMode path 0o700
        result <- runHook 5 path testHookEnv
        result `shouldSatisfy` isLeft

    it "kills a long-running script after the timeout" $ do
      withSystemTempFile "puremyha-hook-sleep.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "sleep 30"
        hClose h
        setFileMode path 0o700
        start  <- getCurrentTime
        result <- runHook 1 path testHookEnv  -- 1-second timeout
        end    <- getCurrentTime
        let elapsed = realToFrac (diffUTCTime end start) :: Double
        result  `shouldSatisfy` isLeft
        elapsed `shouldSatisfy` (< 6)  -- 1s timeout + 2s grace + ample slack

    it "rejects a world-writable hook before executing it" $ do
      withSystemTempFile "puremyha-hook-ww-run.sh" $ \path h -> do
        hPutStrLn h "#!/bin/sh"
        hPutStrLn h "exit 0"
        hClose h
        setFileMode path 0o606
        result <- runHook 5 path testHookEnv
        result `shouldSatisfy` isLeft

    it "rejects a relative path without launching a process" $ do
      result <- runHook 5 "hooks/relative.sh" testHookEnv
      result `shouldSatisfy` isLeft
