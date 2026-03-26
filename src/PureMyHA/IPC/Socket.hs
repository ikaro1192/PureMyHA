module PureMyHA.IPC.Socket (recvLine, maxLineLength) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Text (Text)
import Network.Socket (Socket)
import qualified Network.Socket.ByteString as NSB

-- | Maximum allowed line length (1 MiB).
maxLineLength :: Int
maxLineLength = 1_048_576

-- | Receive bytes from a socket until a newline is found.
-- Returns 'Right' with the bytes before @'\n'@, or
-- 'Left' with an error message if the connection is closed
-- or the line exceeds 'maxLineLength'.
recvLine :: Socket -> IO (Either Text BS.ByteString)
recvLine sock = go [] 0
  where
    go acc !totalLen = do
      chunk <- NSB.recv sock 4096
      if BS.null chunk
        then pure (Left "Connection closed before newline")
        else do
          let newTotal = totalLen + BS.length chunk
          if newTotal > maxLineLength
            then pure (Left "Line too long (exceeds 1 MiB)")
            else do
              let acc' = chunk : acc
                  full = BS.concat (reverse acc')
              if BSC.elem '\n' full
                then pure (Right (BSC.takeWhile (/= '\n') full))
                else go acc' newTotal
