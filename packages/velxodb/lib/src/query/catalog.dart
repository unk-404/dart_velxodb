import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/schema.dart';
import '../serde/vxs.dart';
import '../storage/directory.dart';
import 'index.dart';
import 'reference.dart';

/// First byte of the catalog file.
const int catalogMagic = 0x43;

/// Catalog format version written by this build.
const int catalogVersion = 3;

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

/// Maps collection names to stable numeric prefixes and records indexes.
///
/// Prefixes let one engine host many collections while keeping keys ordered: a
/// collection's keys are exactly `[id high, id low, key...]`. Indexes get their
/// own id from the same space and use it as their namespace prefix.
final class Catalog {
  /// Creates a catalog.
  Catalog(
    List<CollectionEntry> entries, [
    List<IndexDefinition> indexes = const [],
    List<ReferenceDefinition> references = const [],
  ]) : entries = List<CollectionEntry>.unmodifiable(entries),
       indexes = List<IndexDefinition>.unmodifiable(indexes),
       references = List<ReferenceDefinition>.unmodifiable(references);

  /// An empty catalog.
  Catalog.empty()
    : entries = const <CollectionEntry>[],
      indexes = const <IndexDefinition>[],
      references = const <ReferenceDefinition>[];

  /// Registered collections.
  final List<CollectionEntry> entries;

  /// Registered secondary indexes.
  final List<IndexDefinition> indexes;

  /// Registered reference bindings.
  final List<ReferenceDefinition> references;

  /// Finds the id of [name], or `null`.
  int? idOf(String name) {
    for (final entry in entries) {
      if (entry.name == name) return entry.id;
    }
    return null;
  }

  /// Finds the index for `(collectionId, fieldId)`, or `null`.
  IndexDefinition? indexFor(int collectionId, int fieldId) {
    for (final index in indexes) {
      if (index.collectionId == collectionId && index.fieldId == fieldId) {
        return index;
      }
    }
    return null;
  }

  /// Next free id across collections and indexes.
  int nextId() {
    var next = 1;
    for (final entry in entries) {
      if (entry.id >= next) next = entry.id + 1;
    }
    for (final index in indexes) {
      if (index.indexId >= next) next = index.indexId + 1;
    }
    return next;
  }

  /// Returns a catalog with [name] added.
  Catalog withCollection(String name, {int? id}) {
    if (idOf(name) != null) return this;
    final next = id ?? nextId();
    if (next > 0xFFFE) {
      throw StateError('collection id space exhausted');
    }
    return Catalog(<CollectionEntry>[
      ...entries,
      CollectionEntry(next, name),
    ], indexes, references);
  }

  /// Returns a catalog with an index added for `(collectionId, fieldId)`.
  Catalog withIndex(int collectionId, int fieldId, VxsType type) {
    final existing = indexFor(collectionId, fieldId);
    if (existing != null) return this;
    final next = nextId();
    if (next > 0xFFFE) {
      throw StateError('index id space exhausted');
    }
    return Catalog(entries, <IndexDefinition>[
      ...indexes,
      IndexDefinition(
        collectionId: collectionId,
        fieldId: fieldId,
        type: type,
        indexId: next,
      ),
    ], references);
  }

  /// Finds the reference for `(collectionId, fieldId)`, or `null`.
  ReferenceDefinition? referenceFor(int collectionId, int fieldId) {
    for (final reference in references) {
      if (reference.sourceCollectionId == collectionId &&
          reference.fieldId == fieldId) {
        return reference;
      }
    }
    return null;
  }

  /// Returns a catalog with a reference binding added.
  Catalog withReference(
    int sourceCollectionId,
    int fieldId,
    int targetCollectionId,
    OnDelete onDelete,
  ) {
    if (referenceFor(sourceCollectionId, fieldId) != null) return this;
    return Catalog(entries, indexes, <ReferenceDefinition>[
      ...references,
      ReferenceDefinition(
        sourceCollectionId: sourceCollectionId,
        fieldId: fieldId,
        targetCollectionId: targetCollectionId,
        onDelete: onDelete,
      ),
    ]);
  }

  /// Serializes the catalog.
  Uint8List encode() {
    var size = 8 + 4;
    for (final entry in entries) {
      size += 4 + entry.name.length;
    }
    size += 4 + indexes.length * 7;
    size += 4 + references.length * 7;
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
    VxsLe.w32(out, pos, indexes.length);
    pos += 4;
    for (final index in indexes) {
      VxsLe.w16(out, pos, index.collectionId);
      pos += 2;
      VxsLe.w16(out, pos, index.fieldId);
      pos += 2;
      out[pos++] = index.type.index;
      VxsLe.w16(out, pos, index.indexId);
      pos += 2;
    }
    VxsLe.w32(out, pos, references.length);
    pos += 4;
    for (final reference in references) {
      VxsLe.w16(out, pos, reference.sourceCollectionId);
      pos += 2;
      VxsLe.w16(out, pos, reference.fieldId);
      pos += 2;
      VxsLe.w16(out, pos, reference.targetCollectionId);
      pos += 2;
      out[pos++] = _onDeleteCode(reference.onDelete);
    }
    VxsLe.w32(out, pos, VxsCrc32c.compute(out, 0, pos));
    return out;
  }

  /// Parses a catalog. Version 1 files (no indexes) are still readable.
  static Catalog decode(Uint8List bytes) {
    if (bytes.length < 12) {
      throw const VxsFormatException('catalog too short');
    }
    if (bytes[0] != catalogMagic) {
      throw const VxsFormatException('bad catalog header');
    }
    final version = bytes[1];
    if (version < 1 || version > catalogVersion) {
      throw VxsFormatException('unsupported catalog version $version');
    }
    final bodyEnd = bytes.length - 4;
    if (VxsLe.u32(bytes, bodyEnd) != VxsCrc32c.compute(bytes, 0, bodyEnd)) {
      throw const VxsFormatException('catalog checksum mismatch');
    }
    final count = VxsLe.u32(bytes, 4);
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
    final indexes = <IndexDefinition>[];
    if (version >= 2) {
      if (pos + 4 > bodyEnd) {
        throw const VxsFormatException('truncated catalog index list');
      }
      final indexCount = VxsLe.u32(bytes, pos);
      pos += 4;
      for (var i = 0; i < indexCount; i++) {
        if (pos + 7 > bodyEnd) {
          throw const VxsFormatException('truncated catalog index');
        }
        final collectionId = VxsLe.u16(bytes, pos);
        pos += 2;
        final fieldId = VxsLe.u16(bytes, pos);
        pos += 2;
        final typeCode = bytes[pos++];
        if (typeCode >= VxsType.values.length) {
          throw VxsFormatException('unknown index type $typeCode');
        }
        final indexId = VxsLe.u16(bytes, pos);
        pos += 2;
        indexes.add(
          IndexDefinition(
            collectionId: collectionId,
            fieldId: fieldId,
            type: VxsType.values[typeCode],
            indexId: indexId,
          ),
        );
      }
    }
    final references = <ReferenceDefinition>[];
    if (version >= 3) {
      if (pos + 4 > bodyEnd) {
        throw const VxsFormatException('truncated catalog reference list');
      }
      final referenceCount = VxsLe.u32(bytes, pos);
      pos += 4;
      for (var i = 0; i < referenceCount; i++) {
        if (pos + 7 > bodyEnd) {
          throw const VxsFormatException('truncated catalog reference');
        }
        final source = VxsLe.u16(bytes, pos);
        pos += 2;
        final fieldId = VxsLe.u16(bytes, pos);
        pos += 2;
        final target = VxsLe.u16(bytes, pos);
        pos += 2;
        final code = bytes[pos++];
        if (code > OnDelete.setNull.index) {
          throw VxsFormatException('unknown onDelete code $code');
        }
        references.add(
          ReferenceDefinition(
            sourceCollectionId: source,
            fieldId: fieldId,
            targetCollectionId: target,
            onDelete: OnDelete.values[code],
          ),
        );
      }
    }
    if (pos != bodyEnd) {
      throw const VxsFormatException('trailing bytes in catalog');
    }
    return Catalog(entries, indexes, references);
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

int _onDeleteCode(OnDelete value) => switch (value) {
  OnDelete.restrict => 0,
  OnDelete.cascade => 1,
  OnDelete.setNull => 2,
};
