# velxodb

An embedded, pure-Dart document database.

- **Zero-copy documents.** Documents are encoded in `VXS`, a field-addressable
  binary format. A read returns a view over the bytes; a string is only decoded
  when you ask for it.
- **Local-first storage.** Immutable, memory-mapped segments, a checksummed
  write-ahead log and a two-slot manifest. Point reads are a bloom probe plus a
  binary search.
- **I/O-agnostic by construction.** The same segment and manifest bytes are
  served from files or from an object store (S3-style `get`/`put`/`list`), and
  from OPFS in the browser.
- **One engine, many structures.** Collections, secondary indexes, reference
  bindings, graph edges and full-text postings share one key/value engine;
  a document and its derived entries commit in one WAL frame.

## Platform support

| Platform | Local engine | Object-store engine | Worker isolate |
| --- | --- | --- | --- |
| Dart VM (Linux, macOS, Windows) | yes, sync + mmap | yes, async | yes |
| Dart JS / Wasm (browser) | no | yes, over OPFS | no (stub throws) |

The local engine is synchronous by design: awaiting three futures per insert
costs more than the insert. The web stack is asynchronous because OPFS handles
are asynchronous; both share the document encoding and key layout.

## Install

```yaml
dependencies:
  velxodb: ^1.0.0

dev_dependencies:
  velxodb_generator: ^1.0.0
```

Dart `^3.13.0`.

## Quick start (VM)

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
print(view.getString(5)); // zero-copy read, decoded only here

await db.close(flush: true);
```

A transaction makes several documents and their index entries one atomic frame:

```dart
db.transactionSync(() {
  messages.putSync(m1, edited);
  users.putSync(u1, updatedUser);
});
```

## Quick start (browser)

```dart
final db = await VelxoWebDatabase.open(root: 'chat');
final messages = await db.collection('messages');

await messages.put(key, document);
final page = await messages.page(limit: 100);
await db.close();
```

`VelxoWebDatabase` covers CRUD, ordered scans, key-cursor pages, secondary
indexes, atomic transactions, references, graph edges and full-text search over
OPFS. See the repository README for the complete API map.

## Entry points

| Import | Contents |
| --- | --- |
| `package:velxodb/velxodb.dart` | database, collections, queries, indexes, references, graph, Web, worker |
| `package:velxodb/serde.dart` | `DocBuilder`, `DocView`, `DocSink`, `StringView`, CRC-32C |
| `package:velxodb/storage.dart` | WAL, memtable, segments, manifest, engines, object-store SPI |
| `package:velxodb/testing.dart` | `ObjectStoreConformance` kit for custom backends |

## Custom backends

`ObjectStore` is the integration point for cloud object storage. Implement five
methods (`get`, `put`, `delete`, `deleteMany`, `list`) and run the conformance
kit:

```dart
import 'package:velxodb/testing.dart';

await const ObjectStoreConformance(prefix: 'ci/').run(myStore);
```

The engine's request shape is what makes it fit object storage: a write batch is
one `PUT`, a flush is one segment `PUT` plus one manifest `PUT`, and opening
reads one manifest, lists the WAL prefix and fetches only unflushed batches.

## Guarantees

- One document and every derived entry commit in one WAL frame.
- `transactionSync` is all-or-nothing; an exception writes nothing.
- Crash recovery replays the WAL, then trusts the manifest as the commit point.
- `Durability.always` fsyncs every frame; `batched` (default) fsyncs on flush,
  close and `sync()`.
- A writable open takes an exclusive directory lock; read-only opens share it.
- `checkSync(deep: true)` verifies the manifest, segments, blocks, catalog and
  every index posting.
- Errors are typed (`VelxoLockedException`, `VelxoCorruptException`,
  `VelxoConflictException`, `VelxoConstraintException`, …).

## Limits

Single writer per database, one isolate per writable handle, no MVCC. Large
scans decode inside the owning isolate. Web transactions are asynchronous and
serialized by the database. See the repository README for the full list.

## Versioning

`A.B.C` governs both the package API and the on-disk format. See
[VERSIONING.md](https://github.com/unk-404/dart_velxodb/blob/main/VERSIONING.md):
a `C` release is byte-identical and API-frozen, a `B` release changes bytes but
opens transparently inside the same major, and an `A` release requires an
explicit, journaled upgrade with a rollback path.

## Links

- [Repository and documentation](https://github.com/unk-404/dart_velxodb)
- [Changelog](https://github.com/unk-404/dart_velxodb/blob/main/packages/velxodb/CHANGELOG.md)
- [Versioning policy](https://github.com/unk-404/dart_velxodb/blob/main/VERSIONING.md)
- [Issue tracker](https://github.com/unk-404/dart_velxodb/issues)

MIT licensed.
