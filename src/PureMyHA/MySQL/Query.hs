module PureMyHA.MySQL.Query
  ( showReplicaStatus
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
  , Query (..)
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
  (_, stream) <- query_ conn "SHOW REPLICA STATUS"
  rows <- consumeRows stream
  case rows of
    []    -> pure Nothing
    (r:_) -> pure (parseReplicaStatus r)

parseReplicaStatus :: [MySQLValue] -> Maybe ReplicaStatus
parseReplicaStatus row
  | length row < 52 = Nothing
  | otherwise = Just ReplicaStatus
      { rsSourceHost          = textVal (row !! 1)
      , rsSourcePort          = intVal  (row !! 3)
      , rsReplicaIORunning    = parseIORunning (textVal (row !! 10))
      , rsReplicaSQLRunning   = textVal (row !! 11) == "Yes"
      , rsSecondsBehindSource = maybeIntVal (row !! 32)
      , rsExecutedGtidSet     = textVal (row !! 51)
      , rsRetrievedGtidSet    = textVal (row !! 50)
      , rsLastIOError         = textVal (row !! 38)
      , rsLastSQLError        = textVal (row !! 37)
      }

parseIORunning :: Text -> IORunning
parseIORunning "Yes"        = IOYes
parseIORunning "Connecting" = IOConnecting
parseIORunning _            = IONo

-- | Get @@GLOBAL.gtid_executed
getGtidExecuted :: MySQLConn -> IO Text
getGtidExecuted conn = do
  (_, stream) <- query_ conn "SELECT @@GLOBAL.gtid_executed"
  rows <- consumeRows stream
  case rows of
    ((v:_):_) -> pure (textVal v)
    _         -> pure ""

-- | CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1
changeReplicationSourceTo :: MySQLConn -> Text -> Int -> IO ()
changeReplicationSourceTo conn host port = do
  let sql = "CHANGE REPLICATION SOURCE TO SOURCE_HOST='" <> host
            <> "', SOURCE_PORT=" <> T.pack (show port)
            <> ", SOURCE_AUTO_POSITION=1"
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
