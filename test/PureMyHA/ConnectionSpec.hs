module PureMyHA.ConnectionSpec (spec) where

import Data.IORef
import Data.Text (Text)
import PureMyHA.MySQL.Connection (retryWithBackoff)
import Test.Hspec

spec :: Spec
spec = describe "retryWithBackoff" $ do

  it "returns Right immediately on success without retrying" $ do
    callCount <- newIORef (0 :: Int)
    let action = modifyIORef callCount (+1) >> pure (Right "ok" :: Either Text String)
    result <- retryWithBackoff 3 0 0 (const $ pure ()) action
    result `shouldBe` Right "ok"
    readIORef callCount `shouldReturn` 1

  it "retries up to maxAttempts on repeated failure then returns Left" $ do
    callCount <- newIORef (0 :: Int)
    let action = modifyIORef callCount (+1) >> pure (Left "err" :: Either Text ())
    result <- retryWithBackoff 3 0 0 (const $ pure ()) action
    result `shouldBe` Left "err"
    readIORef callCount `shouldReturn` 3

  it "succeeds on second attempt" $ do
    callCount <- newIORef (0 :: Int)
    let action = do
          n <- readIORef callCount
          modifyIORef callCount (+1)
          pure $ if n == 0 then Left "transient" else Right ("ok" :: String)
    result <- retryWithBackoff 3 0 0 (const $ pure ()) action
    result `shouldBe` Right "ok"
    readIORef callCount `shouldReturn` 2

  it "with maxAttempts=1 never retries (preserves current behavior)" $ do
    callCount <- newIORef (0 :: Int)
    let action = modifyIORef callCount (+1) >> pure (Left "err" :: Either Text ())
    result <- retryWithBackoff 1 0 0 (const $ pure ()) action
    result `shouldBe` Left "err"
    readIORef callCount `shouldReturn` 1

  it "calls the debug log callback on each retry" $ do
    logs <- newIORef ([] :: [Text])
    let action = pure (Left "err" :: Either Text ())
        logFn msg = modifyIORef logs (msg :)
    _ <- retryWithBackoff 3 0 0 logFn action
    msgs <- readIORef logs
    length msgs `shouldBe` 2  -- 2 retries logged for 3 total attempts
