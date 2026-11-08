# kv

A tiny Redis-like key-value server, as a vehicle for learning Haskell.

```
cabal build                 # build everything
cabal test                  # hspec + QuickCheck
cabal run kv                # listens on :6380 (pass a port to override)
ncat localhost 6380         # then type: SET a 1 / GET a / DEL a / PING
cabal repl                  # GHCi with the library loaded
```

## Layout

| Module          | What it is                                                     |
|-----------------|----------------------------------------------------------------|
| `KV.Command`    | Pure protocol code: `Command`/`Reply` ADTs, parse and render.   |
| `KV.Store`      | State: one `TVar (Map ByteString value)`; ops are `STM`. The value starts as a plain `ByteString` and grows to "string or list" in exercise 4. |
| `KV.Server`     | `IO` shell: accept loop, one green thread per connection.      |

The split is intentional: a pure core, an `STM` layer for shared state, and a
thin `IO` edge. Keep it that way as you add features.

## Exercises (roughly in order)

Exact command semantics for each exercise are in [COMMANDS.md](COMMANDS.md).

1. **Explore in GHCi.** `cabal repl` loads every module but only puts the
   first (`KV.Command`) in scope, so start with `:m + *KV.Store *KV.Server`
   (`*` means the module's full top level, including its imports). Then try
   `:t execute`, `:i Reply`, `parseCommand "get x"`, and `:k Map`. After
   editing code, `:r` reloads. Get used to asking the compiler.
2. **`INCR key`.** Return an error if the value isn't an integer. Start with
   `BC.readInt`, then make it as strict as Redis (COMMANDS.md lists inputs
   `readInt` accepts but Redis rejects) and detect overflow. Add a QuickCheck
   property: n INCRs from empty gives n.
3. **`MSET k1 v1 k2 v2 ...` and `GETSET`.** Notice you can build these by
   composing existing `STM` actions inside a single `atomically`.
4. **`BLPOP key timeout`.** Add list values and a pop that blocks until an
   element exists. In STM that is just `retry`. Wrap it in
   `System.Timeout.timeout` (or race it with `registerDelay`). This is the
   exercise where STM really shows what it can do. Two things to watch:
   - The timeout lives in `IO`, so `BLPOP` is the first command that doesn't
     fit `execute :: Store -> Command -> STM Reply` on its own. Let the server
     layer handle the waiting; keep the pop itself in `STM`.
   - Redis's timeout `0` means "wait forever", but `timeout 0` in Haskell
     gives up immediately (and a negative value waits forever). The Redis
     timeout is fractional seconds; `timeout` takes microseconds.
5. **Expiry: `EXPIRE` / `TTL`.** Store an expiry with each value. Do lazy
   expiry on read, plus a background reaper thread started with
   `withAsync` from the `async` package (it's already a dependency). STM
   can't read the clock, so `execute` will need the current time passed in.
   If you plan to do persistence (exercise 9), read COMMANDS.md on which
   clock to use first.
6. **Speak RESP.** Replace the line protocol with the Redis wire protocol so
   `redis-cli -p 6380` and `redis-benchmark` work (on Fedora these are
   `valkey-cli` and `valkey-benchmark`; see COMMANDS.md, exercise 7). Drop the
   `Handle` and parse raw `recv` chunks incrementally (`attoparsec` is the
   usual tool; add it to `kv.cabal`). Use `ByteString.Builder` for output.
7. **Measure, then shard.** Run `redis-benchmark`, run the server with
   `cabal run kv -- 6380 +RTS -s`, and look at allocation and GC. Then split
   the single `TVar` into N shards (or try `stm-containers`, a new
   dependency) and compare. Multi-key commands still need to be atomic
   across shards; notice how little STM makes you change for that. Watch for
   laziness: why does `Data.Map.Strict` matter here?
8. **Graceful shutdown.** On SIGINT and SIGTERM, stop accepting, cancel client
   threads, and exit cleanly. This is where async exceptions and `bracket`
   stop being theoretical. GHC already delivers SIGINT (Ctrl-C) to the main
   thread as a `UserInterrupt` exception, but SIGTERM kills the process
   unless you install a handler (`System.Posix.Signals` from the `unix`
   package, a new dependency). The server doesn't currently keep track of
   its client threads, so you'll need to.
9. **Persistence or replication.** Append-only log, snapshotting, or a
   follower that tails the leader. Pick your poison.
