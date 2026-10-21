<center>
  <h1>VelxoDB</h1>

  <a href="https://github.com/unk-404/dart_velxodb/actions/workflows/ci.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/unk-404/dart_velxodb/ci.yml?style=for-the-badge" />
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=for-the-badge" />
  </a>
  
  <img src="https://img.shields.io/pub/v/velxodb.svg?style=flat-square" />
  <img src="https://img.shields.io/pub/points/velxodb?style=flat-square" />
  <img src="https://img.shields.io/pub/likes/velxodb.svg?style=flat-square" />
</center>

An embedded, pure-Dart document database.

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

## Areas

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

## I/O-agnostic

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

- **Atomic writes.** A document and all its derived entries commit in one WAL frame.
- **Transactions.** `db.transactionSync` buffers writes, exposes them to point reads and index lookups within the block, and commits as one frame; an exception applies nothing. Single writer, no nesting, no MVCC; scans don't see uncommitted writes.
- **Crash recovery.** Replay the WAL, then trust the manifest as the commit point. A torn frame is dropped whole; a committed frame never splits. A torn first manifest recovers from the intact WAL.
- **Integrity.** Segment metadata has a CRC; document blocks are CRC-checked lazily on first access, and compaction refuses to rewrite a corrupt block. A flipped `blockCount` can't steer the block table into the index. Deep check verifies every block, orphan segment, catalog entry and posting.
- **Durability tiers.** `always` fsyncs every frame; `batched` (default) fsyncs on flush, close and `sync()`; `none` leaves it to the caller.
- **Bounded work.** Auto-flush and auto-compaction bounds; graph walks have depth limits; pagination is a key cursor, not an offset.
- **Read-only opens.** Readers share the directory lock, replay without truncating, and reject every write, including catalog changes.

## TODOs

+ [ ] Replace the fresh `Isolate.run` per flush build with a long-lived builder.
+ [ ] Add directory fsync where the platform allows it; `Durability.always` currently fsyncs file data only, so a power loss may lose a newly created directory entry (segment, manifest slot or catalog rename), with the WAL covering the window until the manifest commit.
+ [ ] Pin segments and defer unmap so compaction releases old mappings instead of keeping file handles and address space until close.
+ [ ] Add compaction for the OPFS key index, which is replayed on open and grows with every write, raising open cost for long-lived write-heavy databases.
+ [ ] Add a process-wide guard so a second writable open from another isolate in the same process is rejected on POSIX; meanwhile use one writable handle per process or the worker facade.
+ [ ] Introduce read snapshots and a reader/writer split so one slow worker query no longer blocks writes (no MVCC today, reads are serialized).
+ [ ] Implement batched RPC and transferable result buffers to stop copying values across the isolate boundary.
+ [ ] Put queries and transactions on the worker RPC wire; today only CRUD, paging, flush, check and maintenance are exposed.
+ [ ] Support incremental backup and backing up a live database owned by another process, instead of the current full-copy backup.
+ [ ] Speed up indexed range queries with a covering index or a cheaper document fetch, since range is currently slower than isar.
+ [ ] Automatically clean up graph edges when their documents are deleted; `danglingEdges()` finds them today but cleanup is not implemented.
+ [ ] Keep the Web Locks API guard for tabs, and add a fallback for browsers without `navigator.locks` so more than one tab is supported (today the in-page guard is the only protection there).

## Benchmarks

![velxodb benchmarks](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks.svg)

## vs [sled](https://github.com/spacejam/sled)

![velxodb engine vs sled](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-engine.svg)

## vs [isar](https://github.com/isar-community/isar-community)

![velxodb database vs isar](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-db.svg)

### VXS format

![VXS format card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-format.svg)

### Storage

![Storage card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-storage.svg)

### Query

![Query card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-query.svg)

### Object store

![Object-store card](https://raw.githubusercontent.com/unk-404/dart_velxodb/main/assets/benchmarks-objectstore.svg)

The full methodology, the rest of the cards and the comparison harness live
under [`benchmarks/`](benchmarks/README.md).

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
