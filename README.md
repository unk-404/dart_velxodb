# velxodb

An embedded, pure-Dart document database built for very large local datasets and
for object storage (S3-style) as a first-class backend.

- **Pure Dart** — no FFI, no native extensions. The storage format layers compile
  to JS/Wasm; the local engine is VM-only by design.
- **Zero-copy binary format (VXS)** — self-describing documents with field-level
  random access. Reading a field does not deserialize the document or allocate a
  map.
- **LSM-style storage** — WAL → memtable → immutable segments. Point reads use a
  bloom filter plus a binary search; the memtable keeps a hash index for lookups
  and a skip list for ordered range scans.
- **Query layer** — collections, streaming cursors, key ranges, pagination,
  secondary indexes, a small query planner, schema versions and migrations,
  reference bindings with delete policies, and typed graph edges.
- **Object-store mode** — a generic `ObjectStore` SPI. Segments and the manifest
  are objects, WAL batches are objects, reads fetch segments lazily through an
  LRU cache. A simulated store in the repo makes the S3 cost model measurable
  (requests/bytes in both directions) without a network.
- **Generated codecs** — a separate dev-time generator turns a `ModelSpec` into
  plain Dart (const field ids, static `encodeInto`/`decodeFrom`, index and
  reference setup). No reflection, no schema objects on the hot path.

## Status

Pre-alpha, but the local engine is usable end to end.

| Area | State |
| --- | --- |
| VXS format (zero-copy, checksums, fuzz-tested) | done |
| Local engine (WAL, memtable, segments, manifest, mmap, compaction) | done |
| Query layer (collections, cursors, ranges, pagination, planner) | done |
| Secondary indexes (int32/int64, string, bool; equality and range) | done |
| Typed codegen (direct code, separate `velxodb_generator` package) | done |
| Schema versions, defaults, resumable migrations | done |
| Reference bindings (restrict / cascade) + typed graph edges + BFS walk | done |
| Object-store engine + request/byte benchmark | done |
| Full-text and n-gram primitives | planned |
| Web (OPFS) sync engine, HTTP backends | planned |
| Mongo-style client facade | planned |
| Vector / geo field types | planned |

## Packages

| Package | Purpose |
| --- | --- |
| `packages/velxodb` | format, storage engines, query layer, public API |
| `packages/velxodb_generator` | dev-time model/codec generation |

## Quick start

```dart
import 'dart:typed_data';
import 'package:velxodb/velxodb.dart';

final db = VelxoDatabase.openSync('data/chat');
final messages = db.collection('messages');

final key = Uint8List.fromList('m1'.codeUnits);
messages.putSync(key, encodedDocument);
final document = messages.getSync(key); // null when absent
```

### Queries

```dart
// Indexed equality: the planner picks the index automatically.
messages.createIndex(3, VxsType.string);
final bySender = messages.findSync(Query(where: Predicate.eq(3, 'u1')));

// Range over an indexed integer field, newest first via key order.
final recent = messages.scanSync(start: since, limit: 50);

// Stable pagination: a token is the last key of the previous page.
final page = messages.pageSync(limit: 20);
final next = messages.pageSync(limit: 20, after: page.next);
```

### Typed models

Declare a spec and generate code (the generator is a dev dependency):

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
final source = generateModel(spec); // write it to a .g.dart file
```

Then:

```dart
final typed = ChatMessage.open(db);
typed.putSync(ChatMessage.keyOf(message), message);
final found = typed.findSync(Query(where: Predicate.eq(3, 'u1')));
```

### References and graph

```dart
// A reference field holds the target key and gets a reverse index.
messages.createReference(3, 'users');            // restrict by default
messages.createReference(4, 'users', onDelete: OnDelete.cascade);

// Typed many-to-many edges, stored in both directions.
final graph = db.graph;
graph.link('member_of', NodeRef.of(users, userKey), NodeRef.of(groups, groupKey));
final members = graph.incoming('member_of', groupNode);
final network = graph.walk(userNode, maxDepth: 2, relations: {'follows'});
```

### Schema migrations

```dart
collection.migrateSync(toVersion: 2, steps: [
  MigrationStep(from: 1, to: 2, apply: (old, out) {
    copyFields(old, out, toId: 7);
    out.putInt(7, 5);
    copyFields(old, out, fromId: 8);
  }),
]);
```

Migrations are idempotent, resumable page by page, and preserve unknown fields
byte for byte.

## Object storage (S3-style)

`ObjectStore` is a four-method SPI (`get`, `put`, `delete`, `deleteMany`, `list`).
`ObjectStoreEngine` stores segments and the manifest as objects and replays WAL
objects on open:

| Operation | Requests issued |
| --- | --- |
| put/delete batch | 1 PUT (WAL object) |
| flush | 1 PUT segment + 1 PUT manifest + 1 batch DELETE |
| open | 1 GET manifest + 1 LIST WAL + K GET WAL |
| first read of a segment | 1 GET, then served from an LRU cache |
| compaction | S GET segments + 1 PUT segment + 1 PUT manifest + 1 batch DELETE |

`SimulatedObjectStore` counts requests and bytes in both directions, so the cost
model is measurable without S3. Benchmark:

```sh
cd packages/velxodb
dart run benchmark/s3_bench.dart
```

Example run (200k docs, churn, compaction, reads):

```
phase                          wall    requests   (get/put/del/list)      out        in
open (empty)                      3ms          2 (1/0/0/1)      0.0MB      0.0MB
import 200000 docs              412ms        412 (0/408/4/0)     60.3MB      0.0MB
churn 40000 updates + 20000 deletes    106ms        123 (0/122/1/0)     11.7MB      0.0MB
compact                         366ms          8 (5/2/1/0)     27.9MB     36.4MB
20000 random reads               53ms          1 (1/0/0/0)      0.0MB     27.9MB
reopen                            0ms          2 (1/0/0/1)      0.0MB      0.0MB
```

## Benchmarks

Local chart (JIT snapshot, for orientation only):

```sh
cd packages/velxodb
dart run benchmark_test --output jsonl benchmark > ../../bench.jsonl
python ../../.agents/tools/render_bench.py ../../bench.jsonl ../../.agents/benchmarks/benchmarks.png
```

CI runs the same suite and renders `assets/benchmarks.svg` with
[benchcat](https://github.com/unk-404/benchcat). Selected AOT numbers:

| Workload | Result |
| --- | --- |
| VXS encode, 130 B chat doc | ~550 MB/s |
| Engine point read (memtable) | ~18M ops/s |
| 1e6 docs, real files | 355k docs/s import, 38 ms reopen, p50 1.5 µs |
| Secondary index write | ~1.7M ops/s |
| Graph link / adjacency | ~1.9M / ~1.2M ops/s |

## Architecture

```
serde/      VXS binary format, zero-copy views, doc builder, CRC-32C
storage/    block, WAL, memtable (+ skip list), arena, segment, manifest,
            local files (dart:io + mmap), object store + object-store engine
query/      catalog, collections, cursor, indexes, planner, schema,
            migration, references, graph
```

Dependencies only ever point downward: `query → storage → serde`. The storage
layer never knows what a collection, an index or an edge is; each layer is
tested against its own contract.

## Design rules

- **No reflection and no runtime codegen.** The generator runs at development
  time and emits plain Dart.
- **Zero-copy first.** Documents are read through views; projections and filters
  never materialize maps.
- **Explicit ids.** Field ids, schema ids and versions are part of the on-disk
  contract and never derived from names.
- **Crash safety is a commit order, not a transaction.** WAL first, then the
  manifest; a document and its derived index entries share one WAL frame.
- **Bounded work per query.** Walks have depth limits; pagination is a key
  cursor; a global graph walk is opt-in and documented as O(nodes × relations).

## License

MIT.
