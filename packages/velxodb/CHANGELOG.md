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
