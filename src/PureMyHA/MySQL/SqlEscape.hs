-- | Pure SQL literal escaping and whitelist validation helpers.
--
-- MySQL's 'CHANGE REPLICATION SOURCE TO' and 'CLONE INSTANCE FROM' statements
-- do not support prepared statements, so any text embedded in those queries
-- must be escaped at the application layer.
module PureMyHA.MySQL.SqlEscape
  ( escapeSqlString
  , quoteSqlString
  , validateIdentifierLike
  , validateGtidRendering
  ) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as T

-- | Escape a 'Text' value for safe embedding inside a single-quoted SQL
-- string literal. Doubles both @'@ and @\\@ so the result is safe regardless
-- of whether @NO_BACKSLASH_ESCAPES@ is set on the server.
escapeSqlString :: Text -> Text
escapeSqlString = T.concatMap escapeChar
  where
    escapeChar '\'' = "''"
    escapeChar '\\' = "\\\\"
    escapeChar c    = T.singleton c

-- | Wrap a value in single quotes with its contents escaped.
-- E.g. @quoteSqlString "can't" == "'can''t'"@.
quoteSqlString :: Text -> Text
quoteSqlString t = "'" <> escapeSqlString t <> "'"

-- | Whitelist validation for hostname- or username-shaped identifiers.
--
-- Accepts non-empty strings containing only @[A-Za-z0-9]@, @-@, @.@, or @_@.
-- This covers DNS hostnames (RFC 1123 labels), IPv4 dotted-decimal literals,
-- and typical MySQL account names. Any other character is rejected so that
-- identifiers can be interpolated into DDL that does not support prepared
-- statements without risk of SQL injection.
validateIdentifierLike :: Text -> Either Text Text
validateIdentifierLike t
  | T.null t = Left "identifier must not be empty"
  | T.all isAllowed t = Right t
  | otherwise = Left ("identifier contains disallowed characters: " <> t)
  where
    isAllowed c = isAlphaNum c || c == '-' || c == '.' || c == '_'

-- | Defence-in-depth validation for GTID-set renderings.
--
-- 'PureMyHA.MySQL.GTID.renderGtidSet' and 'renderGtidEntry' emit only
-- alphanumeric characters plus @-@, @:@, @,@, and @_@ (the last for tagged
-- GTIDs). This helper enforces that invariant at the embedding site so a
-- future change to the renderer cannot silently introduce injection.
validateGtidRendering :: Text -> Either Text Text
validateGtidRendering t
  | T.all isAllowed t = Right t
  | otherwise = Left ("GTID rendering contains disallowed characters: " <> t)
  where
    isAllowed c = isAlphaNum c || c == '-' || c == ':' || c == ',' || c == '_'
