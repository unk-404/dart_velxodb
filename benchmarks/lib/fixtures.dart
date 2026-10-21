/// Deterministic fixtures shared by every suite and scenario.
///
/// Everything here is pure data plus in-memory doubles, so a suite cannot
/// accidentally depend on the filesystem, the wall clock or a global RNG.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

/// Writes the 130 B chat message into [builder] through the single-doc API.
///
/// The same five fields in the same order as [chatDocument], so the serde and
/// storage benchmarks measure the identical payload.
void writeChat(DocBuilder builder) {
  builder
    ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
    ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
    ..putInt(3, 7)
    ..putInt(4, 1750000000000)
    ..putString(5, '在吗？今天下午三点开会，别忘了带材料。');
}

/// Writes the same message through the batch sink (no per-doc allocation).
void writeChatSink(DocSink sink) {
  sink
    ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
    ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
    ..putInt(3, 7)
    ..putInt(4, 1750000000000)
    ..putString(5, '在吗？今天下午三点开会，别忘了带材料。');
}

/// A realistic 130 B chat message: id, conversation, sender, timestamp, text.
///
/// This is the document used by the storage/engine/compare workloads.
Bytes chatDocument() {
  final builder = DocBuilder(schemaId: 1, schemaVersion: 1);
  writeChat(builder);
  return builder.finish();
}

/// The smaller 3-field message used by the query layer.
Bytes compactDocument() =>
    (DocBuilder(schemaId: 1)
          ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
          ..putInt(2, 7)
          ..putString(3, '在吗？今天下午三点开会，别忘了带材料。'))
        .finish();

/// A document carrying a small indexable field (field 2).
Bytes indexedDocument(int value) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
          ..putInt(2, value))
        .finish();

/// A document whose field 2 holds the key of a document in another collection.
Bytes referringDocument(String targetKey, {String tag = ''}) {
  final builder = DocBuilder(schemaId: 1)
    ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
    ..putString(2, targetKey)
    ..putString(3, '在吗？今天下午三点开会，别忘了带材料。');
  if (tag.isNotEmpty) builder.putString(4, tag);
  return builder.finish();
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// `key-0000`: the general collection key shape.
Uint8List keyOf(int index) =>
    Uint8List.fromList('key-${index.toString().padLeft(4, '0')}'.codeUnits);

/// `seg-000`: segment keys.
Uint8List segmentKey(int index) =>
    Uint8List.fromList('seg-${index.toString().padLeft(3, '0')}'.codeUnits);

/// `flush-0000`: keys seeded into a flushed segment.
Uint8List flushKey(int index) =>
    Uint8List.fromList('flush-${index.toString().padLeft(4, '0')}'.codeUnits);

/// `user-000`: reference targets.
Uint8List userKey(int index) =>
    Uint8List.fromList('user-${index.toString().padLeft(3, '0')}'.codeUnits);

/// `msg-0000`: documents that reference a user.
Uint8List messageKey(int index) =>
    Uint8List.fromList('msg-${index.toString().padLeft(4, '0')}'.codeUnits);

/// Keys for one collection, in ascending order.
List<Uint8List> keysFor(int count) => <Uint8List>[
  for (var i = 0; i < count; i++) keyOf(i),
];

// ---------------------------------------------------------------------------
// Deterministic RNG
// ---------------------------------------------------------------------------

/// xorshift32, so a scenario's read pattern is reproducible and identical
/// between engines and between runs.
final class Rng {
  /// Creates an RNG from a fixed seed.
  Rng([int seed = 0x9E3779B9]) : _state = seed & 0xFFFFFFFF;

  int _state;

  /// Next non-negative 31-bit value.
  int next() {
    var state = _state;
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    _state = state & 0xFFFFFFFF;
    return state & 0x7FFFFFFF;
  }

  /// Next index in `[0, bound)`.
  int nextIndex(int bound) => next() % bound;
}

// ---------------------------------------------------------------------------
// No-I/O storage doubles
// ---------------------------------------------------------------------------

/// Counts bytes but never stores them.
///
/// This is what makes the engine micro benchmark measure the WAL/arena/memtable
/// machine and nothing else. It is deliberately *not* a durability test: see
/// `scenarios/durability_bench.dart` for real file writes and fsync policy.
final class CountingStorageFile implements SyncStorageFile {
  int _length = 0;

  /// Bytes appended so far.
  int get appended => _length;

  @override
  int get lengthSync => _length;

  @override
  void appendSync(Uint8List bytes) => _length += bytes.length;

  @override
  Uint8List readAtSync(int offset, int length) =>
      throw UnsupportedError('no-I/O fixture');

  @override
  void truncateSync(int length) => _length = length;

  @override
  void flushSync() {}

  @override
  Uint8List readAllSync() => Uint8List(0);

  @override
  void writeAllSync(Uint8List bytes) => _length = bytes.length;

  @override
  void closeSync() {}
}

/// Hands out the counting WAL file and refuses everything else.
final class CountingDirectory implements SyncStorageDirectory {
  /// The single counting file behind the WAL name.
  final CountingStorageFile wal = CountingStorageFile();

  @override
  SyncStorageFile openSync(String name, {bool create = true}) {
    if (name == StorageEngine.walFileName) return wal;
    throw UnsupportedError('no-I/O fixture does not support $name');
  }

  @override
  bool existsSync(String name) => false;

  @override
  void deleteSync(String name) {}

  @override
  void renameSync(String from, String to) {}

  @override
  List<String> listSync() => const <String>[];

  @override
  MappedFile mapSync(String name) => throw UnsupportedError('no-I/O fixture');

  @override
  void closeSync() {}
}

// ---------------------------------------------------------------------------
// In-memory catalogs
// ---------------------------------------------------------------------------

/// Catalog that keeps indexes, full-text indexes and reference bindings in
/// memory, so a benchmark needs no database directory.
final class MemoryCatalog implements CollectionCatalog {
  final List<IndexDefinition> _indexes = <IndexDefinition>[];
  final List<TextIndexDefinition> _textIndexes = <TextIndexDefinition>[];
  final List<ReferenceDefinition> _references = <ReferenceDefinition>[];
  final Map<String, int> _collectionIds = <String, int>{};

  /// Registers a collection name so `createReference` can resolve it.
  void addCollection(String name, int id) => _collectionIds[name] = id;

  @override
  IndexDefinition? indexFor(int collectionId, int fieldId) {
    for (final definition in _indexes) {
      if (definition.collectionId == collectionId &&
          definition.fieldId == fieldId) {
        return definition;
      }
    }
    return null;
  }

  @override
  List<IndexDefinition> indexesFor(int collectionId) => <IndexDefinition>[
    for (final definition in _indexes)
      if (definition.collectionId == collectionId) definition,
  ];

  @override
  IndexDefinition registerIndex(
    int collectionId,
    int fieldId,
    VxsType type, {
    bool ready = true,
  }) {
    final definition = IndexDefinition(
      collectionId: collectionId,
      fieldId: fieldId,
      type: type,
      indexId: 500 + collectionId * 100 + fieldId,
      ready: ready,
    );
    _indexes.removeWhere(
      (IndexDefinition existing) =>
          existing.collectionId == collectionId && existing.fieldId == fieldId,
    );
    _indexes.add(definition);
    return definition;
  }

  @override
  int? collectionIdOf(String name) => _collectionIds[name];

  @override
  ReferenceDefinition? referenceFor(int collectionId, int fieldId) {
    for (final definition in _references) {
      if (definition.sourceCollectionId == collectionId &&
          definition.fieldId == fieldId) {
        return definition;
      }
    }
    return null;
  }

  @override
  List<ReferenceDefinition> referencesFor(int collectionId) =>
      <ReferenceDefinition>[
        for (final definition in _references)
          if (definition.sourceCollectionId == collectionId) definition,
      ];

  @override
  List<ReferenceDefinition> referencesTo(int targetCollectionId) =>
      <ReferenceDefinition>[
        for (final definition in _references)
          if (definition.targetCollectionId == targetCollectionId) definition,
      ];

  @override
  ReferenceDefinition registerReference(
    int sourceCollectionId,
    int fieldId,
    int targetCollectionId,
    OnDelete onDelete,
  ) {
    final definition = ReferenceDefinition(
      sourceCollectionId: sourceCollectionId,
      fieldId: fieldId,
      targetCollectionId: targetCollectionId,
      onDelete: onDelete,
    );
    _references.removeWhere(
      (ReferenceDefinition existing) =>
          existing.sourceCollectionId == sourceCollectionId &&
          existing.fieldId == fieldId,
    );
    _references.add(definition);
    return definition;
  }

  @override
  TextIndexDefinition? textIndexFor(int collectionId, int fieldId) {
    for (final definition in _textIndexes) {
      if (definition.collectionId == collectionId &&
          definition.fieldId == fieldId) {
        return definition;
      }
    }
    return null;
  }

  @override
  List<TextIndexDefinition> textIndexesFor(int collectionId) =>
      <TextIndexDefinition>[
        for (final definition in _textIndexes)
          if (definition.collectionId == collectionId) definition,
      ];

  @override
  TextIndexDefinition registerTextIndex(
    int collectionId,
    int fieldId,
    Tokenizer tokenizer, {
    bool ready = true,
  }) {
    final definition = TextIndexDefinition(
      collectionId: collectionId,
      fieldId: fieldId,
      indexId: 700 + collectionId * 100 + fieldId,
      tokenizer: tokenizer,
      ready: ready,
    );
    _textIndexes.removeWhere(
      (TextIndexDefinition existing) =>
          existing.collectionId == collectionId && existing.fieldId == fieldId,
    );
    _textIndexes.add(definition);
    return definition;
  }
}

/// In-memory relation registry for the graph benchmark.
final class MemoryRelations implements RelationCatalog {
  final Map<String, int> _ids = <String, int>{};

  @override
  int relationId(String name) =>
      _ids.putIfAbsent(name, () => 900 + _ids.length);

  @override
  int? existingRelationId(String name) => _ids[name];

  @override
  String? relationName(int id) {
    for (final entry in _ids.entries) {
      if (entry.value == id) return entry.key;
    }
    return null;
  }

  @override
  List<String> relationNames() => _ids.keys.toList();
}

// ---------------------------------------------------------------------------
// Filesystem helpers for scenarios
// ---------------------------------------------------------------------------

/// A fresh empty directory under `.tmp/<name>_<pid>`.
///
/// Callers must delete it; [withTempDir] does that even on failure.
Directory createTempDir(String name) {
  final dir = Directory('${Directory.current.path}/.tmp/${name}_$pid');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  return dir;
}

/// Runs [body] against a fresh temporary directory and always cleans it up.
Future<T> withTempDir<T>(
  String name,
  Future<T> Function(Directory dir) body,
) async {
  final dir = createTempDir(name);
  try {
    return await body(dir);
  } finally {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Total bytes of a regular file tree, for on-disk size reporting.
int directoryBytes(Directory root) {
  if (!root.existsSync()) return 0;
  var bytes = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) bytes += entity.lengthSync();
  }
  return bytes;
}
