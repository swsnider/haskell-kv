# Redis command reference (for the exercises)

Just enough Redis semantics to implement each exercise faithfully. The
authoritative docs are at <https://redis.io/docs/latest/commands/>; each
command has its own page there.

Notation: `[x]` means optional, `x ...` means one or more. Replies are written
as you'd see them in `redis-cli`: `OK` is a simple string, `"v"` a bulk string,
`(nil)` the null bulk, `(integer) n` an integer, and numbered lines an array.

## The data model

- **The keyspace** is one flat map from key to value. Keys and values are
  binary-safe byte strings, and there are no namespaces or nesting.
- **Each value has a type**: string, list, hash, set, sorted set and so on.
  These exercises only need **strings** and **lists**.
- **Numbers are strings.** `INCR` parses the stored string, does the
  arithmetic, and stores the result back as a string.
- **A command against the wrong type** fails with this exact text:
  `WRONGTYPE Operation against a key holding the wrong kind of value`.
  Commands that don't care about type, such as `DEL`, `EXISTS`, `EXPIRE` and
  plain `SET`, work on keys of any type.
- **Empty collections don't exist.** When a pop removes a list's last
  element, the key is deleted. A missing key and an empty list are
  indistinguishable, and list commands treat a missing key as an empty list.
- **Every command is atomic.** No other client ever sees a command half done.
  Real Redis gets this by being single-threaded. You get it from STM.

---

## Already implemented (check that yours matches)

### `PING [message]`
- No argument: replies `PONG`.
- With an argument: replies the argument as a bulk string.

### `GET key`
- The value as a bulk string, or `(nil)` if the key doesn't exist.
- `WRONGTYPE` if the key holds a list.

### `SET key value`
- Always replies `OK`.
- Overwrites any existing value, **of any type**: `SET` on a list key replaces
  the list with a string.
- **Clears any expiry** on the key (see exercise 5).
- Real `SET` takes options, which are good optional extras:
  - `NX`: only set if the key doesn't exist.
  - `XX`: only set if it does.
  - `GET`: reply with the old value.
  - `EX seconds` / `PX milliseconds`: set an expiry at the same time.
  - `KEEPTTL`: don't clear the existing expiry.

  When an `NX` or `XX` condition fails, the reply is `(nil)` instead of `OK`.

### `DEL key [key ...]`
- **Takes multiple keys.** Replies `(integer)` with the number of keys that
  actually existed and were removed. Missing keys are silently ignored.

### `EXISTS key [key ...]` (small extra)
- `(integer)` count of the given keys that exist. A key repeated in the
  arguments is counted each time it appears.

---

## Exercise 2: counters

### `INCR key`
- Adds 1 and replies with the **new** value as `(integer)`.
- A missing key counts as `0`, so the first `INCR` creates it and replies `1`.
- The value must be the canonical text of a signed 64-bit integer. Redis's
  parser is strict:
  - It rejects `"12abc"`, `" 12"`, `"1.5"` and `""`.
  - It also rejects a leading `+` (`"+5"`) and leading zeros (`"012"`).
    `BC.readInt` accepts both, so those make good test cases.

  On a bad value: `ERR value is not an integer or out of range`.
- Overflowing past `maxBound` fails with
  `ERR increment or decrement would overflow`, and the value is left unchanged.
- `WRONGTYPE` if the key holds a list.
- **Keeps** any existing expiry on the key.

### Related, if you want them
- `DECR key`: subtract 1.
- `INCRBY key n` / `DECRBY key n`: add or subtract `n`, where `n` must itself
  be a valid integer.

---

## Exercise 3: multi-key and read-modify-write

### `MSET key value [key value ...]`
- Sets every pair **atomically**: no client ever sees some keys updated and
  others not.
- Always replies `OK`. It can't fail, except for an odd number of arguments,
  which gives `ERR wrong number of arguments for 'mset' command`.
- If a key appears twice, the last value wins.
- Like `SET`, it overwrites any type and clears expiries.

### `MGET key [key ...]`
- Replies with an **array** containing one entry per key, in argument order:
  the value, or `(nil)` if the key is missing.
- A key holding a list gives `(nil)` in its slot, **not** an error.
- `MGET` can't be expressed with your current `Reply` type, so you'll need
  to extend it.

### `MSETNX key value [key value ...]`
- Sets all of the pairs **only if none of the keys exist**. All or nothing.
- Replies `(integer) 1` if it set them and `(integer) 0` if it set nothing.
- This is a good test of whether you're composing STM actions or taking
  shortcuts.

### `GETSET key value`
- Atomically sets the new value and replies with the **old** value, or
  `(nil)` if there wasn't one.
- `WRONGTYPE` if the old value is a list. In that case nothing is set.
- Clears any expiry.
- Deprecated since Redis 6.2 in favour of `SET key value GET`, which does
  the same thing. Implement whichever you like, or both.

---

## Exercise 4: lists and blocking

A list is an ordered sequence of byte strings, with cheap pushes and pops at
both ends. In Redis terms the head is the "left" end and the tail is the
"right" end. Your store's value type has to grow from "just a `ByteString`"
to "a string or a list". `Data.Sequence` gives you O(1) at both ends.

### `LPUSH key element [element ...]` / `RPUSH key element [element ...]`
- Pushes onto the head (`L`) or the tail (`R`), creating the list if the key
  doesn't exist.
- Replies `(integer)` with the list's **new length**.
- Multiple elements are pushed **one at a time, left to right**. So
  `LPUSH k a b c` leaves the list as `c b a`, and `RPUSH k a b c` leaves it as
  `a b c`.
- `WRONGTYPE` if the key holds a string.

### `LPOP key [count]` / `RPOP key [count]`
- Without `count`: removes and replies with one element, or `(nil)` if the
  key is missing.
- With `count`: an array of up to `count` elements, or `(nil)` if the key is
  missing.
- If that empties the list, **delete the key**.

### `LLEN key`
- `(integer)` length. `0` for a missing key.

### `LRANGE key start stop` (useful for testing and debugging)
- An array of the elements from `start` to `stop`, **both inclusive**.
- **Negative indices** count from the end: `-1` is the last element. So
  `LRANGE k 0 -1` returns the whole list.
- **Out-of-range indices** are clamped, not errors. If `start` is past the
  end, or past `stop`, the result is an empty array.

### `BLPOP key [key ...] timeout` / `BRPOP ...`
- Checks the keys **in argument order** and pops from the head (`BLPOP`) or
  tail (`BRPOP`) of the **first non-empty list**.
- Replies with a 2-element array of the key it popped from and the element:
  ```
  1) "jobs"
  2) "job-42"
  ```
- If every list is empty or missing, the client **blocks** until another
  client pushes to one of the keys, or until the timeout passes.
- `timeout` is in seconds and may be fractional (`0.5`). `0` means wait
  forever.
- On timeout the reply is a null array, which shows as `(nil)`.
- Fairness: when several clients block on the same key, Redis serves them
  **in the order they started waiting**. Plain STM `retry` wakes up every
  waiting thread and lets them race, which doesn't give you that order. Decide
  whether you care. Getting first-come-first-served order with STM is a good
  stretch goal.
- To try it, run `BLPOP q 0` in one `redis-cli` and `RPUSH q hi` in another.

---

## Exercise 5: expiry

A key can carry an absolute expiry time. Once that time passes, the key
behaves **exactly as if it doesn't exist** for every command, including
`EXISTS`, `TTL` and `INCR` (which then starts from 0).

### `EXPIRE key seconds` / `PEXPIRE key milliseconds`
- Sets the key's expiry to now plus the duration.
- Replies `(integer) 1` if the expiry was set and `(integer) 0` if the key
  doesn't exist.
- Calling it again replaces the previous expiry.
- A zero or negative duration deletes the key immediately and replies `1`.
- Optional flags:
  - `NX`: only if the key has no expiry.
  - `XX`: only if it has one.
  - `GT` / `LT`: only if the new expiry is later or earlier than the current
    one.

  When a flag's condition isn't met, the reply is `0`.

### `TTL key` / `PTTL key`
- Remaining time to live in seconds (`TTL`) or milliseconds (`PTTL`), as an
  integer.
- `-1` if the key exists but has no expiry.
- `-2` if the key doesn't exist.

### `PERSIST key`
- Removes the expiry.
- `(integer) 1` if there was one to remove. `0` if the key is missing or had
  no expiry.

### Which commands affect an expiry
- **Clear it:** `SET`, `GETSET`, `MSET`, and any other command that
  *replaces* the value.
- **Keep it:** `INCR`/`DECR`, `LPUSH`/`RPUSH`/pops, and any other command that
  *modifies* the value in place.
- **Remove it with the key:** `DEL`.

### How Redis does it (a design hint)
Redis expires keys in two ways at once:
1. **Lazily:** any command that touches a key first checks whether it has
   expired and, if so, deletes it.
2. **Actively:** about 10 times a second, it samples a few keys that have
   expiries and deletes the expired ones. If more than 25% of the sample had
   expired, it samples again immediately.

Lazy expiry alone is always *correct*, but it leaks memory for keys nobody
reads. The active pass exists only to reclaim memory. In your version, the
lazy check belongs inside the STM transaction and the active pass is the
background thread.

Use a monotonic clock for durations: `GHC.Clock.getMonotonicTime`. Note that
STM transactions can't do IO, so they can't read the clock themselves. Read
the time before calling `atomically` and pass it in.

---

## Exercise 6: protocol

See the RESP notes from our earlier conversation, or
<https://redis.io/docs/latest/develop/reference/protocol-spec/>. In short:
- **Requests** are arrays of bulk strings.
- **Replies** use `+` (simple string), `-` (error), `:` (integer), `$` (bulk
  string, `$-1` for nil) and `*` (array).
- Every line ends with `\r\n`.

Error replies should start with an upper-case code word (`ERR`, `WRONGTYPE`),
because clients and test suites look at that word.

---

## Exercise 7: benchmarking tools

Fedora replaced Redis with **Valkey**, a compatible fork, so install it with
`sudo dnf install valkey`. The tools are called `valkey-cli` and
`valkey-benchmark`. The `valkey-compat-redis` package also installs them under
the `redis-*` names.

```
valkey-benchmark -p 6380 -t set,get,incr,lpush,lpop -n 100000 -c 50
valkey-benchmark -p 6380 -t set,get -n 1000000 -c 50 -P 16   # pipelined
```
- `-c`: the number of concurrent connections.
- `-P`: the number of commands pipelined per round trip. This is what
  stresses an incremental parser.
- `-r 100000`: use random keys instead of a single hot key. Compare a hot key
  and random keys before and after sharding your `TVar`.

The benchmark sends `CONFIG GET` when it starts. An error reply should only
produce a warning.

---

## Exercise 8: shutdown

Real Redis shuts down on `SIGTERM`/`SIGINT` or the `SHUTDOWN` command. It
stops accepting connections, finishes the commands in progress, persists if
persistence is configured, and exits. Clients that are blocked (`BLPOP`) are
disconnected. You don't need to implement `SHUTDOWN` itself. The signal path
is the interesting part.

---

## Exercise 9: persistence and replication

### Append-only file (AOF)
- Append every **write** command to a file, in RESP format, after it
  succeeds.
- On startup, replay the file to rebuild the store.
- Redis offers three `fsync` policies, a classic durability-versus-throughput
  trade-off:
  - `always`: fsync after every write.
  - `everysec`: fsync once a second.
  - `no`: let the OS decide.
- Redis rewrites **relative** commands as **absolute** ones before logging
  them. For example, `EXPIRE k 10` is logged as `PEXPIREAT k <unix-ms>`, so
  replaying the log later doesn't restore an expiry 10 seconds from replay
  time. Ask yourself which of your other commands aren't deterministic on
  replay.
- Over time the log grows without limit. Redis periodically compacts it by
  writing the minimal set of commands that recreates the current state.

### Snapshot (RDB)
- A point-in-time dump of the whole keyspace in a binary format.
- Redis has to `fork()` to get a consistent snapshot without stopping writes.
  You don't: your `Map` is immutable, so `readTVarIO` gives you a consistent
  snapshot for free, and you can serialise it on another thread while writes
  carry on. This is one of the nicest demonstrations of persistent data
  structures you'll find.

### Replication (simplified)
Real Redis replication (`REPLICAOF`, `PSYNC`) is involved. A reasonable
simplified version:
1. A follower connects to the leader and receives a snapshot.
2. It then receives a stream of every write command the leader runs, in
   order, which is the same stream as the AOF.
3. The follower applies them. It accepts reads and rejects writes with
   `-READONLY You can't write against a read only replica.`

The hard parts are the distributed-systems parts: the follower falling behind
and reconnecting, and which writes are lost if the leader dies.
