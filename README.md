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

Not yet provided (tracked in `research/productization.md`): multi-isolate
concurrency, backup/restore, web support, the Mongo-style facade, and the
crash-point matrix in CI.

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
| Full-text and n-gram primitives | planned |
| Web (OPFS) sync engine, HTTP backends | planned |
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

Single-run, no cache flush, AOT Dart / native isar / release sled, Windows x64:

| Tier | Result |
| --- | --- |
| Engine import | 108 ms / 100k (925k docs/s) vs sled 272 ms (367k docs/s) |
| Engine point reads | 7.3 ms / 20k (2.75M reads/s) vs sled 54 ms (372k reads/s) |
| Engine reopen + 1k reads | 2.2 ms vs sled 457 ms |
| Engine range scan | sled 2.4 ms / 10k (4.1M keys/s); velxodb has no engine-level cursor |
| Engine disk | 14.1 MB vs sled 66.5 MB |
| DB import + index | 1.22 s / 100k (82k docs/s) vs isar 2.40 s (42k docs/s) |
| DB point reads | 9.4 ms / 20k (2.1M reads/s) vs isar 570 ms (35k reads/s) |
| DB indexed equality | 0.8 ms / 1k (1.2M q/s) vs isar 5.0 ms (200k q/s) |
| DB indexed range | 6.7 ms / 12k (1.8M q/s) vs isar 12.2 ms (986k q/s) |
| DB reopen + 1k reads | 2.6 ms vs isar 46.9 ms |
| DB disk | 18.1 MB vs isar 26.2 MB |

Where velxodb loses, stated plainly:

- **No engine-level KV range cursor.** sled scans 10k keys in 2.4 ms; our
  collection cursor exists, but `StorageEngine` does not expose a public raw
  range API. The row is sled-only on purpose.
- **The engine stores VXS documents, not opaque blobs.** sled accepts arbitrary
  bytes; our lower layer validates the document format. That is a higher-level
  abstraction, not a benchmark trick.
- **Space is traded for write speed.** sled preallocates and logs; we keep 14 MB
  where sled uses 66 MB for the same keys.
- **Concurrency.** isar supports multi-isolate/MVCC access; velxodb is
  single-writer, single-isolate today.

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

## Roadmap

Already shipped: VXS format, WAL + segments + mmap, query layer, secondary
indexes, typed collections, references, graph, full-text, object-store engine,
transactions, single-writer lock, durability tiers, auto-flush, auto-compaction,
integrity check and typed errors.

Remaining, in order:

1. **Crash-point matrix in CI** — cut power at every WAL/segment/manifest commit
   point, reopen, assert the invariants.
2. **Concurrency model** — an isolate worker (one writer, many readers) or an
   explicit single-isolate contract with a background flush/compaction thread.
3. **Backup / restore** and read-only opens.
4. **Engine-level KV range cursor**, so the storage tier has the same API surface
   as sled.
5. **Web storage** (OPFS in a worker) instead of the current stub.
6. **Mongo-style facade** over the existing query layer.
7. **Docs site and runnable examples**, plus long-running stress/fuzz jobs.

## License

MIT.
