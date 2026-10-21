import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/vxs.dart';
import '../storage/directory.dart';

/// First byte of the catalog file.
const int catalogMagic = 0x43;

/// Catalog format version.
const int catalogVersion = 1;

/// Name of the catalog file.
const String catalogFileName = 'CATALOG';

/// One collection registered in the catalog.
final class CollectionEntry {
  /// Creates an entry.
  const CollectionEntry(this.id, this.name);

  /// Stable numeric id used as the key prefix.
  final int id;

  /// Collection name.
  final String name;
}

/// Maps collection names to stable numeric prefixes.
///
/// Prefixes let one engine host many collections while keeping keys ordered: a
/// collection's keys are exactly `[id high, id low, key...]`.
final class Catalog {
  /// Creates a catalog from [entries].
  Catalog(List<CollectionEntry> entries)
    : entries = List<CollectionEntry>.unmodifiable(entries);

  /// An empty catalog.
  Catalog.empty() : entries = const <CollectionEntry>[];

  /// Registered collections.
  final List<CollectionEntry> entries;

  /// Finds the id of [name], or `null`.
  int? idOf(String name) {
    for (final entry in entries) {
      if (entry.name == name) return entry.id;
    }
    return null;
  }

  /// Returns a catalog with [name] added, assigning the next free id.
  Catalog withCollection(String name, {int? id}) {
    if (idOf(name) != null) return this;
    var next = id ?? 1;
    for (final entry in entries) {
      if (entry.id >= next) next = entry.id + 1;
    }
    if (next > 0xFFFE) {
      throw StateError('collection id space exhausted');
    }
    return Catalog(<CollectionEntry>[
      ...entries,
      CollectionEntry(next, name),
    ]);
  }

  /// Serializes the catalog.
  Uint8List encode() {
    var size = 8;
    for (final entry in entries) {
      size += 4 + entry.name.length;
    }
    size += 4;
    final out = Uint8List(size);
    out[0] = catalogMagic;
    out[1] = catalogVersion;
    VxsLe.w16(out, 2, 0);
    VxsLe.w32(out, 4, entries.length);
    var pos = 8;
    for (final entry in entries) {
      VxsLe.w16(out, pos, entry.id);
      pos += 2;
      VxsLe.w16(out, pos, entry.name.length);
      pos += 2;
      final nameBytes = entry.name.codeUnits;
      out.setRange(pos, pos + nameBytes.length, nameBytes);
      pos += nameBytes.length;
    }
    VxsLe.w32(out, pos, VxsCrc32c.compute(out, 0, pos));
    return out;
  }

  /// Parses a catalog.
  static Catalog decode(Uint8List bytes) {
    if (bytes.length < 12) {
      throw const VxsFormatException('catalog too short');
    }
    if (bytes[0] != catalogMagic || bytes[1] != catalogVersion) {
      throw const VxsFormatException('bad catalog header');
    }
    final count = VxsLe.u32(bytes, 4);
    final bodyEnd = bytes.length - 4;
    if (VxsLe.u32(bytes, bodyEnd) != VxsCrc32c.compute(bytes, 0, bodyEnd)) {
      throw const VxsFormatException('catalog checksum mismatch');
    }
    var pos = 8;
    final entries = <CollectionEntry>[];
    for (var i = 0; i < count; i++) {
      if (pos + 4 > bodyEnd) {
        throw const VxsFormatException('truncated catalog entry');
      }
      final id = VxsLe.u16(bytes, pos);
      pos += 2;
      final nameLength = VxsLe.u16(bytes, pos);
      pos += 2;
      if (pos + nameLength > bodyEnd) {
        throw const VxsFormatException('truncated catalog entry');
      }
      final name = String.fromCharCodes(bytes, pos, pos + nameLength);
      pos += nameLength;
      entries.add(CollectionEntry(id, name));
    }
    if (pos != bodyEnd) {
      throw const VxsFormatException('trailing bytes in catalog');
    }
    return Catalog(entries);
  }
}

/// Persists the catalog atomically (write temp, then rename).
final class CatalogStore {
  /// Creates a store over [directory].
  CatalogStore(this.directory);

  /// Directory holding the catalog.
  final SyncStorageDirectory directory;

  static const String _tempName = 'CATALOG.tmp';

  /// Loads the catalog, or an empty one when the database is fresh.
  Catalog loadSync() {
    if (!directory.existsSync(catalogFileName)) return Catalog.empty();
    final file = directory.openSync(catalogFileName, create: false);
    try {
      final bytes = file.readAllSync();
      if (bytes.isEmpty) return Catalog.empty();
      return Catalog.decode(bytes);
    } on VxsFormatException {
      throw StateError('catalog is corrupt; refusing to open the database');
    } finally {
      file.closeSync();
    }
  }

  /// Writes [catalog] atomically.
  void saveSync(Catalog catalog) {
    final temp = directory.openSync(_tempName);
    try {
      temp.writeAllSync(catalog.encode());
      temp.flushSync();
    } finally {
      temp.closeSync();
    }
    directory.renameSync(_tempName, catalogFileName);
  }
}
