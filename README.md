# velxodb

[![CI](https://github.com/unk-404/dart_velxodb/actions/workflows/ci.yml/badge.svg)](https://github.com/unk-404/dart_velxodb/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/velxodb.svg)](https://pub.dev/packages/velxodb)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platforms](https://img.shields.io/badge/platforms-VM%20%7C%20JS%20%7C%20Wasm-blue)

An embedded, pure-Dart document database.

velxodb stores documents in a binary format that can be read without copying,
keeps them in immutable memory-mapped segments, and commits through a checksummed
write-ahead log. The same segment and manifest bytes are served from a local
filesystem, from an object store (S3-style `get`/`put`/`list`) or from OPFS in a
browser. There is no separate "cloud adapter": object storage is the same format
with a different I/O edge.

- **Zero-copy documents.** A read returns a view; strings are decoded only when
  materialized. Projections allocate nothing.
- **One atomic frame.** A document and its secondary-index entries, reference
  postings, graph edges and full-text postings commit together.
- **No reflection, no runtime codegen.** The optional generator emits plain Dart
  with `const` field ids.
- **Typed failures.** Lock, corruption, constraint, conflict and version errors
  are distinct types, not strings.

## Install

```yaml
dependencies:
  velxodb: ^1.0.0
dev_dependencies:
  velxodb_generator: ^1.0.0
```

Requires Dart `^3.13.0`. The package has one runtime dependency (`blit`).

## Quick start

```dart
import 'dart:typed_data';

import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

final db = VelxoDatabase.openSync('data/chat');
final messages = db.collection('messages');

final document = (DocBuilder(schemaId: 1)
      ..putString(1, 'conv-42')
      ..putString(3, 'u1')
      ..putString(5, '在吗？'))
    .finish();

final key = Uint8List.fromList('m1'.codeUnits);
messages.putSync(key, document);

final view = DocView.parse(messages.get(key)!.asUint8List());
print(view.getString(5)); // decoded here, not on read

await db.close(flush: true);
```

A transaction makes several writes one frame:

```dart
db.transactionSync(() {
  messages.putSync(m1, edited);
  users.putSync(u1, updatedUser);
});
```

In the browser the same model is asynchronous, because OPFS is:

```dart
final db = await VelxoWebDatabase.open(root: 'chat');
final messages = await db.collection('messages');
await messages.put(key, document);
final page = await messages.page(limit: 100);
await db.close();
```

## What is in the box

| Area | What you get |
| --- | --- |
| Documents | `VXS` v1: stable field ids, delta-encoded keys, zigzag varints, zero-copy views, optional CRC, forward-compatible unknown fields |
| Storage | WAL, memtable with hash index and skip list, immutable segments, bloom filters, two-slot manifest, compaction, mmap reads |
| Queries | Ordered scans, prefix scans, key-cursor pages, streaming cursors, predicate planner with `explain` |
| Indexes | Secondary indexes on int32, int64, string and boolean; equality and range; crash-safe creation |
| Relations | Reference bindings with reverse indexes and `restrict`/`cascade`; typed graph edges with BFS |
| Text | Plug-in tokenizers, word and n-gram indexes, `any`/`all`, per-hit verification |
| Schema | Versioned documents, resumable migrations, typed collections, a dev-time generator |
| Object storage | `ObjectStore` SPI, simulated store with request accounting, conformance kit |
| Web | Async database over OPFS: CRUD, scans, indexes, transactions, references, graph, full text |
| Operations | Single-writer lock, read-only opens, durability tiers, integrity check, backup/restore, worker isolate, crash matrix |

## Architecture

```
        query/    collections · cursors · indexes · planner · references · graph · text
          │
        storage/  engine · WAL · memtable · segment · manifest · compaction
          │                  ╱                          ╲
        serde/      local files (dart:io + mmap)      object store / OPFS
```

Each layer only depends on the one below it:

- `serde/` is pure byte codecs; it imports no I/O and no storage code.
- `storage/` composes WAL, memtable and segment codecs; it does not know about
  collections, schemas or queries.
- `query/` owns collections, indexes, references, graph and text; it talks to a
  small engine surface.
- `web/` reuses the same `ObjectStoreEngine`, catalog, index codecs and document
  format; only the orchestration is async.
- Backends (local directory, object store, OPFS) sit behind interfaces and are
  interchangeable. The format and the engine are tested without a filesystem.

A segment written by the local engine opens unchanged in the object-store engine
and vice versa; a compatibility test covers both directions.

## Storage is I/O-agnostic by construction

The mutable surface is tiny: segments are immutable and the manifest is the only
object replaced on commit. That single property is what makes crash recovery a
commit order instead of a transaction-log protocol, and it is also why the same
bytes work on a filesystem or an object store.

| Operation | Requests on an object store |
| --- | --- |
| put/delete batch | 1 PUT |
| flush | 1 PUT segment + 1 PUT manifest + 1 batch DELETE |
| open | 1 GET manifest + 1 LIST WAL prefix + K GET unflushed batches |
| first read of a segment | 1 GET, then served from an LRU cache |
| compaction | S GET + 1 PUT segment + 1 PUT manifest + 1 batch DELETE |

A concrete backend implements five methods:

```dart
abstract interface class ObjectStore {
  Future<Uint8List?> get(String key);
  Future<void> put(String key, Uint8List bytes);
  Future<void> delete(String key);
  Future<void> deleteMany(List<String> keys);
  Future<List<String>> list(String prefix);
}
```

Because the SPI is small, correctness is testable: `package:velxodb/testing.dart`
ships `ObjectStoreConformance`, which checks round trips, overwrite, large
objects, deletes, batch deletes, prefix listing and absent keys.

## Guarantees

- **Atomic writes.** A document and every derived entry commit in one WAL frame.
- **Transactions.** `db.transactionSync` buffers writes, exposes them to point
  reads and index lookups inside the block, and commits as one frame. An
  exception applies nothing. Single writer, no nesting, no MVCC; scans do not
  see uncommitted writes.
- **Crash recovery.** Replay the WAL, then trust the manifest as the commit
  point. A torn frame is dropped whole; a committed frame never splits. A torn
  first manifest recovers from the still-intact WAL.
- **Integrity.** Segment metadata has a CRC; document blocks are CRC-checked
  lazily on first access and compaction refuses to rewrite a corrupt block. A
  flipped `blockCount` cannot steer the block table into the index. Deep check
  verifies every block, orphan segment, catalog entry and posting.
- **Durability tiers.** `always` fsyncs every frame; `batched` (default) fsyncs
  on flush, close and `sync()`; `none` leaves it to the caller.
- **Bounded work.** Auto-flush and auto-compaction bounds; graph walks have depth
  limits; pagination is a key cursor, not an offset.
- **Read-only opens.** Readers share the directory lock, replay without
  truncating and reject every write, including catalog changes.
- **Typed errors.** `VelxoLockedException`, `VelxoCorruptException`,
  `VelxoClosedException`, `VelxoConflictException`, `VelxoConstraintException`,
  `VelxoNotFoundException`, `VelxoReadOnlyException`, `VelxoWorkerException`,
  `VelxoIncompatibleException`, `VelxoUpgradeRequiredException`.

## Queries, indexes, relations

```dart
messages.createIndex(3, VxsType.string);

final bySender = messages.findSync(Query(where: Predicate.eq(3, 'u1')));
final recent = messages.scanSync(start: since, limit: 50);
final page = messages.pageSync(limit: 20);
final next = messages.pageSync(limit: 20, after: page.next);
```

References are declared, not implied:

```dart
messages.createReference(3, 'users');                       // restrict
messages.createReference(4, 'users', onDelete: OnDelete.cascade);
```

`restrict` and `cascade` are always enforced on delete; cascade is one frame,
cycle-safe and depth-limited. `enforceReferences = true` additionally rejects a
write whose target does not exist, and `validateReferences()` audits a bulk load
without paying a point read per write.

Graph edges are typed and bidirectional:

```dart
final graph = db.graph;
graph.link('member_of', NodeRef.of(users, userKey), NodeRef.of(groups, groupKey));
final members = graph.incoming('member_of', groupNode);
final network = graph.walk(userNode, maxDepth: 2, relations: {'follows'});
```

## Typed models

The generator is a separate package and runs at development time. Its output is
plain Dart: `const` field ids, static encode/decode functions, index and
reference setup. No schema objects or closures on the hot path.

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

Migrations are version-aware and resumable:

```dart
collection.migrateSync(toVersion: 2, steps: [
  MigrationStep(from: 1, to: 2, apply: (old, out) {
    copyFields(old, out, toId: 7);
    out.putInt(7, 5);
    copyFields(old, out, fromId: 8);
  }),
]);
```

## Concurrency

- One open database belongs to one isolate. Writes are synchronous and
  single-writer.
- `VelxoWorker.open(path)` owns the database in a worker isolate and serializes
  requests from any number of client isolates behind one command port.
- A writable open takes an exclusive directory lock; read-only opens take a
  shared one. The OS lock covers other processes. An in-isolate registry
  rejects a second handle in the same isolate; POSIX advisory locks are
  process-wide, so a *different isolate in the same process* is not detected —
  use one writer per process (documented below).
- `openSync(deferredMaintenance: true)` moves a threshold-triggered flush off the
  write; `backgroundFlush: true` builds the segment on a background isolate.
- Web mutations and index backfills are serialized by the database, so two
  concurrent puts cannot lose each other's postings.

## Benchmarks

![velxodb benchmarks](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks.svg)

![velxodb engine vs sled](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-engine.svg)

![velxodb database vs isar](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-db.svg)

The headline card is a summary; the per-layer cards carry the full set:

| VXS format | Storage |
| --- | --- |
| ![VXS format card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-format.svg) | ![Storage card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-storage.svg) |
| **Query** | **Object store** |
| ![Query card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-query.svg) | ![Object-store card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-objectstore.svg) |

The full methodology, the rest of the cards and the comparison harness live
under [`benchmarks/`](benchmarks/README.md). The comparison suite has two cards,
one per abstraction layer:

- **Storage engine vs sled**: both are raw key/value engines writing the same
  130-byte value per key.
- **Document database vs isar_community**: both write 100k documents with one
  string index and query it the same way.

### Compared with sled and isar

Median of 3 runs; AOT Dart, native isar and release sled; engine order shuffled
per run; the same deterministic key sequence on every engine. Snapshot from the
run that produced the cards (2026-10-21); CI regenerates the cards.

| Phase | velxodb engine | sled 0.34 |
| --- | --- | --- |
| Import 100k | **100.5 ms** (995k docs/s) | 298.2 ms (335k docs/s) |
| Open only | **3.27 ms** | 56.65 ms |
| First 1k reads after open | **16.4 ms** | 34.1 ms |
| 20k point reads | **20.7 ms** (968k reads/s) | 163.8 ms (122k reads/s) |
| 10k key range | not exposed at engine level | 2.8 ms (3.5M keys/s) |
| On-disk size | **15.43 MB** | 63.81 MB |

| Phase | velxodb database | isar_community 3.4.1 |
| --- | --- | --- |
| Import + index 100k | **618 ms** (162k docs/s) | 2179 ms (46k docs/s) |
| Open only | 7.70 ms | **3.29 ms** |
| First 1k reads after open | 16.6 ms | **4.4 ms** |
| 20k point reads | **21.7 ms** (922k reads/s) | 62.0 ms (323k reads/s) |
| Indexed equality (1k hits) | **1.2 ms** (821k q/s) | 5.1 ms (194k q/s) |
| Indexed range (12k hits, closed) | 13.1 ms (916k q/s) | **9.3 ms** (1.29M q/s) |
| On-disk size | **19.34 MB** | 20.97 MB (compacted copy) |

The first 1k reads after open cost more per read than steady state (~17 µs vs
~1 µs) because the first touch of each memory-mapped segment page faults it in.
That is a one-time cost; a workload that immediately scans pays it up front, and
it is the main reason the database-level reopen row is slower than isar's.

### Real filesystem, durability and object storage

- **100k documents on real files** (13.0 MB payload): import 186 ms
  (538k docs/s), reopen 15 ms, RSS increase 2.73 MB, on-disk 15.63 MB (1.20x
  payload), point reads p50 1.0 µs / p95 2.0 µs.
- **Durability** (20k documents, Kdocs/s, put / batch of 500 / transaction of
  100): `always` 0.77 / 192 / 55, `batched` 59.7 / 792 / 467, `none` 67.5 /
  1074 / 798. One WAL frame per document costs 156 B (1.20x the document).
- **Object-store request shape** (200k documents, simulated store, exact
  counts): import 412 requests, 60k-change churn 123, compaction 8, 20k random
  reads 1, reopen 2 with no segment download. Stored 27.9 MB for a 26.0 MB
  payload.

Where velxodb loses, stated plainly:

- **Database open and first reads.** isar opens this 100k-document database in
  3.3 ms; velxodb takes 7.7 ms because it reads the catalog and manifest, and
  its first mapped-page touches cost more than isar's warm buffer pool. Steady
  state flips the result: 922k vs 323k point reads/s.
- **Indexed range.** isar answers a 12k-hit string range in 9.3 ms; velxodb
  takes 13.1 ms because each hit re-reads the document. A covering index is the
  planned fix.
- **No engine-level KV range cursor.** sled scans 10k keys in 2.8 ms; our range
  cursor lives one layer up. The row is sled-only on purpose.
- **The engine stores VXS documents, not opaque blobs.** sled accepts arbitrary
  bytes; our lower layer validates the document format. That is a higher-level
  abstraction, not a benchmark trick.
- **Concurrency.** isar supports multi-isolate MVCC access; velxodb is
  single-writer, single-isolate today.
- **Ecosystem.** isar and sled have years of production history.

### How fair are these numbers?

- **Same API class on both sides.** velxodb uses `putManySync` / `get` /
  `findSync`; isar uses `writeTxnSync` + `putAllSync` / `getSync` /
  `findAllSync`; sled uses `apply_batch` / `get` / `range`. No async API is used
  for one side and sync for the other.
- **Persisted before every read.** Every engine is flushed and closed, then
  reopened; reads and index queries run from storage, not from a memtable. A 1k
  read warm-up runs before the timed 20k reads.
- **Opening is its own row.** The stopwatch starts before `open` and stops
  before the first read for every engine, so open is neither hidden inside nor
  excluded from a read phase.
- **Same payload and same keys.** Tier A writes the identical 130-byte VXS
  fixture on both sides (the Rust side reads the file the Dart side wrote), and
  every engine reads one shared key sequence.
- **Same result sets, checked.** Equality must return exactly 1,000 rows and the
  closed range exactly 12,000 rows; every timed read must hit; the harness
  throws otherwise.
- **Medians with spread.** 3 runs, `semi_range_pct` per row, printed as `±` on
  the cards.
- **All input and code are in this repository**, so the methodology can be
  audited and reproduced.
- The micro cards are JIT and the comparison cards are AOT; each card states
  which compiler it used, and the two sets are not compared across.

Not measured yet: cold reads with dropped OS caches, 1M-document scale, crash
recovery time, mixed read/write churn and multi-isolate throughput. The cards
are a same-workload, same-machine, post-reopen comparison, not a universal
ranking.

## Platform support

| Platform | Local engine | Object store | Worker isolate |
| --- | --- | --- | --- |
| Dart VM (Linux, macOS, Windows) | sync, mmap | async | yes |
| Dart JS (browser) | no | OPFS | no (typed stub) |
| Dart Wasm (browser) | no | OPFS | no (typed stub) |

The Web/OPFS suite runs in Chrome under both `dart2js` and `dart2wasm` in CI;
JS and Wasm compilation of the full public surface is a separate check.

## Versioning

`A.B.C` governs the package and the on-disk format. The normative policy is
[VERSIONING.md](VERSIONING.md); in short:

- **C (patch)**: byte-identical format, unchanged API and behavior, no migration
  logic.
- **B (minor)**: the format may change; direct readers for one exact `A.B.C` are
  not guaranteed, but every release inside one `A` opens every database with no
  user action (newer data is upgraded implicitly, older readers ignore unknown
  fields). API changes are additive.
- **A (major)**: format and/or API may break. An upgrade is explicit:
  `VelxoDatabase.upgradeSync(path)` is the only entry point, and the first
  `2.0.0` migration must record an in-place undo journal (original byte ranges
  and lengths, not a copy) before touching data. The journal and
  `VelxoDatabase.rollbackUpgradeSync(path)` — the downgrade path — are
  implemented and tested; `1.0.0` registers no major migration, so an
  older-major database is refused with `VelxoUpgradeRequiredException`.

Each database carries an atomically replaced `FORMAT` stamp (major, minor,
CRC-32C); the Web database stores the same stamp as an object. `1.0.0` writes
format `1.0`; no major migration is registered yet.

## Known limitations

These are real boundaries, not hidden behavior:

1. **Same-process, multi-isolate writers are not detected on POSIX.** The OS
   lock is process-wide and the in-process registry is per isolate, so a second
   *writable* open from another isolate in the same process is not rejected.
   Use one writable handle per process, or the worker facade. Planned: a
   process-wide guard (v1.1).2. **Worker reads are serialized.** There is no MVCC; one slow query blocks
   writes. Planned: read snapshots and a reader/writer split (v1.1).
3. **Values are copied across the isolate boundary.** Planned: batched RPC and
   transferable result buffers (v1.1).
4. **The worker RPC surface is small.** CRUD, paging, flush, check and
   maintenance; queries and transactions are not on the wire yet (v1.1).
5. **Flush uses a fresh `Isolate.run` per build.** Planned: a long-lived builder
   (v1.0.1).
6. **Backup is a full copy.** Incremental backup and backing up a live database
   owned by another process are not supported (v1.1).
7. **Directory-entry durability.** `Durability.always` fsyncs file data; Dart has
   no directory fsync, so a power loss may lose a newly created directory entry
   (a segment, a manifest slot or the catalog rename). The WAL covers the window
   until the manifest commit; after that the filesystem's journaling is relied
   upon (documented, v1.0.1).
8. **Segment mappings live until close.** Compaction releases readers but not the
   old mappings, so a long-running process with many compactions keeps file
   handles and address space until close. Planned: pinned segments and deferred
   unmap (v1.0.1).
9. **Indexed range is slower than isar.** A covering index or a cheaper document
   fetch is the fix (v1.1).
10. **Web tabs.** Current browsers are guarded by the Web Locks API: a second
    tab opening the same root is refused, and a second handle in one page is
    rejected by an in-page registry. A browser without `navigator.locks` falls
    back to the in-page guard only, so one tab is then the supported topology.
11. **OPFS key index has no compaction yet.** It is replayed on open and grows
    with every write; a very long-lived write-heavy database pays a growing open
    cost (v1.0.1).
12. **Graph edges are not deleted with their documents.** `danglingEdges()` finds
    them; automatic cleanup is not implemented (v1.1).

## Roadmap

Shipped in 1.0.0: VXS, local engine, query layer, secondary indexes, typed
collections, references, graph, full-text, object-store engine, transactions,
Web/OPFS stack, worker isolate, read-only opens, backup, integrity checks,
versioning policy and journal, crash matrix.

Next:

- **1.0.1** — pinned segment mappings, OPFS key-index compaction, streaming Web
  backfills, streaming write batching, directory-fsync work where the platform
  allows it, hardening and docs.
- **1.1.0** — MVCC read snapshots, batched worker RPC, transaction and query
  operations over the wire, covering indexes for range, incremental backup,
  block compression (`B` release), automatic graph edge cleanup.
- **2.0.0** — the first `A` migration, using the existing journal; geo and
  vector field types; optional Mongo-style client facade.

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test packages/velxodb/test packages/velxodb_generator/test -j 1 -x crash
dart test packages/velxodb/test/crash -j 1

cd packages/velxodb
dart test -p chrome -j 1 test                        # browser/OPFS (js)
dart test -p chrome -c dart2wasm -j 1 test/web       # browser/OPFS (wasm)
dart compile wasm example/web_smoke.dart -o /tmp/smoke.wasm

cd ../../benchmarks
dart run tool/run_all.dart --quick                   # micro suites + cards
python compare/run.py                                # isar + sled comparison
```

CI checks formatting and analysis on Linux, runs the VM suite on Linux, macOS
and Windows, the Chrome suite under both `dart2js` and `dart2wasm`, JS and Wasm
compilation, the crash matrix, the micro and comparison benchmarks, and
`dart pub publish --dry-run` for both packages.

## Contributing

Issues and pull requests are welcome at
[unk-404/dart_velxodb](https://github.com/unk-404/dart_velxodb). Before sending
a change:

- run `dart format .`, `dart analyze --fatal-infos` and the full test suites
  listed above;
- add a test for behavior changes; a fix without a regression test is not
  finished;
- classify the change against [VERSIONING.md](VERSIONING.md) (most bug fixes are
  `C`);
- keep the layers separate: `serde` does not import storage, storage does not
  import queries, and backends sit behind the interfaces.

## Security

The database processes untrusted bytes: every decoder validates lengths and
checksums before use, and a failed decode raises `VelxoCorruptException` or
`VxsFormatException` instead of reading out of bounds. Encryption at rest is not
part of 1.0.0. To report a security issue, open a private security advisory on
GitHub rather than a public issue.

## Links

- [Changelog](https://github.com/unk-404/dart_velxodb/blob/main/packages/velxodb/CHANGELOG.md)
- [Versioning policy](VERSIONING.md)
- [Benchmark methodology](benchmarks/README.md)
- [API documentation](https://pub.dev/documentation/velxodb/latest/)

## License

MIT.
