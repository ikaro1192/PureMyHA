module PureMyHA.MySQL.GTID
  ( isEmptyGtidSet
  , parseGtidIntervals
  , renderGtidEntry
  , renderGtidSet
  , gtidTransactionCount
  , mkGtidInterval
  , GtidInterval (..)
  , GtidEntry (..)
  , TransactionId (..)
  , GtidUUID (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | A transaction sequence number within a GTID set.
newtype TransactionId = TransactionId { getTransactionId :: Integer }
  deriving (Eq, Ord, Show, Enum)

-- | A MySQL server UUID used as the source identifier in a GTID.
newtype GtidUUID = GtidUUID { getGtidUUID :: Text }
  deriving (Eq, Ord, Show)

-- | Check if a GTID set string is empty
isEmptyGtidSet :: Text -> Bool
isEmptyGtidSet t = T.null (T.strip t)

-- | A single interval within a GTID set
data GtidInterval = GtidInterval
  { giStart :: TransactionId
  , giEnd   :: TransactionId
  } deriving (Eq, Show)

-- | A parsed GTID entry: UUID with its intervals
data GtidEntry = GtidEntry
  { geUuid      :: GtidUUID
  , geIntervals :: [GtidInterval]
  } deriving (Eq, Show)

-- | Smart constructor that validates giStart <= giEnd.
mkGtidInterval :: Integer -> Integer -> Either String GtidInterval
mkGtidInterval s e
  | s <= e    = Right (GtidInterval (TransactionId s) (TransactionId e))
  | otherwise = Left $ "giStart > giEnd: " <> show s <> " > " <> show e

-- | Parse a GTID set string into structured entries.
-- Format: "uuid1:n1-n2:n3,uuid2:n4-n5"
-- Returns Left on parse failure.
parseGtidIntervals :: Text -> Either String [GtidEntry]
parseGtidIntervals t
  | isEmptyGtidSet t = Right []
  | otherwise = mapM parseEntry (T.splitOn "," (T.strip t))
  where
    parseEntry entry =
      case T.splitOn ":" (T.strip entry) of
        (uuid : intervals) | not (T.null uuid) -> do
          parsed <- mapM parseInterval intervals
          pure (GtidEntry (GtidUUID uuid) parsed)
        _ -> Left $ "Invalid GTID entry: " <> T.unpack entry

    parseInterval iv =
      case T.splitOn "-" iv of
        [s] ->
          case readMaybe (T.unpack s) of
            Just n  -> Right (GtidInterval (TransactionId n) (TransactionId n))
            Nothing -> Left $ "Invalid GTID interval: " <> T.unpack iv
        [s, e] ->
          case (readMaybe (T.unpack s), readMaybe (T.unpack e)) of
            (Just start, Just end) -> Right (GtidInterval (TransactionId start) (TransactionId end))
            _ -> Left $ "Invalid GTID interval: " <> T.unpack iv
        _ -> Left $ "Invalid GTID interval: " <> T.unpack iv

-- | Render a single GtidInterval to its string representation.
renderGtidInterval :: GtidInterval -> Text
renderGtidInterval (GtidInterval s e)
  | s == e    = T.pack (show (getTransactionId s))
  | otherwise = T.pack (show (getTransactionId s)) <> "-" <> T.pack (show (getTransactionId e))

-- | Render a GtidEntry to its string representation (e.g. "uuid:1-5:7-10").
renderGtidEntry :: GtidEntry -> Text
renderGtidEntry (GtidEntry uuid ivs) =
  T.intercalate ":" (getGtidUUID uuid : map renderGtidInterval ivs)

-- | Render a list of GtidEntry to a GTID set string (comma-separated).
renderGtidSet :: [GtidEntry] -> Text
renderGtidSet = T.intercalate "," . map renderGtidEntry

-- | Returns the total number of transactions in a GTID set string.
-- Returns 0 on parse error or empty string.
gtidTransactionCount :: Text -> Integer
gtidTransactionCount t =
  case parseGtidIntervals t of
    Left  _       -> 0
    Right entries -> sum
      [ getTransactionId (giEnd iv) - getTransactionId (giStart iv) + 1
      | entry <- entries
      , iv    <- geIntervals entry
      ]
