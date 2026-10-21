import '../serde/schema.dart';
import '../storage/directory.dart';
import '../storage/engine.dart';
import '../storage/io/storage_io.dart';
import 'catalog.dart';
import 'collection.dart';
import 'graph.dart';
import 'index.dart';
import 'reference.dart';

/// An embedded database: one directory, one engine, many collections.
///
/// The catalog assigns each collection a stable two-byte prefix so a single
/// key/value engine can host all of them without colliding, allocates the same
/// kind of prefix to secondary indexes and relations, and records reference
/// bindings.
final class VelxoDatabase implements CollectionCatalog, RelationCatalog {
  VelxoDatabase._(this._directory, this._engine, this._catalog)
    : _catalogStore = CatalogStore(_directory);

  /// Opens (and creates) the database at [path].
  static VelxoDatabase openSync(String path) {
    final directory = LocalStorageDirectory(path);
    final catalog = CatalogStore(directory).loadSync();
    final engine = StorageEngine(directory: directory);
    engine.openSync();
    return VelxoDatabase._(directory, engine, catalog);
  }

  /// Async facade over [openSync].
  static Future<VelxoDatabase> open(String path) async => openSync(path);

  final SyncStorageDirectory _directory;
  final StorageEngine _engine;
  final CatalogStore _catalogStore;
  final Map<String, Collection> _collections = <String, Collection>{};
  Catalog _catalog;
  GraphStore? _graph;

  /// The underlying storage engine, for advanced use.
  StorageEngine get engine => _engine;

  /// Typed edges (graph) on top of the same engine.
  GraphStore get graph => _graph ??= GraphStore(_engine, this);

  /// Root directory.
  SyncStorageDirectory get directory => _directory;

  /// Names of every collection that has been created.
  List<String> get collectionNames =>
      <String>[for (final entry in _catalog.entries) entry.name];

  /// Returns (creating if needed) the collection called [name].
  Collection collection(String name) {
    final cached = _collections[name];
    if (cached != null) return cached;
    var id = _catalog.idOf(name);
    if (id == null) {
      _catalog = _catalog.withCollection(name);
      _catalogStore.saveSync(_catalog);
      id = _catalog.idOf(name)!;
    }
    final created = Collection(_engine, id, name, catalog: this);
    _collections[name] = created;
    return created;
  }

  @override
  IndexDefinition? indexFor(int collectionId, int fieldId) =>
      _catalog.indexFor(collectionId, fieldId);

  @override
  List<IndexDefinition> indexesFor(int collectionId) => <IndexDefinition>[
    for (final index in _catalog.indexes)
      if (index.collectionId == collectionId) index,
  ];

  @override
  IndexDefinition registerIndex(int collectionId, int fieldId, VxsType type) {
    final existing = _catalog.indexFor(collectionId, fieldId);
    if (existing != null) return existing;
    _catalog = _catalog.withIndex(collectionId, fieldId, type);
    _catalogStore.saveSync(_catalog);
    return _catalog.indexFor(collectionId, fieldId)!;
  }

  @override
  int? collectionIdOf(String name) => _catalog.idOf(name);

  @override
  ReferenceDefinition? referenceFor(int collectionId, int fieldId) =>
      _catalog.referenceFor(collectionId, fieldId);

  @override
  List<ReferenceDefinition> referencesFor(int collectionId) =>
      <ReferenceDefinition>[
        for (final reference in _catalog.references)
          if (reference.sourceCollectionId == collectionId) reference,
      ];

  @override
  List<ReferenceDefinition> referencesTo(int collectionId) =>
      <ReferenceDefinition>[
        for (final reference in _catalog.references)
          if (reference.targetCollectionId == collectionId) reference,
      ];

  @override
  ReferenceDefinition registerReference(
    int sourceCollectionId,
    int fieldId,
    int targetCollectionId,
    OnDelete onDelete,
  ) {
    final existing = _catalog.referenceFor(sourceCollectionId, fieldId);
    if (existing != null) return existing;
    _catalog = _catalog.withReference(
      sourceCollectionId,
      fieldId,
      targetCollectionId,
      onDelete,
    );
    _catalogStore.saveSync(_catalog);
    return _catalog.referenceFor(sourceCollectionId, fieldId)!;
  }

  @override
  int relationId(String name) {
    final existing = _catalog.relationIdOf(name);
    if (existing != null) return existing;
    _catalog = _catalog.withRelation(name);
    _catalogStore.saveSync(_catalog);
    return _catalog.relationIdOf(name)!;
  }

  @override
  int? existingRelationId(String name) => _catalog.relationIdOf(name);

  @override
  String? relationName(int id) => _catalog.relationName(id);

  @override
  List<String> relationNames() =>
      <String>[for (final relation in _catalog.relations) relation.name];

  /// Flushes the memtable into a segment.
  bool flushSync() => _engine.flushSync() != null;
  /// Async facade over [flushSync].
  Future<bool> flush() async => flushSync();

  /// Merges segments and drops tombstones.
  bool compactSync() => _engine.compactSync();

  /// Closes the engine and unmaps segments.
  Future<void> close() async => _engine.close();
}
