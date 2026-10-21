## 0.1.0

- Initial workspace scaffold.
- `VXS` v1 binary format (`package:velxodb/serde.dart`):
  - 6-byte header, delta-encoded field keys (1 byte per field), zigzag varints;
  - `DocView` zero-copy reads, `DocCursor` allocation-free traversal;
  - `DocBuilder` writes field values straight into their final position, with a
    single-pass UTF-8 encoder for the common short-string path;
  - unknown fields can be re-emitted byte-for-byte for forward compatibility.
- Tests: round trips, UTF-8 edge cases (127/128-byte prefix boundary, surrogate
  pairs, >64KiB bodies), ordering enforcement, unknown-field preservation, fuzz.
- `StringView`: zero-copy UTF-8 comparison, prefix matching, CRC-based hashing
  and no-allocation equality against `String`.
- CRC-32C (`compute` + streaming `update`) and an optional per-document checksum
  trailer verified by `DocView.parseVerified`.
- `DocSink` batch writer: many documents into one buffer, no per-document
  allocation (~165 ns per 130 B document on AOT).
- Browser test suite (`dart test -p chrome`): JS integer semantics, handwritten
  UTF-8, CRC vectors and the batch writer all run in Chrome in CI.
- `DocView.validate(schema)` reports every structural problem at once;
  `DocView.project(schema, ids)` reads several fields in one scan (~3x faster
  than calling the individual getters).
- Structured fuzzing: mutated-but-valid documents only ever raise
  `VxsFormatException`.
- Storage layer (`package:velxodb/storage.dart`): self-delimiting blocks,
  checksummed WAL frames with crash recovery, and a minimal `StorageFile`
  abstraction with an in-memory implementation.
- Memtable with open addressing (~2.2x faster than `HashMap` for inserts and
  lookups), chunked document arena with stable views, and a synchronous write
  path (WAL → arena → memtable) with an async facade.
- Segments: immutable blocks plus a sorted primary index and a bloom filter,
  with a checksum over all metadata. `SegmentReader.find` is a bloom probe plus
  a binary search and returns a zero-copy document view.
- Directory and manifest: two alternating manifest slots with generations and
  checksums, plus `StorageEngine.flushSync()` and `compactSync()`.
- Real local files: `LocalStorageDirectory` (dart:io, synchronous), `autoSync`
  and `autoFlush` policies, and a web stub so the package still compiles to
  Wasm. 1e6 documents: 355k docs/s import, p50 1.5 us point reads, 1.21x disk.
- Segments are memory-mapped on open instead of copied; a 1e6-document database
  opens in 38 ms with a 27 MB resident-set increase. Closing an engine now
  unmaps segments and refuses further reads.
- Query layer: `Velxo.open`, `VelxoDatabase.collection`, a CRC-checked catalog
  with atomic temp-and-rename saves, and collections whose keys are prefixed
  with a stable two-byte id. Point reads, writes, deletes and sorted prefix
  scans merge the memtable with segments newest-first and honour tombstones.
- Streaming `CollectionCursor` with prefix/range bounds (segment cursors seek by
  binary search instead of scanning), predicate filters over zero-copy
  `DocView`s, and limits. Scan throughput roughly 4M docs/s.
- Memtable gains an index-based skip list next to the hash table: range scans
  seek in O(log n + k) instead of collecting and sorting the whole memtable
  (~17.5M docs/s for a 1k window over 50k entries), and flush now iterates in
  key order.
- Secondary indexes: `Collection.createIndex(fieldId, type)` allocates its own
  two-byte namespace and stores `[indexId][encodedValue][primaryKey]` entries.
  Integers use an order-preserving sign/magnitude encoding and strings use an
  escaped UTF-8 encoding, so prefix lookups are unambiguous. Indexes are
  maintained on write/delete (read-old, then delta), backfilled when created,
  persisted in catalog v2, and lookups verify the field value to tolerate
  non-transactional crashes.
- Index range scans (`lookupByIndexRangeSync`) and key-cursor pagination
  (`pageSync` with `after`/`next`) that does not drift when data changes.
- Query planner: a `Predicate` AST (`eq/lt/lte/gt/gte/between/and/or/not`),
  plans that pick an index for an indexable `and` branch and fall back to a scan
  otherwise, with a residual filter so results never depend on the plan.
  `collection.explainSync` reports the choice.
- Typed models: `DocumentSchema<T>` / `TypedCollection<T>` and a dev-time
  generator, now in its own package `velxodb_generator`, that turns a `ModelSpec`
  into plain Dart: `const` field ids, static `encodeInto`/`decodeFrom`, generated
  index creation and a typed collection opener built from static tear-offs. No
  schema objects, closures or reflection on the hot path (AOT: decode 366 ns vs
  392 ns through `DocumentSchema`). Generated code is committed as a fixture and
  compiled by the test suite.
- Schema versions and migrations: documents carry a schema version, generated
  models declare `documentSchemaVersion` and per-field defaults so a new version
  can read old documents, and `collection.migrateSync` / `migratePageSync` apply
  a validated version chain with resumable pages, idempotent re-runs and
  byte-preserving `copyFields` for unknown fields.
- Reference bindings: `collection.createReference(fieldId, 'target')` persists
  `(source, field, target, onDelete)` in catalog v3, creates the reverse index
  and applies `restrict` (default) or `cascade` when a target is deleted.
  Optional `enforceReferences` verifies targets on write. A document and all of
  its index entries now commit in one WAL frame via `engine.applyBatchSync`.
- Graph edges: `db.graph` stores typed, bidirectional edges
  (`[relationId][direction][length][node][node]`) with properties, written in one
  frame; relation names live in catalog v4. Adjacency is a prefix scan
  (~1.9M links/s, ~1.2M adjacency queries/s), `walk` does a depth-limited BFS
  across selected or all relations, and `danglingEdges` finds edges whose target
  document is gone.
- CRC-32C now uses slicing-by-16 (about 2.5x the byte-at-a-time throughput).
