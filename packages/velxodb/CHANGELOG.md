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
- Object storage: a generic `ObjectStore` SPI (`get`/`put`/`delete`/`deleteMany`/
  `list`), `SimulatedObjectStore` with request/byte counters, and an
  `ObjectStoreEngine` whose segments and manifest are objects, whose write
  batches are WAL objects, and whose segments are fetched lazily through an LRU
  cache. Benchmark (`benchmark/object_store_bench.dart`): 200k-doc import in 412
  requests, churn of 120k changes in 123 requests, reopen in 2 requests.
- Backend compatibility test: a segment written by the local engine opens in the
  object-store engine and vice versa, proving the format is I/O-agnostic.
- `VelxoDatabase.close(flush: true)` for graceful shutdown: reopening then reads
  the manifest and maps segments instead of replaying the whole WAL (11 ms vs
  1.5 s for 100k unflushed documents).
- Full-text primitives: a `Tokenizer` SPI (`WordTokenizer`, `NgramTokenizer`),
  inverted postings stored as `[indexId][encodedTerm][primaryKey]` in the same
  engine, maintained in the same WAL frame as the document, backfilled on
  creation, and queried with `any`/`all` modes plus per-hit verification.
  ~482k docs/s on 64 hits (JIT, including verification).
- Transactions: `db.transactionSync` buffers all writes (collections, indexes,
  references, graph), makes them visible to point reads, and commits the set as
  one WAL frame; an exception applies nothing. Single writer, no nesting, no
  MVCC. Verified with a torn-frame test.
- Safety defaults: the local directory takes an exclusive `LOCK` (a second open
  fails), `VelxoDatabase.openSync` auto-flushes at 64 MB by default, and
  `close(flush: true)` gives a fast graceful reopen.
- Durability tiers: `Durability.always` fsyncs every WAL frame (one fsync per
  batch or transaction), the default `Durability.batched` fsyncs on flush, close
  and `db.sync()` (the group-commit point), and `Durability.none` leaves
  durability to the caller. Segments now auto-compact at 4 by default.
- Integrity check: `db.checkSync(deep: true)` verifies the manifest, segment
  blocks (CRC + document parse), orphan files, and every secondary/full-text
  posting against its document. Typed errors replace ad-hoc `StateError`s:
  `VelxoLockedException`, `VelxoCorruptException`, `VelxoClosedException`,
  `VelxoConflictException`, `VelxoNotFoundException`.
- Corruption handling: if manifest files exist but none decodes, opening now
  raises `VelxoCorruptException` instead of silently starting empty; a failed
  open releases the directory lock.
- Crash-point matrix: deterministic tests tear every byte of a transaction WAL
  frame, ignore a segment written before its manifest commit, fall back from a
  torn newest manifest, replay the pre-truncate WAL idempotently, and report a
  truncated referenced segment as `VelxoCorruptException`. Runs as its own CI
  job.
- `checkSync` no longer opens a second WAL handle (which closed the shared
  handle in in-memory directories), and opening a segment that fails to decode
  now raises `VelxoCorruptException`.
- Deferred maintenance: `VelxoDatabase.openSync(deferredMaintenance: true)`
  moves the threshold-triggered flush and compaction off the write call through
  a `MaintenanceScheduler` (microtask today, worker isolate later). Memory may
  overshoot the threshold briefly; past 4x it flushes inline. WAL replay keeps
  pending writes safe across close or crash.
- Background flush: `VelxoDatabase.openSync(backgroundFlush: true)` builds the
  segment on a background isolate (`Isolate.run`, snapshot transferred via
  `TransferableTypedData`). Writes continue during the build; the memtable and
  WAL reset only when no write landed after the snapshot, otherwise newer writes
  shadow the committed segment. `waitForMaintenance()` awaits the build. The
  web build falls back to an inline build.
- Worker isolate: `VelxoWorker.open(path)` owns the only `VelxoDatabase` in a
  dedicated isolate and exposes an async RPC facade (`put`/`get`/`delete`/
  `page`/`flush`/`check`/`waitForMaintenance`/`close`). Requests from any
  isolate are queued and executed one at a time, preserving the single-writer
  contract while callers stay concurrent. Typed exceptions cross the boundary.
  The web build exports an unsupported stub.
- Read-only opens: `VelxoDatabase.openSync(path, readOnly: true)` replays the
  WAL without truncating, rejects engine writes and catalog changes with
  `VelxoReadOnlyException`, and refuses to create a missing database or
  collection. Readers take a shared directory lock (many readers coexist);
  writers stay exclusive.
- Backup/restore: `db.backupSync(targetDirectory)` flushes and copies a
  consistent file set (skipping LOCK) into an empty target;
  `copyDatabase(source, target)` restores it. Both work on storage directories,
  so the same code fits local and future object-store targets. Full copy only,
  not incremental.
- Index range: removed the redundant per-hit document decode and value
  comparison; the cursor bounds already enforce the range. The 12k-hit
  comparison drops from 12.9 ms to 11.0 ms (isar is still ~1.25x faster).
- Versioning: added the normative `VERSIONING.md` policy and a `FORMAT` stamp
  (major, minor, CRC-32C). A patch must be byte-identical and API-frozen, a
  minor is transparent inside the same major, and a major requires the explicit
  `VelxoDatabase.upgradeSync` with a downgrade path. New typed errors:
  `VelxoIncompatibleException`, `VelxoUpgradeRequiredException`.
- Major-upgrade undo journal: `UpgradeJournal` records original byte ranges
  (and full content of deleted files) before an upgrade mutates them; rollback
  applies them in reverse, so the downgrade path is an in-place reverse diff,
  not a copy of the database. An interrupted upgrade is refused on open and
  reverted with `VelxoDatabase.rollbackUpgradeSync(path)`.
- Web/OPFS foundation: `OpfsObjectStore` implements the async `ObjectStore`
  over blit's chunked OPFS `BytesFile`, with an append-only crash-safe key index
  (intent before object, torn tail ignored). The existing `ObjectStoreEngine`
  runs on top of it with the same segment/manifest bytes as the VM. Chrome tests
  cover put/get/list/delete, a 300 KiB object, and an engine write/flush/reopen.
- Single-writer lock now also works on POSIX: an in-process registry of
  canonical paths complements the OS lock, which is process-wide there, so a
  second open inside the same process is rejected on Linux and macOS too.
- READMEs rewritten (workspace and package).
- CRC-32C now uses slicing-by-16 (about 2.5x the byte-at-a-time throughput).
