module PureMyHA.MySQL.Query
  ( showReplicaStatus
  , showReplicas
  , getGtidExecuted
  , changeReplicationSourceTo
  , startReplica
  , stopReplica
  , resetReplicaAll
  , setReadOnly
  , setReadWrite
  , setSuperReadOnly
  , clearSuperReadOnly
  , gtidSubtract
  , gtidSubset
  , injectEmptyTransaction
  , waitForRelayLogApply
  , needsPublicKeyRetrieval
  , checkClonePlugin
  , cloneInstanceFrom
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import Data.List (nubBy)
import Control.Exception (try, SomeException)
import Control.Concurrent (threadDelay)
import Network.Socket (getAddrInfo, defaultHints, addrAddress, getNameInfo, NameInfoFlag(NI_NUMERICHOST))
import Database.MySQL.Base
  ( MySQLConn, MySQLValue (..), query_, execute_
  , Query (..), ColumnDef (..)
  )
import qualified System.IO.Streams as S
import PureMyHA.Config (DbCredentials (..), TLSConfig (..), TLSMode (..))
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
    , rsReplicaSQLRunning   = if look "Replica_SQL_Running" == "Yes" then SQLRunning else SQLStopped
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

-- | Discover connected replicas by combining SHOW REPLICAS (Host column)
-- and SHOW PROCESSLIST (Binlog Dump threads).  Returns discovered NodeIds
-- (deduplicated), the expected replica count from SHOW REPLICAS,
-- and raw hostnames before resolution (for diagnostics).
showReplicas :: MySQLConn -> Int -> IO ([NodeId], Int, [Text])
showReplicas conn defaultPort = do
  -- 1. SHOW REPLICAS — extract Host column where non-empty
  --    Wrapped in try: if the user lacks REPLICATION SLAVE privilege,
  --    we still fall through to SHOW PROCESSLIST.
  (expectedCount, srHosts) <- do
    result <- try @SomeException $ do
      (srCols, srStream) <- query_ conn "SHOW REPLICAS"
      srRows <- consumeRows srStream
      let srColNames = map (TE.decodeUtf8 . columnName) srCols
          hosts = [ h
                  | row <- srRows
                  , let kvs = zip srColNames row
                        h   = textVal (maybe MySQLNull id (lookup "Host" kvs))
                  , h /= ""
                  ]
      pure (length srRows, hosts)
    pure $ case result of
      Left _       -> (0, [])
      Right (n, h) -> (n, h)
  -- 2. SHOW PROCESSLIST — Binlog Dump threads
  (plCols, plStream) <- query_ conn "SHOW PROCESSLIST"
  plRows <- consumeRows plStream
  let plColNames = map (TE.decodeUtf8 . columnName) plCols
      plHosts = [ T.takeWhile (/= ':') h
                | row <- plRows
                , let kvs = zip plColNames row
                      cmd = textVal (maybe MySQLNull id (lookup "Command" kvs))
                      h   = textVal (maybe MySQLNull id (lookup "Host"    kvs))
                , (cmd == "Binlog Dump GTID" || cmd == "Binlog Dump") && h /= ""
                ]
  -- 3. Merge and deduplicate
  let allHosts = srHosts ++ plHosts
  nodes <- mapM (\h -> do
    ip <- resolveHostToIP h
    pure (NodeId ip defaultPort)) allHosts
  let deduped = nubBy (\a b -> nodeHost a == nodeHost b && nodePort a == nodePort b) nodes
  pure (deduped, expectedCount, allHosts)

-- | Get @@GLOBAL.gtid_executed
getGtidExecuted :: MySQLConn -> IO Text
getGtidExecuted conn = do
  (_, stream) <- query_ conn "SELECT @@GLOBAL.gtid_executed"
  rows <- consumeRows stream
  case rows of
    ((v:_):_) -> pure (textVal v)
    _         -> pure ""

-- | Returns True when GET_SOURCE_PUBLIC_KEY=1 should be included in
--   CHANGE REPLICATION SOURCE TO. This is needed when TLS is not in use;
--   when TLS is active the public key is exchanged via the TLS handshake.
needsPublicKeyRetrieval :: Maybe TLSConfig -> Bool
needsPublicKeyRetrieval Nothing   = True
needsPublicKeyRetrieval (Just tc) = tlsMode tc == TLSDisabled

-- | CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1
changeReplicationSourceTo :: MySQLConn -> Text -> Int -> DbCredentials -> Maybe TLSConfig -> IO ()
changeReplicationSourceTo conn host port DbCredentials{..} mTls = do
  let pubKeyOpt = if needsPublicKeyRetrieval mTls
                    then ", GET_SOURCE_PUBLIC_KEY=1"
                    else ""
      sql = "CHANGE REPLICATION SOURCE TO SOURCE_HOST='" <> host
            <> "', SOURCE_PORT=" <> T.pack (show port)
            <> ", SOURCE_USER='" <> dbUser <> "'"
            <> ", SOURCE_PASSWORD='" <> dbPassword <> "'"
            <> ", SOURCE_AUTO_POSITION=1"
            <> pubKeyOpt
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

-- | SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF
-- Clears super_read_only first because in MySQL 8, SET GLOBAL read_only=OFF
-- fails silently when super_read_only=ON (e.g. when promoting a fenced node).
setReadWrite :: MySQLConn -> IO ()
setReadWrite conn = do
  _ <- execute_ conn "SET GLOBAL super_read_only = OFF"
  _ <- execute_ conn "SET GLOBAL read_only = OFF"
  pure ()

-- | SET GLOBAL super_read_only = ON
-- Blocks writes from all connections including SUPER-privileged ones.
setSuperReadOnly :: MySQLConn -> IO ()
setSuperReadOnly conn = do
  _ <- execute_ conn "SET GLOBAL super_read_only = ON"
  pure ()

-- | Clear super_read_only and read_only.
clearSuperReadOnly :: MySQLConn -> IO ()
clearSuperReadOnly conn = do
  _ <- execute_ conn "SET GLOBAL super_read_only = OFF"
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

-- | Wait until all GTIDs in Retrieved_Gtid_Set are applied (appear in Executed_Gtid_Set).
-- Polls SHOW REPLICA STATUS at 1-second intervals.
-- Returns True if caught up, False on timeout.
-- If no replica status exists, returns True (already promoted or standalone).
waitForRelayLogApply :: MySQLConn -> Int -> IO Bool
waitForRelayLogApply conn maxWaitSeconds = go 0
  where
    go elapsed
      | elapsed >= maxWaitSeconds = pure False
      | otherwise = do
          mStatus <- showReplicaStatus conn
          case mStatus of
            Nothing -> pure True  -- no replica status = nothing to wait for
            Just rs -> do
              let retrieved = rsRetrievedGtidSet rs
                  executed  = rsExecutedGtidSet rs
              if T.null retrieved || retrieved == executed
                then pure True
                else do
                  -- Check GTID_SUBSET(Retrieved_Gtid_Set, Executed_Gtid_Set)
                  isSubset <- gtidSubset conn retrieved executed
                  if isSubset
                    then pure True
                    else do
                      threadDelay 1000000  -- 1 second
                      go (elapsed + 1)

-- | Resolve a hostname to a numeric IP address.
-- If resolution fails (or the input is already an IP), returns the input unchanged.
resolveHostToIP :: Text -> IO Text
resolveHostToIP host = do
  result <- try @SomeException $ do
    infos <- getAddrInfo (Just defaultHints) (Just (T.unpack host)) Nothing
    case infos of
      (ai:_) -> do
        (Just numericHost, _) <- getNameInfo [NI_NUMERICHOST] True False (addrAddress ai)
        pure (T.pack numericHost)
      [] -> pure host
  pure $ case result of
    Left _   -> host
    Right ip -> ip

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

-- | Check if the CLONE plugin is installed and ACTIVE on the given node.
checkClonePlugin :: MySQLConn -> IO Bool
checkClonePlugin conn = do
  (_, stream) <- query_ conn
    "SELECT PLUGIN_NAME FROM INFORMATION_SCHEMA.PLUGINS \
    \WHERE PLUGIN_NAME = 'clone' AND PLUGIN_STATUS = 'ACTIVE'"
  rows <- consumeRows stream
  pure (not (null rows))

-- | Execute CLONE INSTANCE FROM on a recipient node connection.
-- The recipient MySQL instance clones data from the specified donor.
-- NOTE: The MySQL process restarts after cloning; the connection will be dropped.
cloneInstanceFrom :: MySQLConn -> Text -> Int -> DbCredentials -> IO ()
cloneInstanceFrom conn donorHost donorPort DbCredentials{..} = do
  let sql = "CLONE INSTANCE FROM '" <> dbUser <> "'@'" <> donorHost <> "':"
            <> T.pack (show donorPort) <> " IDENTIFIED BY '" <> dbPassword <> "'"
  _ <- execute_ conn (toQuery (BL.fromStrict (TE.encodeUtf8 sql)))
  pure ()
