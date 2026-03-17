module PureMyHA.MySQL.GTID
  ( isEmptyGtidSet
  , parseGtidIntervals
  , gtidTransactionCount
  , GtidInterval (..)
  , GtidEntry (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | Check if a GTID set string is empty
isEmptyGtidSet :: Text -> Bool
isEmptyGtidSet t = T.null (T.strip t)

-- | A single interval within a GTID set
data GtidInterval = GtidInterval
  { giStart :: Integer
  , giEnd   :: Integer
  } deriving (Eq, Show)

-- | A parsed GTID entry: UUID with its intervals
data GtidEntry = GtidEntry
  { geUuid      :: Text
  , geIntervals :: [GtidInterval]
  } deriving (Eq, Show)

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
          pure (GtidEntry uuid parsed)
        _ -> Left $ "Invalid GTID entry: " <> T.unpack entry

    parseInterval iv =
      case T.splitOn "-" iv of
        [s] ->
          case readMaybe (T.unpack s) of
            Just n  -> Right (GtidInterval n n)
            Nothing -> Left $ "Invalid GTID interval: " <> T.unpack iv
        [s, e] ->
          case (readMaybe (T.unpack s), readMaybe (T.unpack e)) of
            (Just start, Just end) -> Right (GtidInterval start end)
            _ -> Left $ "Invalid GTID interval: " <> T.unpack iv
        _ -> Left $ "Invalid GTID interval: " <> T.unpack iv

-- | GTID セット文字列中のトランザクション総数を返す。
-- パースエラーまたは空文字列の場合は 0 を返す。
gtidTransactionCount :: Text -> Integer
gtidTransactionCount t =
  case parseGtidIntervals t of
    Left  _       -> 0
    Right entries -> sum
      [ giEnd iv - giStart iv + 1
      | entry <- entries
      , iv    <- geIntervals entry
      ]
