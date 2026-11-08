{- | The shared key-value store.

All state lives in one 'TVar', and every operation is an 'STM' action
rather than an 'IO' action. That means callers decide where transactions
begin and end: @atomically (execute s a >> execute s b)@ runs both
commands as a single atomic unit, with no locks in sight.
-}
module KV.Store (
    Store,
    newStore,
    execute,
)
where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe
import Data.Sequence (Seq)

-- import Data.Sequence qualified as Seq
import KV.Command

data StoreValue
    = StoreString !ByteString
    | StoreList !(Seq ByteString)
    deriving stock (Eq, Show)

newtype Store = Store (TVar (Map ByteString StoreValue))

newStore :: IO Store
newStore = Store <$> newTVarIO Map.empty

execute :: Store -> Command -> STM Reply
execute store@(Store tv) =
    \case
        Ping Nothing -> pure Pong
        Ping (Just str) -> pure (Value str)
        Get k -> do
            v <- lookupString k <$> readTVar tv
            case v of
                Right Nothing -> pure Nil
                Right (Just s) -> pure (Value s)
                Left e -> pure e
        Set k v -> Ok <$ modifyTVar' tv (Map.insert k (StoreString v))
        Del k -> do
            m <- readTVar tv
            if Map.member k m
                then Count 1 <$ writeTVar tv (Map.delete k m)
                else pure (Count 0)
        Incr k -> incrBy 1 k
        IncrBy k sn -> case BC.readInt sn of
            Nothing -> pure errNotInt
            Just (_, s) | not (BC.null s) -> pure errNotInt
            Just (n, _) -> incrBy n k
        Decr k -> incrBy (-1) k
        DecrBy k sn -> case BC.readInt sn of
            Nothing -> pure errNotInt
            Just (_, s) | not (BC.null s) -> pure errNotInt
            Just (n, _) -> incrBy (-n) k
        MSet args -> case pairwise args of
            Just pairs@(_ : _) -> Ok <$ mapM_ (execute store . uncurry Set) pairs
            _ -> pure (Error "ERR wrong number of arguments for 'mset' command")
        MSetNX args -> case pairwise args of
            Just pairs@(_ : _) -> do
                m <- readTVar tv
                if all ((\k -> not (Map.member k m)) . fst) pairs
                    then Count 1 <$ execute store (MSet args)
                    else pure (Count 0)
            _ -> pure (Error "ERR wrong number of arguments for 'msetnx' command")
        MGet [] -> pure (Error "ERR wrong number of arguments for 'mget' command")
        MGet args -> do
            vs <- mapM (execute store . Get) args
            pure (Array (map (\e -> case e of Error _ -> Nil; x -> x) vs))
        GetSet k v -> do
            prev <- execute store (Get k)
            result <- case prev of
                Error _ -> pure errWrongType
                _ -> prev <$ execute store (Set k v)
            pure result
  where
    incrBy :: Int -> ByteString -> STM Reply
    incrBy amount k = do
        m <- readTVar tv
        case lookupString k m of
            Left err -> pure err
            Right prev -> case BC.readInt (fromMaybe "0" prev) of
                Nothing -> pure errNotInt
                Just (_, s) | not (BC.null s) -> pure errNotInt
                Just (v, _) ->
                    Count (v + amount) <$ modifyTVar' tv (Map.insert k (StoreString (intToBytestring (v + amount))))

    pairwise :: [ByteString] -> Maybe [(ByteString, ByteString)]
    pairwise = \case
        [] -> Just []
        k : v : rest -> ((k, v) :) <$> pairwise rest
        [_] -> Nothing

    lookupString :: ByteString -> Map ByteString StoreValue -> Either Reply (Maybe ByteString)
    lookupString k m = case Map.lookup k m of
        Nothing -> Right Nothing
        Just (StoreString s) -> Right (Just s)
        Just (StoreList _) -> Left errWrongType
    -- lookupList :: ByteString -> Map ByteString StoreValue -> Either Reply (Seq ByteString) -- missing key = Seq.empty
    -- lookupList k m = case Map.lookup k m of
    --     Nothing -> Right Seq.empty
    --     Just (StoreList l) -> Right l
    --     Just (StoreString _) -> Left errWrongType

    intToBytestring :: Int -> BC.ByteString
    intToBytestring = BC.pack . show

errWrongType :: Reply
errWrongType = Error "WRONGTYPE Operation against a key holding the wrong kind of value"

errNotInt :: Reply
errNotInt = Error "ERR value is not an integer or out of range"