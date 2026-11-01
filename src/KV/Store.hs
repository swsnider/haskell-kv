-- | The shared key-value store.
--
-- All state lives in one 'TVar', and every operation is an 'STM' action
-- rather than an 'IO' action. That means callers decide where transactions
-- begin and end: @atomically (execute s a >> execute s b)@ runs both
-- commands as a single atomic unit, with no locks in sight.
module KV.Store
  ( Store
  , newStore
  , execute
  ) where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.ByteString.Char8 qualified as BC

import KV.Command

newtype Store = Store (TVar (Map ByteString ByteString))

newStore :: IO Store
newStore = Store <$> newTVarIO Map.empty

execute :: Store -> Command -> STM Reply
execute store@(Store tv) =
  \case
    Ping -> pure Pong
    Get k -> maybe Nil Value . Map.lookup k <$> readTVar tv
    Set k v -> Ok <$ modifyTVar' tv (Map.insert k v)
    Del k -> do
      m <- readTVar tv
      if Map.member k m
        then Count 1 <$ writeTVar tv (Map.delete k m)
        else pure (Count 0)
    Incr k -> incrBy 1 k
    IncrBy k sn -> case BC.readInt sn of
      Nothing                      -> pure errNotInt
      Just(_, s) | not (BC.null s) -> pure errNotInt
      Just(n, _)                   -> incrBy n k
    Decr k -> incrBy (-1) k
    DecrBy k sn -> case BC.readInt sn of
      Nothing                      -> pure errNotInt
      Just(_, s) | not (BC.null s) -> pure errNotInt
      Just(n, _)                   -> incrBy (-n) k
    MSet args -> case pairwise args of
      Just pairs@(_ : _) -> Ok <$ mapM_ (execute store . uncurry Set) pairs
      _ -> pure (Error "ERR wrong number of arguments for 'mset' command")
    MSetNX args -> case pairwise args of
      Just pairs@(_ : _) -> do
        m <- readTVar tv
        if all (\k -> not (Map.member k m)) (map fst pairs)
          then Count 1 <$ execute store (MSet args)
          else pure (Count 0)
      _ -> pure (Error "ERR wrong number of arguments for 'msetnx' command")
    MGet [] -> pure (Error "ERR wrong number of arguments for 'mset' command")
    MGet args -> Array <$> (mapM (execute store . Get) args)
  where
    incrBy :: Int -> ByteString -> STM Reply
    incrBy amount k = do
      m <- readTVar tv
      let prev = fromMaybe "0" (Map.lookup k m)
      case BC.readInt prev of
        Nothing                      -> pure errNotInt
        Just(_, s) | not (BC.null s) -> pure errNotInt
        Just (v, _)                  -> Count (v + amount) <$ modifyTVar' tv (Map.insert k (intToBytestring (v + amount)))
    
    pairwise :: [ByteString] -> Maybe [(ByteString, ByteString)]
    pairwise = \case
      []           -> Just []
      k : v : rest -> ((k, v) :) <$> pairwise rest
      [_]          -> Nothing

intToBytestring :: Int -> BC.ByteString
intToBytestring = BC.pack . show

-- errWrongType :: Reply
-- errWrongType = Error "WRONGTYPE Operation against a key holding the wrong kind of value"

errNotInt :: Reply
errNotInt = Error "ERR value is not an integer or out of range"