module Main (main) where

import Control.Concurrent.STM (atomically)
import Control.Monad
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import KV.Command
import KV.Store
import Test.Hspec
import Test.QuickCheck

main :: IO ()
main = hspec $ do
    describe "parseCommand" $ do
        it "parses GET" $
            parseCommand "GET foo" `shouldBe` Right (Get "foo")
        it "is case-insensitive in the command name" $
            parseCommand "set k v" `shouldBe` Right (Set "k" "v")
        it "tolerates the \\r that telnet and nc send" $
            parseCommand "PING\r" `shouldBe` Right (Ping Nothing)
        it "rejects the wrong number of arguments" $
            parseCommand "GET" `shouldSatisfy` isLeft
        it "round-trips with renderCommand" $ property $ \(AnyCommand c) ->
            parseCommand (renderCommand c) === Right c

    describe "Store" $ do
        it "returns what was set" $ property $ \(Token k) (Token v) -> ioProperty $ do
            store <- newStore
            r <- atomically $ execute store (Set k v) >> execute store (Get k)
            pure (r === Value v)
        it "reports how many keys DEL removed" $ do
            store <- newStore
            _ <- atomically $ execute store (Set "k" "v")
            rs <- mapM (atomically . execute store) [Del "k", Del "k", Get "k"]
            rs `shouldBe` [Count 1, Count 0, Nil]
        it "increments when using INCR" $ property $ \(Positive n) -> ioProperty $ do
            let expected = (BC.pack . show) n
            store <- newStore
            rs <- replicateM n (atomically $ execute store (Incr "k"))
            actual <- atomically $ execute store (Get "k")
            pure (rs === map Count [1 .. n] .&&. actual === Value expected)
        forM_ badInts $ \bad ->
            it ("refuses to incr " <> show bad) $ do
                store <- newStore
                _ <- atomically $ execute store (Set "k" bad)
                r <- atomically $ execute store (Incr "k")
                r `shouldSatisfy` isError
                v <- atomically $ execute store (Get "k")
                v `shouldBe` Value bad
        it "decrements when using DECR" $ property $ \(Positive n) (Positive initial) -> ioProperty $ do
            let expected = (BC.pack . show) (initial - n)
            store <- newStore
            _ <- atomically $ execute store (Set "k" ((BC.pack . show) initial))
            rs <- replicateM n (atomically $ execute store (Decr "k"))
            actual <- atomically $ execute store (Get "k")
            pure (rs === map Count [initial - 1, initial - 2 .. initial - n] .&&. actual === Value expected)
        forM_ badInts $ \bad ->
            it ("refuses to decr " <> show bad) $ do
                store <- newStore
                _ <- atomically $ execute store (Set "k" bad)
                r <- atomically $ execute store (Decr "k")
                r `shouldSatisfy` isError
                v <- atomically $ execute store (Get "k")
                v `shouldBe` Value bad
        it "increments when using INCRBY" $ property $ \(Positive n) (Positive initial) -> ioProperty $ do
            let expected = (BC.pack . show) (initial + n)
            store <- newStore
            _ <- atomically $ execute store (Set "k" ((BC.pack . show) initial))
            r <- atomically $ execute store (IncrBy "k" ((BC.pack . show) n))
            actual <- atomically $ execute store (Get "k")
            pure (r === Count (initial + n) .&&. actual === Value expected)
        forM_ badInts $ \bad ->
            it ("refuses to incrby " <> show bad) $ do
                store <- newStore
                _ <- atomically $ execute store (Set "k" "0")
                r <- atomically $ execute store (IncrBy "k" bad)
                r `shouldSatisfy` isError
                v <- atomically $ execute store (Get "k")
                v `shouldBe` Value "0"
        it "decrements when using DECRBY" $ property $ \(Positive n) (Positive initial) -> ioProperty $ do
            let expected = (BC.pack . show) (initial - n)
            store <- newStore
            _ <- atomically $ execute store (Set "k" ((BC.pack . show) initial))
            r <- atomically $ execute store (DecrBy "k" ((BC.pack . show) n))
            actual <- atomically $ execute store (Get "k")
            pure (r === Count (initial - n) .&&. actual === Value expected)
        forM_ badInts $ \bad ->
            it ("refuses to decrby " <> show bad) $ do
                store <- newStore
                _ <- atomically $ execute store (Set "k" "0")
                r <- atomically $ execute store (DecrBy "k" bad)
                r `shouldSatisfy` isError
                v <- atomically $ execute store (Get "k")
                v `shouldBe` Value "0"

        it "works when performing mset" $ property $ \(Token k) (Token v) (rest :: [(Token, Token)]) -> ioProperty $ do
            let pairs = (k, v) : [(k', v') | (Token k', Token v') <- rest]
                args = concat [[a, b] | (a, b) <- pairs]
                final = Map.fromList pairs
                keys = map fst pairs
            store <- newStore
            r <- atomically $ execute store (MSet args)
            rs <- atomically $ execute store (MGet keys)
            let expected = Array [maybe Nil Value (Map.lookup key final) | key <- keys]
            pure (r === Ok .&&. rs === expected)

        it "works when performing msetnx" $ property $ \(Token k) (Token v) (rest :: [(Token, Token)]) -> ioProperty $ do
            let args = k : v : concat [[k', v'] | (Token k', Token v') <- rest]
            store <- newStore
            r <- atomically $ execute store (Set k "")
            r2 <- atomically $ execute store (MSetNX args)
            pure (r === Ok .&&. r2 === Count 0)

        it "sets and gets with GETSET" $ property $ \(Token k) (Token v) (Token v2) -> ioProperty $ do
            store <- newStore
            _ <- atomically $ execute store (Set k v)
            r <- atomically $ execute store (GetSet k v2)
            r2 <- atomically $ execute store (Get k)
            pure (r === Value v .&&. r2 === Value v2)

isError :: Reply -> Bool
isError = \case
    Error _ -> True
    _ -> False

badInts :: [BC.ByteString]
badInts = ["abc", "12abc", "1 2", "01", "+12", "-012", "-0"]

newtype Token = Token {unToken :: BC.ByteString}
    deriving stock (Show)

instance Arbitrary Token where
    arbitrary = Token . BC.pack <$> listOf1 (elements (['a' .. 'z'] <> ['0' .. '9']))
    shrink (Token t) = [Token (BC.pack s) | s <- shrink (BC.unpack t), not (null s)]

-- | A wrapper so the Arbitrary instance isn't an orphan on 'Command'.
newtype AnyCommand = AnyCommand Command
    deriving stock (Show)

instance Arbitrary AnyCommand where
    arbitrary :: Gen AnyCommand
    arbitrary =
        AnyCommand
            <$> oneof
                [ pure (Ping Nothing),
                  Ping <$> Just <$> token,
                  Get <$> token,
                  Set <$> token <*> token,
                  Del <$> token,
                  Incr <$> token,
                  IncrBy <$> token <*> int,
                  Decr <$> token,
                  DecrBy <$> token <*> int,
                  MSet <$> listOf1 token,
                  MSetNX <$> map unToken <$> (flatten <$> arbitrary),
                  MGet <$> listOf1 token,
                  GetSet <$> token <*> token
                ]
      where
        token = unToken <$> arbitrary
        int = BC.pack . show <$> arbitrary @Int
        flatten :: [(Token, Token)] -> [Token]
        flatten xs = [x | (y, z) <- xs, x <- [y, z]]
