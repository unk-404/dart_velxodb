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
