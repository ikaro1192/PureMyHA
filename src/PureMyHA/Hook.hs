module PureMyHA.Hook
  ( runHook
  , HookEnv (..)
  ) where

import Control.Exception (try, SomeException)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.Process (createProcess, proc, waitForProcess, env)

data HookEnv = HookEnv
  { hookClusterName :: Text
  , hookNewSource   :: Maybe Text
  , hookOldSource   :: Maybe Text
  }

-- | Execute a hook script and wait for it to complete.
-- Returns Left with error message if the hook fails.
runHook :: FilePath -> HookEnv -> IO (Either Text ())
runHook scriptPath hookEnv = do
  let envVars =
        [ ("PURERMYHA_CLUSTER", T.unpack (hookClusterName hookEnv))
        ] ++
        maybe [] (\h -> [("PURERMYHA_NEW_SOURCE", T.unpack h)]) (hookNewSource hookEnv) ++
        maybe [] (\h -> [("PURERMYHA_OLD_SOURCE", T.unpack h)]) (hookOldSource hookEnv)
  result <- try @SomeException $ do
    (_, _, _, ph) <- createProcess (proc scriptPath [T.unpack (hookClusterName hookEnv)])
      { env = Just envVars }
    exitCode <- waitForProcess ph
    pure exitCode
  case result of
    Left err ->
      pure $ Left $ "Hook failed with exception: " <> T.pack (show err)
    Right ExitSuccess ->
      pure $ Right ()
    Right (ExitFailure n) ->
      pure $ Left $ "Hook exited with code " <> T.pack (show n)
