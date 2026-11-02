-- | The TCP front end: one green thread per client, like a goroutine per conn.
module KV.Server (runServer) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket, bracketOnError, displayException)
import Control.Monad (forever, unless)
import Data.ByteString.Char8 qualified as BC
import Data.List.NonEmpty (NonEmpty (..))
import Network.Socket
import System.IO

import KV.Command
import KV.Store

runServer :: ServiceName -> Store -> IO ()
runServer port store = bracket (listenOn port) close $ \sock -> forever $ do
    (conn, peer) <- accept sock
    logLine ("connect " <> show peer)
    -- forkFinally is Go's `go func() { defer conn.Close(); ... }()`. The
    -- handler runs whether serve returns normally or dies with an exception.
    forkFinally (serve store conn) $ \result -> do
        close conn
        logLine
            ( either
                (\e -> "error " <> show peer <> ": " <> displayException e)
                (const ("disconnect " <> show peer))
                result
            )

listenOn :: ServiceName -> IO Socket
listenOn port = do
    let hints = defaultHints{addrFlags = [AI_PASSIVE], addrSocketType = Stream}
    addr :| _ <- getAddrInfo (Just hints) Nothing (Just port)
    -- bracketOnError closes the socket only if setup fails partway through.
    bracketOnError (openSocket addr) close $ \sock -> do
        setSocketOption sock ReuseAddr 1
        bind sock (addrAddress addr)
        listen sock 1024
        pure sock

-- | Serve one client: read a line, run it, write the reply, repeat.
serve :: Store -> Socket -> IO ()
serve store conn = bracket (socketToHandle conn ReadWriteMode) hClose $ \h -> do
    hSetBuffering h LineBuffering
    let loop = do
            eof <- hIsEOF h
            unless eof $ do
                line <- BC.hGetLine h
                reply <- case parseCommand line of
                    Left err -> pure (Error err)
                    Right cmd -> atomically (execute store cmd)
                BC.hPutStrLn h (renderReply reply)
                loop
    loop

logLine :: String -> IO ()
logLine = hPutStrLn stderr
