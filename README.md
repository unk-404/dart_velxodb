# velxodb

An embedded, pure-Dart document database.

It is built local-first: the default backend is a memory-mapped, log-structured
engine that answers point reads from RAM and range scans without copying
documents. The same immutable segments can also be served from object storage,
because the storage format never assumes files — that is a property of the
design, not a separate adapter.

## Why it is fast

**Local I/O is the main path.**

- Segments are memory-mapped, not read into the heap. A 1e6-document database
  (157 MB) opens in **38 ms** with a **27 MB** resident-set increase.
- Point reads are bloom filter → binary search → zero-copy `DocView`. A 1e6-doc
  database answers hot reads at **p50 1.5 µs**.
- The memtable keeps a hash index for lookups and a skip list for ordered range
  scans, so a 1k-key window over 50k entries costs **~17.5M docs/s**.
- Writes go through a framed, checksummed WAL; a document and its index entries
  commit in one frame. Import of 1e6 docs runs at **355k docs/s** on real files.

**The format never copies a document.**

- `VXS` has stable field ids, delta-encoded keys and direct field offsets.
  Reading three fields or projecting five allocates nothing.
- Encoding a 130 B chat document runs at **~550 MB/s**; CRC-32C checks
  segments and indexes at **~900 MB/s**.

**The mutable surface is tiny.**

- Segments are immutable; the manifest is the only object replaced on commit.
  This is what makes crash recovery a commit order instead of a transaction log
  protocol, and it is also why the same bytes work on a filesystem or an object
  store.
- Compaction rewrites segments and drops tombstones; the manifest swap is the
  commit point.

## Storage is I/O-agnostic, by construction

```
query/   collections, cursors, indexes, planner, schema, migrations, graph
   ↓
storage/ segments · manifest · memtable · WAL · arena
   ↓            ↙                    ↘
serde/     local files (dart:io + mmap)   object store (get/put/list)
```

Both backends share the block, WAL, segment and manifest codecs. A segment
written by the local engine opens unchanged in the object-store engine and vice
versa — this is covered by a compatibility test, not just claimed. Manifest
placement follows each backend's atomicity model: two alternating slot files on
disk (portable atomic replacement), a single replaceable object on object stores
(where PUT is atomic).

- **Local backend**: synchronous, `RandomAccessFile`, mmap for reads, fsync
  policies, batching. This is the default and the fastest option.
- **Object-store backend**: async; segments and the manifest are objects, write
  batches are small WAL objects, segments are fetched lazily through an LRU
  cache. The core ships the `ObjectStore` interface and an in-repo simulated
  implementation; concrete cloud adapters are integrator code, not core code.
- Choosing a backend never changes the document format, the segment format or
  the query API.

Object storage also inherits the format's request shape:

| Operation | Requests |
| --- | --- |
| put/delete batch | 1 PUT |
| flush | 1 PUT segment + 1 PUT manifest + 1 batch DELETE |
| open | 1 GET manifest + 1 LIST + K GET (unflushed WAL only) |
| first read of a segment | 1 GET, then served from the LRU cache |
| compaction | S GET + 1 PUT segment + 1 PUT manifest + 1 batch DELETE |

A 200k-document import over the object-store engine issues **412 requests**, a
120k-change churn issues **123**, and a reopen issues **2** with no segment
download. The full breakdown is in the benchmark below.

## What the engine guarantees

- **Atomic writes.** One document and every derived entry (secondary indexes,
  reference indexes, full-text postings, graph edges) commit in a single WAL
  frame.
- **Multi-document transactions.** `db.transactionSync` buffers every write,
  makes it visible to point reads inside the block, and commits the whole set as
  one frame; an exception applies nothing. Single writer, no nesting, no MVCC —
  scans do not see uncommitted writes.
- **Single-writer lock.** Opening the same directory twice fails immediately, so
  two processes cannot interleave writes into one log.
- **Crash recovery.** WAL replay, then the manifest as the commit point. A frame
  torn by a crash is dropped whole; a committed transaction never splits.
- **Durability tiers.** `Durability.always` fsyncs every WAL frame (a batch or a
  transaction is one frame, so one fsync covers the group); the default
  `Durability.batched` fsyncs on flush, close and `db.sync()`, which is the
  group-commit point; `Durability.none` leaves durability to the caller.
- **Bounded memory and read amplification.** The memtable auto-flushes at 64 MB
  and segments auto-compact at 4, both configurable on open; the write that
  crosses a threshold pays for the work.
- **Integrity check.** `db.checkSync(deep: true)` verifies the manifest, every
  segment block (CRC plus document parse), orphan segment files, and every
  secondary/full-text posting against its document. It is read-only.
- **Typed errors.** `VelxoLockedException`, `VelxoCorruptException`,
  `VelxoClosedException`, `VelxoConflictException`, `VelxoNotFoundException`.
- **Graceful shutdown.** `db.close(flush: true)` writes a segment so the next
  open reads the manifest instead of replaying the log.

Not yet provided: the Web database/query facade, the Mongo-style facade,
storage-format migration, encryption, and geo/vector.

### Concurrency contract

- One open database belongs to one isolate. Reads and writes are synchronous
  and single-writer; there is no shared memory between isolates.
- `VelxoWorker.open(path)` runs the only `VelxoDatabase` in a dedicated worker
  isolate and exposes an async RPC facade (`put`, `get`, `delete`, `page`,
  `flush`, `check`, `waitForMaintenance`, `close`). Requests from any number of
  client isolates are queued and executed one at a time by the worker, so the
  single-writer contract holds while callers stay concurrent. Values cross the
  boundary as copies, so zero-copy reads apply inside the worker.
- `VelxoDatabase.openSync(path, readOnly: true)` replays the WAL without
  truncating it and rejects every write (`VelxoReadOnlyException`), including
  catalog changes. A read-only open takes a shared directory lock, so many
  readers can coexist; a writable open is exclusive.
- `db.backupSync(targetDirectory)` flushes first and copies a consistent file
  set into an empty target; `copyDatabase(source, target)` restores it. Both work
  at the storage-directory level, so the same code backs local and future
  object-store targets. Backup is a full copy, not incremental.
- Do not open the same path directly in the same process while a worker owns it:
  POSIX `fcntl` locks are process-wide, so a direct open in another isolate is
  not detected. Across processes the OS lock still applies. The worker client
  rejects a second worker for the same path in one isolate.
- `VelxoDatabase.openSync(deferredMaintenance: true)` moves the flush/compaction
  triggered by a threshold crossing off the write call: the write returns first,
  the segment is built on a `MaintenanceScheduler` (a microtask today). Memory
  may overshoot the threshold until it runs; past 4x the threshold the engine
  flushes inline so a synchronous write loop cannot grow without bound.
- The WAL keeps every write safe while maintenance is pending, so closing or
  crashing before it runs recovers normally.
- `VelxoDatabase.openSync(backgroundFlush: true)` builds the segment itself on a
  background isolate (`Isolate.run`, with the snapshot batch transferred). The
  write that crosses the threshold only encodes the memtable; if no writes
  landed during the build, the memtable and WAL are reset, otherwise the newer
  writes stay in the memtable/WAL and shadow the new segment.
  `db.waitForMaintenance()` awaits it. On the web the segment is built inline
  because isolates are unavailable.

### Known limitations (planned)

These are real boundaries, not hidden behavior:

1. **Same-process writer isolation across isolates.** The worker+rpc model works,
   but a direct `VelxoDatabase.openSync` from another isolate in the same
   process is not detected on POSIX. Planned: a process-wide writer registry
   (lock directory with owner PID, or a `flock`-based lock) so every entry point
   shares one guard.
2. **Worker reads are serialized.** There is no MVCC; one slow query blocks
   writes. Planned: read-only snapshots plus a shared-lock mode, then a
   reader/writer split across isolates.
3. **Values are copied across the isolate boundary.** Planned: batched RPC and
   transferable result buffers for large scans; zero-copy stays inside the
   worker.
4. **The worker RPC surface is small.** It covers key/value CRUD, paging, flush,
   check and maintenance. Planned: queries (indexed eq/range, full-text, graph)
   and transactions over the protocol.
5. **Flush uses a fresh `Isolate.run` per build.** Planned: a long-lived builder
   worker reused across flushes.
6. **Full-copy backup only.** Planned: incremental backup and backup of a live
   database owned by another process.
7. **Indexed range is still slower than isar (about 1.25x).** The redundant
   per-hit value check was removed; closing the rest needs a covering index or a
   cheaper document fetch for range hits.

## Status

Pre-alpha, usable end to end on the VM.

| Area | State |
| --- | --- |
| VXS format (zero-copy, checksums, fuzz-tested) | done |
| Local engine (WAL, memtable, segments, manifest, mmap, compaction) | done |
| Query layer (collections, cursors, ranges, pagination, planner) | done |
| Secondary indexes (int32/int64, string, bool; equality and range) | done |
| Typed codegen (direct code, separate `velxodb_generator` package) | done |
| Schema versions, defaults, resumable migrations | done |
| Reference bindings (restrict / cascade) | done |
| Typed graph edges + depth-limited BFS walk | done |
| Object-store backend (async, same segment format) | done |
| Crash-point matrix (deterministic, in CI) | done |
| Deferred flush/compaction (single isolate) | done |
| Background-isolate segment build | done |
| Worker isolate + RPC facade (one writer, many clients) | done |
| Read-only opens + shared reader locks | done |
| Full backup/restore | done |
| Full-text and n-gram primitives | done |
| Web (OPFS) async DB: CRUD/scan/indexes/tx | done; refs/graph/text next |
| Mongo-style client facade | planned |
| Vector / geo field types | planned |

## Quick start

```dart
import 'dart:typed_data';
import 'package:velxodb/velxodb.dart';

final db = VelxoDatabase.openSync('data/chat');
final messages = db.collection('messages');

final key = Uint8List.fromList('m1'.codeUnits);
messages.putSync(key, encodedDocument);
final document = messages.getSync(key);

// Multi-document atomicity: one WAL frame, or nothing on throw.
db.transactionSync(() {
  messages.putSync(key, editedDocument);
  users.putSync(userKey, userDocument);
});

await db.close(flush: true); // graceful shutdown: reopen reads the manifest,
                             // not a full WAL replay
```

### Web (async)

Browsers cannot run the synchronous local engine. The Web stack uses blit's
chunked OPFS backend and the async object-store engine, with the same document
encoding and collection key layout as the VM:

```dart
final db = await VelxoWebDatabase.open(root: 'chat');
final messages = await db.collection('messages');

await messages.put(key, encodedDocument);
final document = await messages.get(key);
final page = await messages.page(limit: 100);
await db.close();
```

The OPFS store keeps a crash-safe append-only key index so `list` works without
walking OPFS; each object is a blit logical file (chunked, sparse, worker pool).
This async facade covers collections, document CRUD, ordered scans, key-cursor
pages, secondary indexes (equality and range) and write transactions (one WAL
object for documents plus index maintenance) with the same key layout as the VM.
References, graph and full-text over OPFS are the next step. Chrome tests cover
the adapter, engine reopen, CRUD, indexes and transactions.

### Queries

```dart
messages.createIndex(3, VxsType.string);
final bySender = messages.findSync(Query(where: Predicate.eq(3, 'u1')));

final recent = messages.scanSync(start: since, limit: 50);

final page = messages.pageSync(limit: 20);
final next = messages.pageSync(limit: 20, after: page.next);
```

### Typed models

The generator is a dev dependency; its output is plain Dart with const field
ids and static codecs, no reflection on the hot path:

```dart
const spec = ModelSpec(
  className: 'ChatMessage',
  collectionName: 'messages',
  keyField: 'id',
  fields: <FieldSpec>[
    FieldSpec('id', 1, FieldKind.string),
    FieldSpec('conversationId', 2, FieldKind.string, indexed: true),
    FieldSpec('senderId', 3, FieldKind.string, indexed: true),
    FieldSpec('createdAt', 4, FieldKind.int64, indexed: true),
    FieldSpec('body', 5, FieldKind.string),
  ],
);
final source = generateModel(spec);
```

```dart
final typed = ChatMessage.open(db);
typed.putSync(ChatMessage.keyOf(message), message);
```

### References, graph, migrations

```dart
messages.createReference(3, 'users');                       // restrict by default
messages.createReference(4, 'users', onDelete: OnDelete.cascade);

final graph = db.graph;
graph.link('member_of', NodeRef.of(users, userKey), NodeRef.of(groups, groupKey));
final members = graph.incoming('member_of', groupNode);
final network = graph.walk(userNode, maxDepth: 2, relations: {'follows'});

collection.migrateSync(toVersion: 2, steps: [
  MigrationStep(from: 1, to: 2, apply: (old, out) {
    copyFields(old, out, toId: 7);
    out.putInt(7, 5);
    copyFields(old, out, fromId: 8);
  }),
]);
```

## Benchmarks

![velxodb benchmarks](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks.svg)

![velxodb engine vs sled](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-engine.svg)

![velxodb database vs isar](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-db.svg)

Everything lives under `benchmarks/`. The main suite (CI renders
`assets/benchmarks.svg`):

```sh
cd benchmarks
dart run benchmark_test --output jsonl . > ../bench.jsonl
```

The comparison suite has two cards, one per abstraction layer:

- **`assets/benchmarks-engine.svg`** — velxodb **storage engine** vs sled:
  both are raw key/value engines writing one 130-byte value per key.
- **`assets/benchmarks-db.svg`** — velxodb **document database** vs
  isar_community: both write 100k documents with one string index and query it
  the same way.

Local run (needs the isar native library and Rust):

```sh
cd benchmarks/compare && python run.py
```

Median of 3 runs, AOT Dart / native isar / release sled, Windows x64. Every
read/query phase runs after flush + close + reopen, so no engine serves from a
warm memtable:

| Tier | Result |
| --- | --- |
| Engine import | 98.6 ms / 100k (1.01M docs/s) vs sled 284.5 ms (351k docs/s) |
| Engine point reads | 18.8 ms / 20k (1.06M reads/s) vs sled 162 ms (123k reads/s) |
| Engine reopen + 1k reads | 2.2 ms vs sled 87.3 ms |
| Engine range scan | sled 2.6 ms / 10k (3.84M keys/s); velxodb has no engine-level cursor |
| Engine disk | 15.4 MB vs sled 63.4 MB |
| DB import + index | 1.55 s / 100k (64k docs/s) vs isar 2.08 s (48k docs/s) |
| DB point reads | 23.4 ms / 20k (855k reads/s) vs isar 61.3 ms (326k reads/s) |
| DB indexed equality | 1.3 ms / 1k (769k q/s) vs isar 4.7 ms (213k q/s) |
| DB indexed range | 11.0 ms / 12k (1.09M q/s) vs isar 8.8 ms (**1.36M q/s**) |
| DB reopen + 1k reads | 2.7 ms vs isar 4.4 ms |
| DB disk | 19.3 MB vs isar 26.2 MB |

Where velxodb loses, stated plainly:

- **Indexed range.** isar answers a 12k-hit string range in 8.8 ms; velxodb
  takes 11.0 ms. We win equality and point reads, lose range.
- **No engine-level KV range cursor.** sled scans 10k keys in 2.6 ms; our
  collection cursor exists, but `StorageEngine` does not expose a public raw
  range API. The row is sled-only on purpose.
- **The engine stores VXS documents, not opaque blobs.** sled accepts arbitrary
  bytes; our lower layer validates the document format. That is a higher-level
  abstraction, not a benchmark trick.
- **Concurrency.** isar supports multi-isolate/MVCC access; velxodb is
  single-writer, single-isolate today.
- **Ecosystem.** isar and sled have years of production hardening; this engine
  is young, and the crash-point matrix is not in CI yet.

### How fair are these numbers?

- **Same API class on both sides.** velxodb uses `putManySync` / `get` /
  `findSync`; isar uses `writeTxnSync` + `putAllSync` / `getSync` /
  `findAllSync`; sled uses `apply_batch` / `get` / `range`. No async API is used
  for one side and sync for the other.
- **Persisted before every read/query.** Every engine is flushed and closed,
  then reopened; reads and index queries run from storage, not from a memtable.
  A 1k-read warm-up runs before the timed 20k reads on every side.
- **Same payload size in tier A**: 130-byte values for velxodb and sled.
- **Same result sets, checked.** Equality must return exactly 1,000 rows and
  the closed range exactly 12,000 rows on both engines; the harness throws if
  not.
- **Medians with spread.** 3 runs; `run.py` records the semi-range as
  `rme_pct` in each report.
- **All input and code are in this repository** (`benchmarks/compare`), so the
  methodology can be audited and reproduced.

Remaining differences that are legitimate design choices, not cheating:

- velxodb returns zero-copy bytes/views; isar materializes `Doc` objects. That
  is an API/format advantage of the design, but it means query throughput is not
  purely "engine speed".
- isar and sled use their own record encodings; byte-for-byte disk layout is
  not comparable, only logical workload and result sets are.
- Closed ranges are used on both sides because isar 3.4.1 returns zero rows for
  an exclusive-upper string range; this is disclosed rather than hidden.

Still not measured: cold reads with dropped OS caches, RSS, crash recovery
time, and concurrent/multi-isolate throughput. The cards are a same-workload,
same-machine, post-reopen comparison, not a universal ranking.

Object-store engine, simulated with request/byte accounting:

```sh
cd benchmarks
dart run object_store_bench.dart
```

```
phase                          wall    requests   (get/put/del/list)      out        in
open (empty)                      3ms          2 (1/0/0/1)      0.0MB      0.0MB
import 200000 docs              412ms        412 (0/408/4/0)     60.3MB      0.0MB
churn 40000 updates + 20000 deletes    106ms        123 (0/122/1/0)     11.7MB      0.0MB
compact                         366ms          8 (5/2/1/0)     27.9MB     36.4MB
20000 random reads               53ms          1 (1/0/0/0)      0.0MB     27.9MB
reopen                            0ms          2 (1/0/0/1)      0.0MB      0.0MB
```

## Packages

| Package | Purpose |
| --- | --- |
| `packages/velxodb` | format, storage engines, query layer, public API |
| `packages/velxodb_generator` | dev-time model/codec generation |

## Design rules

- **No reflection, no runtime codegen.** The generator runs at development time.
- **Zero-copy first.** Documents are read through views; projections and filters
  never materialize maps.
- **Explicit ids.** Field ids, schema ids and versions are part of the on-disk
  contract and never derived from names.
- **Crash safety is a commit order.** WAL first, then the manifest; a document
  and its derived entries share one WAL frame.
- **Bounded work per query.** Walks have depth limits; pagination is a key
  cursor; global graph walks are opt-in and documented as O(nodes × relations).
- **I/O stays at the edge.** The format and the engine are tested without a
  filesystem; backends are interchangeable and small.

## Versioning

VelxoDB uses `A.B.C`. The normative policy is [VERSIONING.md](VERSIONING.md);
the short version:

- **C (patch)**: byte-identical format, unchanged export API and documented
  behavior, no migration logic. Internal logic, bug fixes and performance
  optimizations are allowed.
- **B (minor)**: format may change; a direct reader built for one exact `A.B.C`
  is not promised to read another `A.B.*`, but VelxoDB's own API transparently
  upgrades or ignores the difference, so every release inside the same A opens
  every database without user action. API changes are additive; removals
  require an explicit deprecation and happen only in the next A.
- **A (major)**: format and/or API may break. Upgrading requires
  `VelxoDatabase.upgradeSync(path)`, which records an **in-place undo journal**
  (original byte ranges, not a copy of the database) before touching data.
  `VelxoDatabase.rollbackUpgradeSync(path)` applies it in reverse for the
  downgrade path. Opening without upgrading raises
  `VelxoUpgradeRequiredException`; opening a newer major raises
  `VelxoIncompatibleException`.

Each database carries a `FORMAT` stamp (`major`, `minor`, CRC-32C). A database
without one is treated as `1.0` and stamped on the next writable open. An
unfinished major upgrade leaves `UPGRADE-JOURNAL` behind; opening refuses until
it is rolled back.

## Roadmap

Already shipped: VXS format, WAL + segments + mmap, query layer, secondary
indexes, typed collections, references, graph, full-text, object-store engine,
transactions, single-writer lock, durability tiers, auto-flush, auto-compaction,
deferred maintenance, background-isolate segment builds, the worker-isolate RPC
facade, read-only opens, full backup/restore, integrity check, typed errors, and
a deterministic crash-point matrix in CI (every byte of a torn transaction
frame, segment-before-manifest, torn manifest fallback, pre-truncate replay,
corrupt segment).

Remaining, in order:

1. **Process-wide writer guard + MVCC** — a direct open from another isolate in
   the same process is still not detected on POSIX, and reads block writes;
   planned: a process-wide guard and snapshots so readers do not serialize
   behind the writer.
2. **Index-range performance** — isar is still about 1.25x faster on the
   12k-hit range benchmark; close it with a covering index or cheaper document
   fetch, then add the engine-level KV range cursor.
3. **Web feature parity** — CRUD/scan/indexes/transactions are Chrome-tested;
   references, graph and full-text over OPFS remain, then wasm smoke.
4. **Mongo-style facade** over the existing query layer.
5. **Docs site and runnable examples**, plus long-running stress/fuzz jobs.

## License

MIT.
