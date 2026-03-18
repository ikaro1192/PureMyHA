module PureMyHA.MySQL.Query
  ( showReplicaStatus
  , showReplicas
  , countExpectedReplicas
  , getGtidExecuted
  , changeReplicationSourceTo
  , startReplica
  , stopReplica
  , resetReplicaAll
  , setReadOnly
  , setReadWrite
  , gtidSubtract
  , gtidSubset
  , injectEmptyTransaction
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import Database.MySQL.Base
  ( MySQLConn, MySQLValue (..), query_, execute_
  , Query (..), ColumnDef (..)
  )
import qualified System.IO.Streams as S
import PureMyHA.Types

-- | Convert a lazy ByteString SQL to a Query
toQuery :: BL.ByteString -> Query
toQuery = Query

-- | Consume all rows from an InputStream
consumeRows :: S.InputStream [MySQLValue] -> IO [[MySQLValue]]
consumeRows = S.toList

-- | SHOW REPLICA STATUS (MySQL 8.4 syntax)
showReplicaStatus :: MySQLConn -> IO (Maybe ReplicaStatus)
showReplicaStatus conn = do
  (cols, stream) <- query_ conn "SHOW REPLICA STATUS"
  rows <- consumeRows stream
  case rows of
    []    -> pure Nothing
    (r:_) -> pure (parseReplicaStatus (zip (map (TE.decodeUtf8 . columnName) cols) r))

parseReplicaStatus :: [(Text, MySQLValue)] -> Maybe ReplicaStatus
parseReplicaStatus kvs =
  Just ReplicaStatus
    { rsSourceHost          = look "Source_Host"
    , rsSourcePort          = intVal (raw "Source_Port")
    , rsReplicaIORunning    = parseIORunning (look "Replica_IO_Running")
    , rsReplicaSQLRunning   = look "Replica_SQL_Running" == "Yes"
    , rsSecondsBehindSource = maybeIntVal (raw "Seconds_Behind_Source")
    , rsExecutedGtidSet     = look "Executed_Gtid_Set"
    , rsRetrievedGtidSet    = look "Retrieved_Gtid_Set"
    , rsLastIOError         = look "Last_IO_Error"
    , rsLastSQLError        = look "Last_SQL_Error"
    }
  where
    raw  name = maybe MySQLNull id (lookup name kvs)
    look name = textVal (raw name)

parseIORunning :: Text -> IORunning
parseIORunning "Yes"        = IOYes
parseIORunning "Connecting" = IOConnecting
parseIORunning _            = IONo

-- | SHOW REPLICAS — returns the count of replicas listed (MySQL 8.4).
-- Used only to validate against the SHOW PROCESSLIST discovery count.
countExpectedReplicas :: MySQLConn -> IO Int
countExpectedReplicas conn = do
  (_, stream) <- query_ conn "SHOW REPLICAS"
  rows <- consumeRows stream
  pure (length rows)

-- | Discover connected replicas via SHOW PROCESSLIST by inspecting
-- "Binlog Dump GTID" / "Binlog Dump" threads.  The Host column in
-- SHOW PROCESSLIST has the form "ip:port", so we can extract the IP
-- even when report_host is not set on the replica.
showReplicas :: MySQLConn -> Int -> IO [NodeId]
showReplicas conn defaultPort = do
  (cols, stream) <- query_ conn "SHOW PROCESSLIST"
  rows <- consumeRows stream
  let colNames = map (TE.decodeUtf8 . columnName) cols
      toNodeId row =
        let kvs = zip colNames row
            cmd = textVal (maybe MySQLNull id (lookup "Command" kvs))
            h   = textVal (maybe MySQLNull id (lookup "Host"    kvs))
            ip  = T.takeWhile (/= ':') h
        in if (cmd == "Binlog Dump GTID" || cmd == "Binlog Dump") && ip /= ""
             then Just (NodeId ip defaultPort)
             else Nothing
  pure [nid | Just nid <- map toNodeId rows]

-- | Get @@GLOBAL.gtid_executed
getGtidExecuted :: MySQLConn -> IO Text
getGtidExecuted conn = do
  (_, stream) <- query_ conn "SELECT @@GLOBAL.gtid_executed"
  rows <- consumeRows stream
  case rows of
    ((v:_):_) -> pure (textVal v)
    _         -> pure ""

-- | CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1
changeReplicationSourceTo :: MySQLConn -> Text -> Int -> Text -> Text -> IO ()
changeReplicationSourceTo conn host port replUser replPassword = do
  let sql = "CHANGE REPLICATION SOURCE TO SOURCE_HOST='" <> host
            <> "', SOURCE_PORT=" <> T.pack (show port)
            <> ", SOURCE_USER='" <> replUser <> "'"
            <> ", SOURCE_PASSWORD='" <> replPassword <> "'"
            <> ", SOURCE_AUTO_POSITION=1"
            <> ", SOURCE_GET_SOURCE_PUBLIC_KEY=1"
  _ <- execute_ conn (toQuery (BL.fromStrict (TE.encodeUtf8 sql)))
  pure ()

-- | START REPLICA
startReplica :: MySQLConn -> IO ()
startReplica conn = do
  _ <- execute_ conn "START REPLICA"
  pure ()

-- | STOP REPLICA
stopReplica :: MySQLConn -> IO ()
stopReplica conn = do
  _ <- execute_ conn "STOP REPLICA"
  pure ()

-- | RESET REPLICA ALL
resetReplicaAll :: MySQLConn -> IO ()
resetReplicaAll conn = do
  _ <- execute_ conn "RESET REPLICA ALL"
  pure ()

-- | SET GLOBAL read_only = ON
setReadOnly :: MySQLConn -> IO ()
setReadOnly conn = do
  _ <- execute_ conn "SET GLOBAL read_only = ON"
  pure ()

-- | SET GLOBAL read_only = OFF
setReadWrite :: MySQLConn -> IO ()
setReadWrite conn = do
  _ <- execute_ conn "SET GLOBAL read_only = OFF"
  pure ()

-- | Use MySQL GTID_SUBTRACT to find errant GTIDs
gtidSubtract :: MySQLConn -> Text -> Text -> IO Text
gtidSubtract conn replicaGtid sourceGtid = do
  let sql = "SELECT GTID_SUBTRACT('" <> replicaGtid <> "', '" <> sourceGtid <> "')"
  (_, stream) <- query_ conn (toQuery (BL.fromStrict (TE.encodeUtf8 sql)))
  rows <- consumeRows stream
  case rows of
    [[v]] -> pure (textVal v)
    _     -> pure ""

-- | Use MySQL GTID_SUBSET to check if replicaGtid is a subset of sourceGtid
gtidSubset :: MySQLConn -> Text -> Text -> IO Bool
gtidSubset conn replicaGtid sourceGtid = do
  let sql = "SELECT GTID_SUBSET('" <> replicaGtid <> "', '" <> sourceGtid <> "')"
  (_, stream) <- query_ conn (toQuery (BL.fromStrict (TE.encodeUtf8 sql)))
  rows <- consumeRows stream
  case rows of
    [[v]] -> pure (intVal v == 1)
    _     -> pure False

-- | Inject an empty transaction for a given GTID (for errant GTID repair)
injectEmptyTransaction :: MySQLConn -> Text -> IO ()
injectEmptyTransaction conn gtid = do
  _ <- execute_ conn (toQuery (BL.fromStrict (TE.encodeUtf8 ("SET GTID_NEXT='" <> gtid <> "'"))))
  _ <- execute_ conn "BEGIN"
  _ <- execute_ conn "COMMIT"
  _ <- execute_ conn "SET GTID_NEXT='AUTOMATIC'"
  pure ()

-- Helpers
textVal :: MySQLValue -> Text
textVal (MySQLText t)  = t
textVal (MySQLBytes b) = TE.decodeUtf8 b
textVal MySQLNull      = ""
textVal v              = T.pack (show v)

intVal :: MySQLValue -> Int
intVal (MySQLInt8 n)    = fromIntegral n
intVal (MySQLInt8U n)   = fromIntegral n
intVal (MySQLInt16 n)   = fromIntegral n
intVal (MySQLInt16U n)  = fromIntegral n
intVal (MySQLInt32 n)   = fromIntegral n
intVal (MySQLInt32U n)  = fromIntegral n
intVal (MySQLInt64 n)   = fromIntegral n
intVal (MySQLInt64U n)  = fromIntegral n
intVal (MySQLText t)    = maybe 0 id (readMaybeInt t)
intVal _                = 0

maybeIntVal :: MySQLValue -> Maybe Int
maybeIntVal MySQLNull = Nothing
maybeIntVal v         = Just (intVal v)

readMaybeInt :: Text -> Maybe Int
readMaybeInt t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _         -> Nothing
