module PureMyHA.MySQL.GTID
  ( isEmptyGtidSet
  , parseGtidSet
  , parseGtidIntervals
  , renderGtidEntry
  , renderGtidSet
  , gtidTransactionCount
  , mkGtidInterval
  , mkGtidTag
  , mkSingleGtid
  , emptyGtidSet
  , expandGtidEntry
  , GtidInterval (..)
  , GtidEntry (..)
  , GtidSet (..)
  , GtidTag (..)
  , TransactionId (..)
  , GtidUUID (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Char (isAlpha, isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | A transaction sequence number within a GTID set.
newtype TransactionId = TransactionId { getTransactionId :: Integer }
  deriving (Eq, Ord, Show, Enum)

-- | A MySQL server UUID used as the source identifier in a GTID.
newtype GtidUUID = GtidUUID { getGtidUUID :: Text }
  deriving (Eq, Ord, Show)

-- | A tag for MySQL 8.4+ tagged GTIDs.
-- Tags must start with a letter or underscore, contain only alphanumeric
-- characters and underscores, and be at most 32 characters long.
newtype GtidTag = GtidTag { getGtidTag :: Text }
  deriving (Eq, Ord, Show)

-- | Smart constructor for GtidTag with validation.
mkGtidTag :: Text -> Either String GtidTag
mkGtidTag t
  | T.null t = Left "GtidTag cannot be empty"
  | T.length t > 32 = Left "GtidTag must be at most 32 characters"
  | not (isValidFirst (T.head t)) = Left "GtidTag must start with a letter or underscore"
  | not (T.all isValidChar t) = Left "GtidTag must contain only alphanumeric characters and underscores"
  | otherwise = Right (GtidTag t)
  where
    isValidFirst c = isAlpha c || c == '_'
    isValidChar  c = isAlphaNum c || c == '_'

-- | A single interval within a GTID set
data GtidInterval = GtidInterval
  { giStart :: TransactionId
  , giEnd   :: TransactionId
  } deriving (Eq, Show)

-- | A parsed GTID entry: UUID with optional tag and its intervals.
-- Also used to represent individual GTIDs (single interval where start == end).
data GtidEntry = GtidEntry
  { geUuid      :: GtidUUID
  , geTag       :: Maybe GtidTag
  , geIntervals :: [GtidInterval]
  } deriving (Eq, Show)

-- | A parsed GTID set.
newtype GtidSet = GtidSet { getGtidEntries :: [GtidEntry] }
  deriving (Eq, Show)

instance ToJSON GtidSet where
  toJSON = toJSON . renderGtidSet

instance FromJSON GtidSet where
  parseJSON v = do
    t <- parseJSON v
    case parseGtidSet t of
      Left err -> fail err
      Right gs -> pure gs

-- | The empty GTID set.
emptyGtidSet :: GtidSet
emptyGtidSet = GtidSet []

-- | Check if a GTID set is empty.
isEmptyGtidSet :: GtidSet -> Bool
isEmptyGtidSet (GtidSet entries) = null entries

-- | Smart constructor that validates giStart <= giEnd.
mkGtidInterval :: Integer -> Integer -> Either String GtidInterval
mkGtidInterval s e
  | s <= e    = Right (GtidInterval (TransactionId s) (TransactionId e))
  | otherwise = Left $ "giStart > giEnd: " <> show s <> " > " <> show e

-- | Construct a single GTID as a GtidEntry (one interval where start == end).
mkSingleGtid :: GtidUUID -> Maybe GtidTag -> TransactionId -> GtidEntry
mkSingleGtid uuid tag tid = GtidEntry uuid tag [GtidInterval tid tid]

-- | Parse a GTID set string into a GtidSet.
-- Format: "uuid1:n1-n2:n3,uuid2:tag:n4-n5"
-- Returns Left on parse failure.
parseGtidSet :: Text -> Either String GtidSet
parseGtidSet t
  | isEmptyText t = Right emptyGtidSet
  | otherwise = GtidSet <$> mapM parseEntry (T.splitOn "," (T.strip t))
  where
    isEmptyText = T.null . T.strip

    parseEntry entry =
      case T.splitOn ":" (T.strip entry) of
        (uuid : rest) | not (T.null uuid), not (null rest) ->
          case rest of
            (seg : segs)
              | isTagSegment seg -> do
                  tag <- mkGtidTag seg
                  parsed <- mapM parseInterval segs
                  pure (GtidEntry (GtidUUID uuid) (Just tag) parsed)
              | otherwise -> do
                  parsed <- mapM parseInterval rest
                  pure (GtidEntry (GtidUUID uuid) Nothing parsed)
            [] -> Left $ "Invalid GTID entry (no intervals): " <> T.unpack entry
        _ -> Left $ "Invalid GTID entry: " <> T.unpack entry

    -- A segment is a tag if it starts with a letter or underscore.
    -- Interval segments always start with a digit.
    isTagSegment seg = case T.uncons seg of
      Just (c, _) -> isAlpha c || c == '_'
      Nothing     -> False

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

-- | Parse a GTID set string into structured entries.
-- Alias for parseGtidSet that returns [GtidEntry] for backward compatibility.
parseGtidIntervals :: Text -> Either String [GtidEntry]
parseGtidIntervals t = getGtidEntries <$> parseGtidSet t

-- | Render a single GtidInterval to its string representation.
renderGtidInterval :: GtidInterval -> Text
renderGtidInterval (GtidInterval s e)
  | s == e    = T.pack (show (getTransactionId s))
  | otherwise = T.pack (show (getTransactionId s)) <> "-" <> T.pack (show (getTransactionId e))

-- | Render a GtidEntry to its string representation (e.g. "uuid:1-5:7-10" or "uuid:tag:1-5").
renderGtidEntry :: GtidEntry -> Text
renderGtidEntry (GtidEntry uuid mTag ivs) =
  T.intercalate ":" (getGtidUUID uuid : tagParts ++ map renderGtidInterval ivs)
  where
    tagParts = case mTag of
      Nothing  -> []
      Just tag -> [getGtidTag tag]

-- | Render a GtidSet to a GTID set string (comma-separated).
renderGtidSet :: GtidSet -> Text
renderGtidSet (GtidSet entries) = T.intercalate "," (map renderGtidEntry entries)

-- | Returns the total number of transactions in a GtidSet.
gtidTransactionCount :: GtidSet -> Integer
gtidTransactionCount (GtidSet entries) = sum
  [ getTransactionId (giEnd iv) - getTransactionId (giStart iv) + 1
  | entry <- entries
  , iv    <- geIntervals entry
  ]

-- | Expand one GtidEntry to individual GtidEntries (one per transaction).
expandGtidEntry :: GtidEntry -> [GtidEntry]
expandGtidEntry GtidEntry{..} =
  [ mkSingleGtid geUuid geTag n
  | GtidInterval{..} <- geIntervals
  , n <- [giStart .. giEnd]
  ]
