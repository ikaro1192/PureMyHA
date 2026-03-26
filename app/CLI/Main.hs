module Main (main) where

import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import PureMyHA.Config (loadConfig, validateConfig)
import PureMyHA.IPC.Client
import PureMyHA.IPC.Protocol
import PureMyHA.IPC.Server (defaultSocketPath)
import PureMyHA.Types (ClusterName (..))

data CLIOptions = CLIOptions
  { optSocketPath  :: FilePath
  , optCluster     :: Maybe Text
  , optJsonOutput  :: Bool
  , optCommand     :: Command
  }

data Command
  = CmdStatus
  | CmdTopology
  | CmdSwitchover (Maybe Text) Bool (Maybe Int)
  | CmdAckRecovery
  | CmdErrantGtid
  | CmdFixErrantGtid
  | CmdDemote Text Text   -- host, source
  | CmdDiscovery
  | CmdPauseReplica  Text
  | CmdResumeReplica Text
  | CmdPauseFailover
  | CmdResumeFailover
  | CmdSetLogLevel Text
  | CmdValidateConfig FilePath
  | CmdUnfence Text
  | CmdClone Text (Maybe Text)   -- recipient, donor?

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
        <> command "demote"
            (info demoteCmd (progDesc "Demote a node to replica under specified source"))
        <> command "discovery"
            (info (pure CmdDiscovery) (progDesc "Trigger manual topology discovery"))
        <> command "pause-replica"
            (info pauseReplicaCmd (progDesc "Pause replication on a node for maintenance"))
        <> command "resume-replica"
            (info resumeReplicaCmd (progDesc "Resume replication on a paused node"))
        <> command "pause-failover"
            (info (pure CmdPauseFailover) (progDesc "Pause automatic failover for maintenance"))
        <> command "resume-failover"
            (info (pure CmdResumeFailover) (progDesc "Resume automatic failover"))
        <> command "set-log-level"
            (info setLogLevelCmd (progDesc "Set daemon log level (debug|info|warn|error)"))
        <> command "validate-config"
            (info validateConfigCmd (progDesc "Validate configuration file without connecting to daemon"))
        <> command "unfence"
            (info unfenceCmd (progDesc "Clear super_read_only on a fenced node (verify data consistency first)"))
        <> command "clone"
            (info cloneCmd (progDesc "Re-seed a replica using MySQL CLONE plugin"))
        )

demoteCmd :: Parser Command
demoteCmd = CmdDemote
  <$> strOption (long "host"   <> metavar "HOST" <> help "Node to demote")
  <*> strOption (long "source" <> metavar "HOST" <> help "New replication source host")

pauseReplicaCmd :: Parser Command
pauseReplicaCmd = CmdPauseReplica <$> strOption (long "host" <> metavar "HOST" <> help "Node to pause")

resumeReplicaCmd :: Parser Command
resumeReplicaCmd = CmdResumeReplica <$> strOption (long "host" <> metavar "HOST" <> help "Node to resume")

setLogLevelCmd :: Parser Command
setLogLevelCmd = CmdSetLogLevel
  <$> argument str (metavar "LEVEL" <> help "Log level: debug, info, warn, error")

unfenceCmd :: Parser Command
unfenceCmd = CmdUnfence
  <$> strOption (long "host" <> metavar "HOST" <> help "Host to unfence (clears super_read_only)")

cloneCmd :: Parser Command
cloneCmd = CmdClone
  <$> strOption (long "recipient" <> metavar "HOST[:PORT]"
        <> help "Replica node to re-seed")
  <*> optional (strOption (long "donor" <> metavar "HOST[:PORT]"
        <> help "Donor node (default: replica with most advanced GTID)"))

validateConfigCmd :: Parser Command
validateConfigCmd = CmdValidateConfig
  <$> strOption
        ( long "config"
        <> short 'c'
        <> metavar "FILE"
        <> value "/etc/puremyha/config.yaml"
        <> help "Path to configuration file" )

switchoverCmd :: Parser Command
switchoverCmd = CmdSwitchover
  <$> optional (strOption
        ( long "to"
        <> metavar "HOST"
        <> help "Target host to promote" ))
  <*> switch
        ( long "dry-run"
        <> help "Show what would happen without executing" )
  <*> optional (option auto
        ( long "drain-timeout"
        <> metavar "SECS"
        <> help "Wait up to SECS seconds for user connections to close, then KILL remaining" ))

main :: IO ()
main = do
  opts <- execParser (info (cliOptions <**> helper)
    (fullDesc <> progDesc "PureMyHA CLI" <> header "puremyha"))

  let socketPath = optSocketPath opts
      mCluster   = fmap ClusterName (optCluster opts)
      json       = optJsonOutput opts

  case optCommand opts of
    CmdValidateConfig configPath -> runValidateConfig configPath json
    _ -> do
      let req = case optCommand opts of
            CmdStatus             -> ReqStatus mCluster
            CmdTopology           -> ReqTopology mCluster
            CmdSwitchover mTo dr mDt -> ReqSwitchover mCluster mTo dr mDt
            CmdAckRecovery        -> ReqAckRecovery mCluster
            CmdErrantGtid         -> ReqErrantGtid mCluster
            CmdFixErrantGtid      -> ReqFixErrantGtid mCluster
            CmdDemote host src    -> ReqDemote mCluster host src
            CmdDiscovery          -> ReqDiscovery mCluster
            CmdPauseReplica  host -> ReqPauseReplica  mCluster host
            CmdResumeReplica host -> ReqResumeReplica mCluster host
            CmdPauseFailover      -> ReqPauseFailover  mCluster
            CmdResumeFailover     -> ReqResumeFailover mCluster
            CmdSetLogLevel lvl    -> ReqSetLogLevel lvl
            CmdUnfence host       -> ReqUnfence mCluster host
            CmdClone rcpt mDonor  -> ReqClone mCluster rcpt mDonor

      eResp <- sendRequest socketPath req
      case eResp of
        Left err -> do
          hPutStrLn stderr $ "Error: " <> T.unpack err
          exitFailure
        Right resp -> case resp of
          RespStatus statuses        -> printStatus json statuses
          RespTopology views         -> printTopology json views
          RespOperation result       -> printOperationResult json result
          RespErrantGtids gtids      -> printErrantGtids json gtids
          RespError msg              -> do
            hPutStrLn stderr $ "Daemon error: " <> T.unpack msg
            exitFailure

runValidateConfig :: FilePath -> Bool -> IO ()
runValidateConfig configPath json = do
  eCfg <- loadConfig configPath
  case eCfg of
    Left err -> printResult [err] >> exitFailure
    Right cfg ->
      let errs = validateConfig cfg
      in if null errs
           then printResult [] >> exitSuccess
           else printResult errs >> exitFailure
  where
    printResult :: [String] -> IO ()
    printResult [] =
      if json
        then putStrLn $ BLC.unpack $ encode $ object ["valid" .= True]
        else putStrLn "Config is valid."
    printResult errs =
      if json
        then putStrLn $ BLC.unpack $ encode $
               object ["valid" .= False, "errors" .= errs]
        else do
          putStrLn "Config validation failed:"
          mapM_ (\e -> putStrLn $ "  - " <> e) errs
