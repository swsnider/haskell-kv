module Main (main) where

import System.Environment (getArgs)

import KV.Server (runServer)
import KV.Store (newStore)

main :: IO ()
main = do
  port <- getArgs >>= \case
    [p] -> pure p
    _ -> pure "6380"
  store <- newStore
  putStrLn ("kv listening on :" <> port)
  runServer port store
