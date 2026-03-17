module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import PureMyHA.IPC.Client
import PureMyHA.IPC.Protocol
import PureMyHA.IPC.Server (defaultSocketPath)

data CLIOptions = CLIOptions
  { optSocketPath  :: FilePath
  , optCluster     :: Maybe Text
  , optJsonOutput  :: Bool
  , optCommand     :: Command
  }

data Command
  = CmdStatus
  | CmdTopology
  | CmdSwitchover { cmdToHost :: Maybe Text }
  | CmdAckRecovery
  | CmdErrantGtid
  | CmdFixErrantGtid

cliOptions :: Parser CLIOptions
cliOptions = CLIOptions
  <$> strOption
        ( long "socket"
        <> metavar "PATH"
        <> value defaultSocketPath
        <> help "Daemon socket path" )
  <*> optional (strOption
        ( long "cluster"
        <> short 'C'
        <> metavar "NAME"
        <> help "Cluster name" ))
  <*> switch
        ( long "json"
        <> short 'j'
        <> help "Output in JSON format" )
  <*> subparser
        ( command "status"
            (info (pure CmdStatus) (progDesc "Show cluster status"))
        <> command "topology"
            (info (pure CmdTopology) (progDesc "Show replication topology"))
        <> command "switchover"
            (info switchoverCmd (progDesc "Execute manual switchover"))
        <> command "ack-recovery"
            (info (pure CmdAckRecovery) (progDesc "Clear anti-flap recovery block"))
        <> command "errant-gtid"
            (info (pure CmdErrantGtid) (progDesc "Show errant GTIDs"))
        <> command "fix-errant-gtid"
            (info (pure CmdFixErrantGtid) (progDesc "Fix errant GTIDs with empty transactions"))
        )

switchoverCmd :: Parser Command
switchoverCmd = CmdSwitchover
  <$> optional (strOption
        ( long "to"
        <> metavar "HOST"
        <> help "Target host to promote" ))

main :: IO ()
main = do
  opts <- execParser (info (cliOptions <**> helper)
    (fullDesc <> progDesc "PureMyHA CLI" <> header "purermyha"))

  let socketPath = optSocketPath opts
      mCluster   = optCluster opts
      json       = optJsonOutput opts
      req = case optCommand opts of
        CmdStatus           -> ReqStatus mCluster
        CmdTopology         -> ReqTopology mCluster
        CmdSwitchover mTo   -> ReqSwitchover mCluster mTo
        CmdAckRecovery      -> ReqAckRecovery mCluster
        CmdErrantGtid       -> ReqErrantGtid mCluster
        CmdFixErrantGtid    -> ReqFixErrantGtid mCluster

  eResp <- sendRequest socketPath req
  case eResp of
    Left err -> do
      hPutStrLn stderr $ "Error: " <> T.unpack err
      exitFailure
    Right resp -> case resp of
      RespStatus statuses      -> printStatus json statuses
      RespTopology views       -> printTopology json views
      RespOperation result     -> printOperationResult json result
      RespErrantGtids gtids    -> printErrantGtids json gtids
      RespError msg            -> do
        hPutStrLn stderr $ "Daemon error: " <> T.unpack msg
        exitFailure
