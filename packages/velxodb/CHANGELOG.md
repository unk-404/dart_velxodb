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
- CRC-32C now uses slicing-by-16 (about 2.5x the byte-at-a-time throughput).
