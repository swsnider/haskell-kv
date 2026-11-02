{- | The wire protocol: parsing requests and rendering replies.

Everything here is pure. Nothing touches a socket, which is what lets
test/Spec.hs check the parser with QuickCheck instead of a live server.
-}
module KV.Command (
    Command (..),
    Reply (..),
    parseCommand,
    renderCommand,
    renderReply,
) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Char (toUpper)

data Command
    = Ping
    | Get ByteString
    | Set ByteString ByteString
    | Del ByteString
    | Incr ByteString
    | IncrBy ByteString ByteString
    | Decr ByteString
    | DecrBy ByteString ByteString
    | MSet [ByteString]
    | MSetNX [ByteString]
    | MGet [ByteString]
    | GetSet ByteString ByteString
    deriving stock (Eq, Show)

data Reply
    = Pong
    | Ok
    | Value ByteString
    | Nil
    | Count Int
    | Array [Reply]
    | Error ByteString
    deriving stock (Eq, Show)

{- | Parse one line of the toy text protocol, e.g. @SET name alice@.

Tokens are whitespace-separated, so values can't contain spaces. Fixing
that properly is what the RESP exercise in the README is for.
-}
parseCommand :: ByteString -> Either ByteString Command
parseCommand line = case BC.words line of
    [cmd] | cmd `is` "PING" -> Right Ping
    [cmd, k] | cmd `is` "GET" -> Right (Get k)
    [cmd, k, v] | cmd `is` "SET" -> Right (Set k v)
    [cmd, k] | cmd `is` "DEL" -> Right (Del k)
    [cmd, k] | cmd `is` "INCR" -> Right (Incr k)
    [cmd, k, n] | cmd `is` "INCRBY" -> Right (IncrBy k n)
    [cmd, k] | cmd `is` "DECR" -> Right (Decr k)
    [cmd, k, n] | cmd `is` "DECRBY" -> Right (DecrBy k n)
    cmd : args | cmd `is` "MSET" -> Right (MSet args)
    cmd : args | cmd `is` "MSETNX" -> Right (MSetNX args)
    cmd : args | cmd `is` "MGET" -> Right (MGet args)
    [cmd, k, v] | cmd `is` "GETSET" -> Right (GetSet k v)
    [] -> Left "ERR empty command"
    (cmd : _) -> Left ("ERR unknown command or wrong number of arguments: " <> cmd)
  where
    is cmd name = BC.map toUpper cmd == name

-- | The inverse of 'parseCommand' (for well-formed tokens).
renderCommand :: Command -> ByteString
renderCommand =
    BC.unwords . \case
        Ping -> ["PING"]
        Get k -> ["GET", k]
        Set k v -> ["SET", k, v]
        Del k -> ["DEL", k]
        Incr k -> ["INCR", k]
        IncrBy k n -> ["INCRBY", k, n]
        Decr k -> ["DECR", k]
        DecrBy k n -> ["DECRBY", k, n]
        MSet args -> ["MSET"] <> args
        MSetNX args -> ["MSETNX"] <> args
        MGet args -> ["MGET"] <> args
        GetSet k v -> ["GETSET", k, v]

renderReply :: Reply -> ByteString
renderReply =
    \case
        Pong -> "PONG"
        Ok -> "OK"
        Value v -> v
        Nil -> "(nil)"
        Count n -> BC.pack (show n)
        Array [] -> "(empty array)"
        Array elements -> BC.unlines (zipWith numbered [1 :: Int ..] elements)
        Error e -> e
  where
    numbered i r = BC.pack (show i) <> ") " <> renderReply r
