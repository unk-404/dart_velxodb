import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/vxs.dart';
import 'directory.dart';

/// First byte of a manifest.
const int manifestMagic = 0x4D;

/// Manifest format version.
const int manifestVersion = 1;

/// One immutable segment referenced by a manifest.
final class SegmentInfo {
  /// Describes a segment file.
  const SegmentInfo({
    required this.name,
    required this.entryCount,
    required this.byteLength,
  });

  /// File name inside the directory.
  final String name;

  /// Number of index entries (documents plus tombstones).
  final int entryCount;

  /// Segment size in bytes.
  final int byteLength;

  /// Serialized size of this record.
  int get encodedSize => 2 + name.length + 4 + 4;

  @override
  String toString() => 'SegmentInfo($name, $entryCount entries, $byteLength B)';
}

/// Immutable description of the database contents.
///
/// A manifest is written whole: two fixed slots alternate, each carrying a
/// monotonically increasing generation. Opening picks the valid slot with the
/// highest generation, so a torn write can only ever lose the newest
/// transaction, never corrupt an older state.
final class Manifest {
  /// Creates a manifest.
  Manifest({required this.generation, required List<SegmentInfo> segments})
    : segments = List<SegmentInfo>.unmodifiable(segments);

  /// Monotonic generation.
  final int generation;

  /// Segments in write order (oldest first).
  final List<SegmentInfo> segments;

  /// Serializes the manifest.
  Uint8List encode() {
    var size = 12;
    for (final segment in segments) {
      size += segment.encodedSize;
    }
    size += 4; // checksum
    final out = Uint8List(size);
    out[0] = manifestMagic;
    out[1] = manifestVersion;
    VxsLe.w16(out, 2, 0);
    VxsLe.w32(out, 4, generation);
    VxsLe.w32(out, 8, segments.length);
    var pos = 12;
    for (final segment in segments) {
      VxsLe.w16(out, pos, segment.name.length);
      pos += 2;
      final nameBytes = segment.name.codeUnits;
      out.setRange(pos, pos + nameBytes.length, nameBytes);
      pos += nameBytes.length;
      VxsLe.w32(out, pos, segment.entryCount);
      pos += 4;
      VxsLe.w32(out, pos, segment.byteLength);
      pos += 4;
    }
    VxsLe.w32(out, pos, VxsCrc32c.compute(out, 0, pos));
    return out;
  }

  /// Parses a manifest. Throws [VxsFormatException] when invalid.
  static Manifest decode(Uint8List bytes) {
    if (bytes.length < 16) {
      throw const VxsFormatException('manifest too short');
    }
    if (bytes[0] != manifestMagic || bytes[1] != manifestVersion) {
      throw const VxsFormatException('bad manifest header');
    }
    final generation = VxsLe.u32(bytes, 4);
    final count = VxsLe.u32(bytes, 8);
    final bodyEnd = bytes.length - 4;
    if (VxsLe.u32(bytes, bodyEnd) != VxsCrc32c.compute(bytes, 0, bodyEnd)) {
      throw const VxsFormatException('manifest checksum mismatch');
    }
    var pos = 12;
    final segments = <SegmentInfo>[];
    for (var i = 0; i < count; i++) {
      if (pos + 2 > bodyEnd) {
        throw const VxsFormatException('truncated manifest entry');
      }
      final nameLength = VxsLe.u16(bytes, pos);
      pos += 2;
      if (pos + nameLength + 8 > bodyEnd) {
        throw const VxsFormatException('truncated manifest entry');
      }
      final name = String.fromCharCodes(bytes, pos, pos + nameLength);
      pos += nameLength;
      final entryCount = VxsLe.u32(bytes, pos);
      pos += 4;
      final byteLength = VxsLe.u32(bytes, pos);
      pos += 4;
      segments.add(
        SegmentInfo(
          name: name,
          entryCount: entryCount,
          byteLength: byteLength,
        ),
      );
    }
    if (pos != bodyEnd) {
      throw const VxsFormatException('trailing bytes in manifest');
    }
    return Manifest(generation: generation, segments: segments);
  }
}

/// Stores the manifest in two alternating slots.
final class ManifestStore {
  /// Creates a store over [directory].
  ManifestStore(this.directory);

  /// Directory holding the slots.
  final SyncStorageDirectory directory;

  /// Names of the two slots, indexed by `generation % 2`.
  static const List<String> slotNames = <String>[
    'MANIFEST-0',
    'MANIFEST-1',
  ];

  /// Loads the newest valid manifest, or `null` when the database is empty.
  Manifest? loadSync() {
    Manifest? best;
    for (var slot = 0; slot < slotNames.length; slot++) {
      if (!directory.existsSync(slotNames[slot])) continue;
      try {
        final bytes = directory.openSync(slotNames[slot]).readAllSync();
        if (bytes.isEmpty) continue;
        final manifest = Manifest.decode(bytes);
        if (best == null || manifest.generation > best.generation) {
          best = manifest;
        }
      } on VxsFormatException {
        // A torn slot is expected after a crash; the other slot is authoritative.
        continue;
      }
    }
    return best;
  }

  /// Writes [segments] as the next generation into the alternating slot.
  Manifest saveSync(List<SegmentInfo> segments) {
    final current = loadSync();
    final generation = (current?.generation ?? 0) + 1;
    final manifest = Manifest(generation: generation, segments: segments);
    final file = directory.openSync(slotNames[generation % 2]);
    file.writeAllSync(manifest.encode());
    file.flushSync();
    return manifest;
  }
}
