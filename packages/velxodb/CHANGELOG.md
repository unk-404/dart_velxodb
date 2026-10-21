## 1.0.0 - 2026-10-21

First public release. VelxoDB is an embedded document database with a local
memory-mapped engine, an object-store engine built from the same bytes, and a
browser (OPFS) stack.

### Storage

- `VXS` v1 document format: 6-byte header, delta-encoded field ids (one byte per
  field), zigzag varints, zero-copy `DocView`/`DocCursor`, forward-compatible
  unknown fields and an optional CRC-32C trailer. `DocSink` writes many documents
  into one buffer without per-document allocation.
- Synchronous local engine: framed, checksummed WAL → memtable → immutable
  segments → two-slot manifest. Segments are memory-mapped; point reads are a
  bloom probe, a binary search and a zero-copy view.
- Document blocks carry CRC-32C and are verified lazily: the first read that
  touches a block checks it once, and compaction refuses to rewrite a corrupt
  block instead of laundering it. The segment index, block table and bloom
  filter have their own checksum.
- Memtable combines an open-addressed hash table with a skip list, so point
  lookups and narrow ordered ranges both avoid a scan.
- Auto-flush (64 MB default), auto-compaction (four segments default),
  deferred maintenance and background-isolate segment builds.
- Stale first manifests recover from the WAL; a WAL with no manifest is not
  treated as an empty database.
- `Durability.always` / `batched` / `none`, with `db.sync()` as the group-commit
  point.
- Integrity check: `db.checkSync(deep: true)` verifies the manifest, every block,
  orphan segments, and every secondary and full-text posting against its
  document.
- Typed errors: locked, corrupt, closed, conflict, constraint, not found,
  read-only, incompatible, upgrade-required.

### Query layer

- Collections with stable two-byte key prefixes; ordered scans, prefix scans,
  key-cursor pagination and streaming cursors.
- Multi-document transactions: all writes are buffered, visible to point reads
  and to index lookups inside the block, and committed as one WAL frame. Single
  writer, no nesting, no MVCC; scans do not see uncommitted writes.
- Secondary indexes on int32, int64, string and boolean fields, with
  order-preserving value encodings, equality and range lookups, and per-hit
  verification. A crash during creation leaves the index marked "not ready";
  the next writable open finishes it, and queries fall back to a scan.
- Query planner with `Predicate` (`eq`, ranges, `and`/`or`/`not`) and
  `explainSync`; index plans still honour the query's key range.
- Reference bindings with a reverse index and `restrict` / `cascade` deletion
  policies. A cascade is one frame, cycle-safe and depth-limited; optional
  `enforceReferences` validates targets on write, and `validateReferences()`
  audits a bulk load afterwards.
- Typed graph edges: forward and reverse edges in one frame, adjacency scans,
  depth-limited BFS with cycle detection and `danglingEdges`.
- Full-text primitives: pluggable tokenizers (`WordTokenizer`, `NgramTokenizer`),
  inverted postings maintained in the document's frame, `any`/`all` queries and
  per-hit verification.
- Schema versions with resumable, idempotent migrations and byte-preserving
  copies of unknown fields.
- Typed models: `DocumentSchema` / `TypedCollection` and the separate
  `velxodb_generator` package, which emits plain Dart with `const` field ids and
  static codecs. No reflection and no runtime code generation.
- Catalog v6: names are UTF-8 (v5 and older truncated non-ASCII names), and each
  index records whether its backfill completed. Saves are atomic
  (temporary file + rename).

### Object storage and Web

- `ObjectStore` SPI (`get`, `put`, `delete`, `deleteMany`, `list`) and
  `SimulatedObjectStore` with request/byte counters. The engine's request shape
  is one `PUT` per write batch, one segment `PUT` plus one manifest `PUT` per
  flush, and a manifest `GET` plus a WAL `LIST` on open.
- `ObjectStoreEngine`: segments and manifest are immutable objects, write batches
  are small WAL objects, segments are fetched lazily with an LRU cache, and a
  missing listed WAL object is reported instead of silently dropped.
- `package:velxodb/testing.dart` provides `ObjectStoreConformance`, a contract
  suite for custom backends.
- OPFS: `OpfsObjectStore` over blit chunked files, with an append-only key index
  that is written after the object (so a crash leaves an unreferenced object,
  never a listed key with no object) and truncated at the first torn record.
- `VelxoWebDatabase` / `WebCollection`: CRUD, ordered scans, pages, equality and
  range indexes, atomic write transactions, reference validation and
  `restrict`/`cascade`, typed graph edges with BFS, and full-text search. Every
  mutation is a single WAL object; the database takes the same `FORMAT` gate as
  the VM.
- Writes and backfills are serialized inside the Web database, so two concurrent
  reads-modify-writes cannot lose index postings. `collection.put` inside a
  `writeTxn` body is rejected instead of committing behind the caller's back.
- Web cross-tab exclusion: the OPFS database takes an origin-wide Web Lock
  (`navigator.locks`), so a second tab opening the same root is refused; an
  in-page registry rejects a second handle in the same page. Browsers without
  the API fall back to the in-page guard.

### Concurrency and operations

- `VelxoWorker.open(path)` runs the database in a dedicated isolate and exposes
  an async RPC facade. Requests from any isolate are queued and executed one at
  a time.
- Read-only opens replay the WAL without truncating and reject all writes,
  including catalog changes; readers share the directory lock.
- Backup/restore copies a consistent file set, skips the lock and the format
  temporary file, refuses a database with an unfinished upgrade journal, and
  streams large segments.
- `A.B.C` versioning policy (`VERSIONING.md`), an atomically replaced `FORMAT`
  stamp, an explicit major-upgrade entry point and an in-place undo journal with
  exact-length restoration for the downgrade path.
- Crash-point matrix in CI: every torn byte of a transaction frame, a segment
  written before its manifest, a torn newest manifest and a corrupted block.

### Known limits

Single writer per database and one isolate per writable handle; POSIX advisory
locks are process-wide, so a second writable open from another isolate in the
same process is not detected (documented and planned). No MVCC: scans do not see
uncommitted writes and a slow worker read blocks the writer. Values are copied
across the worker boundary. Backup is a full copy. The object-store backend has
no multi-writer CAS yet. Compression and geo/vector types are not part of 1.0.0.
