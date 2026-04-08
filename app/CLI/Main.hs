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
import PureMyHA.Types (ClusterName (..), HostName (..))

data CLIOptions = CLIOptions
  { optSocketPath  :: FilePath
  , optCluster     :: Maybe Text
  , optJsonOutput  :: Bool
  , optCommand     :: Command
  }

data Command
  = CmdStatus
  | CmdTopology
  | CmdSwitchover (Maybe HostName) Bool (Maybe Int)
  | CmdAckRecovery
  | CmdErrantGtid
  | CmdFixErrantGtid Bool          -- dry-run
  | CmdDemote HostName HostName Bool   -- host, source, dry-run
  | CmdSimulateFailover
  | CmdDiscovery
  | CmdPauseReplica  HostName
  | CmdResumeReplica HostName
  | CmdStopReplication  HostName
  | CmdStartReplication HostName
  | CmdPauseFailover
  | CmdResumeFailover
  | CmdSetLogLevel Text
  | CmdValidateConfig FilePath
  | CmdUnfence HostName
  | CmdClone HostName (Maybe HostName)   -- recipient, donor?

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
            (info fixErrantGtidCmd (progDesc "Fix errant GTIDs with empty transactions"))
        <> command "demote"
            (info demoteCmd (progDesc "Demote a node to replica under specified source"))
        <> command "simulate-failover"
            (info (pure CmdSimulateFailover) (progDesc "Simulate what would happen if the source died right now"))
        <> command "discovery"
            (info (pure CmdDiscovery) (progDesc "Trigger manual topology discovery"))
        <> command "pause-replica"
            (info pauseReplicaCmd (progDesc "Exclude a replica from failover candidates (does not stop MySQL replication)"))
        <> command "resume-replica"
            (info resumeReplicaCmd (progDesc "Re-include a paused replica in failover candidates (does not start MySQL replication)"))
        <> command "stop-replication"
            (info stopReplicationCmd (progDesc "Stop MySQL replication on a replica and exclude from failover"))
        <> command "start-replication"
            (info startReplicationCmd (progDesc "Start MySQL replication on a replica and re-include in failover"))
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

fixErrantGtidCmd :: Parser Command
fixErrantGtidCmd = CmdFixErrantGtid
  <$> switch (long "dry-run" <> help "Show what would happen without executing")

demoteCmd :: Parser Command
demoteCmd = CmdDemote
  <$> (HostName <$> strOption (long "host"   <> metavar "HOST" <> help "Node to demote"))
  <*> (HostName <$> strOption (long "source" <> metavar "HOST" <> help "New replication source host"))
  <*> switch (long "dry-run" <> help "Show SQL that would be executed without running it")

pauseReplicaCmd :: Parser Command
pauseReplicaCmd = CmdPauseReplica <$> (HostName <$> strOption (long "host" <> metavar "HOST" <> help "Node to pause"))

resumeReplicaCmd :: Parser Command
resumeReplicaCmd = CmdResumeReplica <$> (HostName <$> strOption (long "host" <> metavar "HOST" <> help "Node to resume"))

stopReplicationCmd :: Parser Command
stopReplicationCmd = CmdStopReplication <$> (HostName <$> strOption (long "host" <> metavar "HOST" <> help "Node to stop replication on"))

startReplicationCmd :: Parser Command
startReplicationCmd = CmdStartReplication <$> (HostName <$> strOption (long "host" <> metavar "HOST" <> help "Node to start replication on"))

setLogLevelCmd :: Parser Command
setLogLevelCmd = CmdSetLogLevel
  <$> argument str (metavar "LEVEL" <> help "Log level: debug, info, warn, error")

unfenceCmd :: Parser Command
unfenceCmd = CmdUnfence
  <$> (HostName <$> strOption (long "host" <> metavar "HOST" <> help "Host to unfence (clears super_read_only)"))

cloneCmd :: Parser Command
cloneCmd = CmdClone
  <$> (HostName <$> strOption (long "recipient" <> metavar "HOST[:PORT]"
        <> help "Replica node to re-seed"))
  <*> optional (HostName <$> strOption (long "donor" <> metavar "HOST[:PORT]"
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
  <$> optional (HostName <$> strOption
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

toExec :: Bool -> ExecutionMode
toExec True  = DryRun
toExec False = Live

main :: IO ()
main = do
  opts <- execParser (info (cliOptions <**> helper)
    (fullDesc <> progDesc "PureMyHA CLI" <> header "puremyha"))

  let socketPath = optSocketPath opts
      mCluster   = fmap ClusterName (optCluster opts)
      json       = optJsonOutput opts

  case optCommand opts of
    CmdValidateConfig configPath -> runValidateConfig configPath json
    cmd -> do
      let req = case cmd of
            CmdStatus             -> ReqStatus mCluster
            CmdTopology           -> ReqTopology mCluster
            CmdSwitchover mTo dr mDt ->
              let target = case mTo of
                    Nothing   -> AutoSelectTarget
                    Just host -> ExplicitTarget host mDt
              in ReqSwitchover mCluster target (toExec dr)
            CmdAckRecovery        -> ReqAckRecovery mCluster
            CmdErrantGtid         -> ReqErrantGtid mCluster
            CmdFixErrantGtid dr   -> ReqFixErrantGtid mCluster (toExec dr)
            CmdDemote host src dr -> ReqDemote mCluster host src (toExec dr)
            CmdSimulateFailover   -> ReqSimulateFailover mCluster
            CmdDiscovery          -> ReqDiscovery mCluster
            CmdPauseReplica  host -> ReqPauseReplica  mCluster host
            CmdResumeReplica host -> ReqResumeReplica mCluster host
            CmdStopReplication  host -> ReqStopReplication  mCluster host
            CmdStartReplication host -> ReqStartReplication mCluster host
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
