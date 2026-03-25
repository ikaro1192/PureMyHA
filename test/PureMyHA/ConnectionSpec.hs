module PureMyHA.ConnectionSpec (spec) where

import Data.IORef
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Database.MySQL.Base (ConnectInfo (..))
import PureMyHA.Config (DbCredentials (..))
import PureMyHA.MySQL.Connection (retryWithBackoff, makeConnectInfo)
import PureMyHA.Types (NodeId (..))
import Test.Hspec

spec :: Spec
spec = do

  describe "makeConnectInfo" $ do
    let nid  = NodeId "db1.example.com" 3307
        cred = DbCredentials "admin" "secret"
        ci   = makeConnectInfo nid cred

    it "sets ciHost from nodeHost" $
      ciHost ci `shouldBe` "db1.example.com"

    it "sets ciPort from nodePort via fromIntegral" $
      ciPort ci `shouldBe` 3307

    it "sets ciUser and ciPassword from DbCredentials" $ do
      ciUser ci `shouldBe` TE.encodeUtf8 "admin"
      ciPassword ci `shouldBe` TE.encodeUtf8 "secret"

  describe "retryWithBackoff" $ do

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
