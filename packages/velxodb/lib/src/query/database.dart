import 'dart:typed_data';

import '../backup/backup.dart';
import '../errors.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import '../storage/background_segment.dart';
import '../storage/check.dart';
import '../storage/directory.dart';
import '../storage/engine.dart';
import '../storage/io/storage_io.dart';
import '../storage/maintenance.dart';
import '../upgrade_journal.dart';
import '../version.dart';
import 'catalog.dart';
import 'collection.dart';
import 'cursor.dart';
import 'fulltext.dart';
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
  VelxoDatabase._(
    this._directory,
    this._engine,
    this._catalog, {
    bool readOnly = false,
  }) : _readOnly = readOnly,
       _catalogStore = CatalogStore(_directory, readOnly: readOnly);

  final bool _readOnly;
  bool _closed = false;

  /// Whether this handle was opened read-only.
  bool get readOnly => _readOnly;

  /// Opens (and creates) the database at [path].
  ///
  /// The directory is locked exclusively: a second open of the same path fails
  /// fast instead of letting two writers corrupt the log. [autoFlush] bounds
  /// memtable memory; when it is crossed the write that crosses it pays for the
  /// flush. [durability] defaults to [Durability.batched]; pass
  /// [Durability.always] when a committed write must survive a power cut.
  /// With [deferredMaintenance], the flush/compaction that crosses a threshold
  /// runs after the triggering write returns instead of inline. With
  /// [backgroundFlush], the segment itself is built on a background isolate.
  static VelxoDatabase openSync(
    String path, {
    bool autoFlush = true,
    int maxMemtableBytes = 64 << 20,
    Durability durability = Durability.batched,
    bool autoCompact = true,
    int compactionThreshold = 4,
    bool deferredMaintenance = false,
    bool backgroundFlush = false,
    bool readOnly = false,
    bool repairIndexes = true,
  }) {
    final directory = LocalStorageDirectory(path, readOnly: readOnly);
    StorageEngine? engine;
    try {
      checkFormatCompatibility(directory, readOnly: readOnly);
      final catalog = CatalogStore(directory, readOnly: readOnly).loadSync();
      engine = StorageEngine(
        directory: directory,
        autoFlush: autoFlush,
        autoCompact: autoCompact,
        compactionThreshold: compactionThreshold,
        durability: durability,
        maxMemtableBytes: maxMemtableBytes,
        maintenanceScheduler: deferredMaintenance
            ? const MicrotaskMaintenanceScheduler()
            : null,
        backgroundSegmentBuilder: backgroundFlush
            ? buildSegmentInBackground
            : null,
        readOnly: readOnly,
      );
      engine.openSync();
      final database = VelxoDatabase._(
        directory,
        engine,
        catalog,
        readOnly: readOnly,
      );
      if (!readOnly && repairIndexes) database._finishPendingIndexes();
      return database;
    } on Object {
      // A failed open must not leak the directory lock.
      if (engine != null) {
        engine.closeSync();
      } else {
        directory.closeSync();
      }
      rethrow;
    }
  }

  /// Async facade over [openSync].
  static Future<VelxoDatabase> open(String path) async => openSync(path);

  /// Explicit major-format upgrade.
  ///
  /// Opening an older major without this raises
  /// [VelxoUpgradeRequiredException]. A real migration must back up first and
  /// switch atomically; no migration is registered while the format is 1.x, so
  /// this reports that no path exists instead of touching data.
  static void upgradeSync(String path) {
    final directory = LocalStorageDirectory(path);
    try {
      if (directory.existsSync(upgradeJournalFileName)) {
        throw const VelxoUpgradeRequiredException(
          'an upgrade journal is present; roll it back first',
        );
      }
      final stamp = readFormatStamp(directory);
      if (stamp == null) {
        writeFormatStamp(directory);
        return;
      }
      if (stamp.major > formatMajor) {
        throw VelxoIncompatibleException(
          'database format ${stamp.major}.${stamp.minor} is newer than '
          'this build',
        );
      }
      if (stamp.major < formatMajor) {
        throw VelxoUpgradeRequiredException(
          'no migration is registered from format ${stamp.major}.x',
        );
      }
      if (stamp.minor < formatMinor) writeFormatStamp(directory);
    } finally {
      directory.closeSync();
    }
  }

  /// Reverts an interrupted major upgrade using its in-place undo journal.
  ///
  /// The journal records the original byte ranges before the upgrade touched
  /// them; applying it in reverse restores the exact pre-upgrade files. It is
  /// a no-op when no journal exists.
  static void rollbackUpgradeSync(String path) {
    final directory = LocalStorageDirectory(path);
    try {
      UpgradeJournal(directory).rollback();
    } finally {
      directory.closeSync();
    }
  }

  final SyncStorageDirectory _directory;
  final StorageEngine _engine;
  final CatalogStore _catalogStore;
  final Map<String, Collection> _collections = <String, Collection>{};
  Catalog _catalog;
  GraphStore? _graph;

  /// The underlying storage engine, for advanced use.
  StorageEngine get engine => _engine;

  /// Typed edges (graph) on top of the same engine.
  GraphStore get graph {
    _checkOpen();
    return _graph ??= GraphStore(_engine, this);
  }

  /// Root directory.
  SyncStorageDirectory get directory => _directory;

  /// Names of every collection that has been created.
  List<String> get collectionNames => <String>[
    for (final entry in _catalog.entries) entry.name,
  ];

  /// Returns (creating if needed) the collection called [name].
  Collection collection(String name) {
    _checkOpen();
    final cached = _collections[name];
    if (cached != null) return cached;
    var id = _catalog.idOf(name);
    if (id == null) {
      if (_readOnly) {
        throw VelxoNotFoundException('no such collection: $name');
      }
      _catalog = _catalog.withCollection(name);
      _catalogStore.saveSync(_catalog);
      id = _catalog.idOf(name)!;
    }
    return _cachedCollection(id, name);
  }

  /// Returns the collection called [name] when it exists, without creating it.
  Collection? collectionOrNull(String name) {
    _checkOpen();
    final cached = _collections[name];
    if (cached != null) return cached;
    final id = _catalog.idOf(name);
    if (id == null) return null;
    return _cachedCollection(id, name);
  }

  Collection _cachedCollection(int id, String name) {
    final created = Collection(_engine, id, name, catalog: this);
    _collections[name] = created;
    return created;
  }

  void _checkOpen() {
    if (_closed) throw const VelxoClosedException('database is closed');
  }

  void _checkWritableCatalog() {
    _checkOpen();
    if (_readOnly) {
      throw const VelxoReadOnlyException('database is read-only');
    }
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
  IndexDefinition registerIndex(
    int collectionId,
    int fieldId,
    VxsType type, {
    bool ready = true,
  }) {
    _checkWritableCatalog();
    final existing = _catalog.indexFor(collectionId, fieldId);
    if (existing != null) {
      if (existing.ready == ready) return existing;
      _catalog = _catalog.withIndexReady(collectionId, fieldId, ready);
      _catalogStore.saveSync(_catalog);
      return _catalog.indexFor(collectionId, fieldId)!;
    }
    _catalog = _catalog.withIndex(collectionId, fieldId, type, ready: ready);
    _catalogStore.saveSync(_catalog);
    return _catalog.indexFor(collectionId, fieldId)!;
  }

  @override
  int? collectionIdOf(String name) => _catalog.idOf(name);

  @override
  TextIndexDefinition? textIndexFor(int collectionId, int fieldId) =>
      _catalog.textIndexFor(collectionId, fieldId);

  @override
  List<TextIndexDefinition> textIndexesFor(int collectionId) =>
      <TextIndexDefinition>[
        for (final textIndex in _catalog.textIndexes)
          if (textIndex.collectionId == collectionId) textIndex,
      ];

  @override
  TextIndexDefinition registerTextIndex(
    int collectionId,
    int fieldId,
    Tokenizer tokenizer, {
    bool ready = true,
  }) {
    _checkWritableCatalog();
    final existing = _catalog.textIndexFor(collectionId, fieldId);
    if (existing != null) {
      if (existing.ready == ready) return existing;
      _catalog = _catalog.withTextIndexReady(collectionId, fieldId, ready);
      _catalogStore.saveSync(_catalog);
      return _catalog.textIndexFor(collectionId, fieldId)!;
    }
    _catalog = _catalog.withTextIndex(
      collectionId,
      fieldId,
      tokenizer,
      ready: ready,
    );
    _catalogStore.saveSync(_catalog);
    return _catalog.textIndexFor(collectionId, fieldId)!;
  }

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
    _checkWritableCatalog();
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
    _checkWritableCatalog();
    final existing = _catalog.relationIdOf(name);
    if (existing != null) return existing;
    _catalog = _catalog.withRelation(name);
    _catalogStore.saveSync(_catalog);
    return _catalog.relationIdOf(name)!;
  }

  /// Finishes index backfills that a crash interrupted.
  ///
  /// An index is recorded as not ready before its backfill starts and marked
  /// ready afterwards. Opening writable therefore always leaves every declared
  /// index complete; a read-only open leaves it not ready and queries simply
  /// fall back to a scan.
  void _finishPendingIndexes() {
    for (final entry in List<CollectionEntry>.of(_catalog.entries)) {
      final pending =
          _catalog.indexes.any(
            (index) => index.collectionId == entry.id && !index.ready,
          ) ||
          _catalog.textIndexes.any(
            (index) => index.collectionId == entry.id && !index.ready,
          );
      if (!pending) continue;
      collection(entry.name).repairPendingIndexes();
    }
  }

  @override
  int? existingRelationId(String name) => _catalog.relationIdOf(name);

  @override
  String? relationName(int id) => _catalog.relationName(id);

  /// Whether a transaction is currently open.
  bool get inTransaction => _engine.inTransaction;

  /// Runs [body] as one atomic transaction.
  ///
  /// All writes made through this database (collections, indexes, references,
  /// graph edges) are buffered, visible to point reads inside [body], and
  /// committed as a single WAL frame. If [body] throws, nothing is applied.
  ///
  /// Single writer, no nesting, and scans do not see uncommitted writes.
  T transactionSync<T>(T Function() body) => _engine.transactionSync(body);

  /// Async facade over [transactionSync].
  Future<T> transaction<T>(T Function() body) async => transactionSync(body);

  /// fsyncs the WAL, making every committed frame durable.
  ///
  /// This is the group-commit point for [Durability.batched]: many writes are
  /// covered by one fsync.
  void syncNow() => _engine.syncNow();

  /// Async facade over [syncNow].
  Future<void> sync() async => syncNow();

  /// Waits for any in-flight background segment build.
  Future<void> waitForMaintenance() => _engine.waitForMaintenance();

  @override
  List<String> relationNames() => <String>[
    for (final relation in _catalog.relations) relation.name,
  ];

  /// Flushes the memtable into a segment.
  bool flushSync() => _engine.flushSync() != null;

  /// Async facade over [flushSync].
  Future<bool> flush() async => flushSync();

  /// Writes a consistent copy of this database into [target].
  ///
  /// A writable database is flushed first, so the copy has an empty WAL and a
  /// committed manifest. [target] must be empty (its backend may own a LOCK
  /// file); close it after the call. Read-only handles can be backed up without
  /// flushing.
  BackupReport backupSync(SyncStorageDirectory target) {
    _checkOpen();
    if (!_readOnly) {
      if (_engine.maintenanceScheduled) {
        throw const VelxoConflictException(
          'background maintenance is running; await db.waitForMaintenance() '
          'before taking a synchronous backup',
        );
      }
      flushSync();
    }
    return copyDatabase(_directory, target);
  }

  /// Waits for background maintenance, then takes a consistent backup.
  Future<BackupReport> backup(SyncStorageDirectory target) async {
    await waitForMaintenance();
    return backupSync(target);
  }

  /// Merges segments and drops tombstones.
  bool compactSync() => _engine.compactSync();

  /// Verifies the manifest, segments, catalog and (with [deep]) every index.
  ///
  /// Read-only diagnostic; nothing is repaired. [deep] scans every secondary
  /// and full-text posting and re-reads its document, which costs time
  /// proportional to the index size.
  CheckReport checkSync({bool deep = false}) {
    final engineReport = _engine.checkSync();
    final issues = List<CheckIssue>.of(engineReport.issues);
    final stats = Map<String, int>.of(engineReport.stats);
    stats['collections'] = _catalog.entries.length;
    stats['indexes'] = _catalog.indexes.length;
    stats['textIndexes'] = _catalog.textIndexes.length;
    stats['references'] = _catalog.references.length;
    stats['relations'] = _catalog.relations.length;

    if (deep) {
      var entries = 0;
      var postings = 0;
      for (final index in _catalog.indexes) {
        final result = _checkIndex(index);
        entries += result.checked;
        if (result.dangling > 0) {
          issues.add(
            CheckIssue(
              CheckSeverity.error,
              'dangling-index',
              'index on collection ${index.collectionId} field '
                  '${index.fieldId}: ${result.dangling} postings point at '
                  'missing documents',
            ),
          );
        }
        if (result.stale > 0) {
          issues.add(
            CheckIssue(
              CheckSeverity.error,
              'stale-index',
              'index on collection ${index.collectionId} field '
                  '${index.fieldId}: ${result.stale} postings disagree with '
                  'their document',
            ),
          );
        }
      }
      for (final textIndex in _catalog.textIndexes) {
        final result = _checkTextIndex(textIndex);
        postings += result.checked;
        if (result.dangling > 0) {
          issues.add(
            CheckIssue(
              CheckSeverity.error,
              'dangling-text-index',
              'text index on collection ${textIndex.collectionId} field '
                  '${textIndex.fieldId}: ${result.dangling} postings point at '
                  'missing documents',
            ),
          );
        }
        if (result.stale > 0) {
          issues.add(
            CheckIssue(
              CheckSeverity.error,
              'stale-text-index',
              'text index on collection ${textIndex.collectionId} field '
                  '${textIndex.fieldId}: ${result.stale} postings no longer '
                  'occur in their document',
            ),
          );
        }
      }
      stats['deepIndexEntries'] = entries;
      stats['deepTextPostings'] = postings;
    }
    return CheckReport(issues, stats);
  }

  ({int checked, int dangling, int stale}) _checkIndex(
    IndexDefinition definition,
  ) {
    final namespace = _namespace(definition.indexId);
    final cursor = buildCollectionCursor(
      engine: _engine,
      fullPrefix: namespace,
      lower: namespace,
      includeLower: true,
      upper: _prefixUpperBound(namespace),
      includeUpper: false,
    );
    var checked = 0;
    var dangling = 0;
    var stale = 0;
    while (cursor.moveNext()) {
      checked++;
      final raw = cursor.current.key; // [encodedValue][primaryKey]
      final length = definition.encodedValueLength(raw, 0);
      final primaryKey = Uint8List.sublistView(raw, length);
      final document = _engine.get(
        _composeKey(definition.collectionId, primaryKey),
      );
      if (document == null) {
        dangling++;
        continue;
      }
      final value = definition.readValue(DocView.parse(document.asUint8List()));
      if (value != _decodeIndexValue(definition, raw)) stale++;
    }
    return (checked: checked, dangling: dangling, stale: stale);
  }

  ({int checked, int dangling, int stale}) _checkTextIndex(
    TextIndexDefinition definition,
  ) {
    final namespace = _namespace(definition.indexId);
    final cursor = buildCollectionCursor(
      engine: _engine,
      fullPrefix: namespace,
      lower: namespace,
      includeLower: true,
      upper: _prefixUpperBound(namespace),
      includeUpper: false,
    );
    var checked = 0;
    var dangling = 0;
    var stale = 0;
    while (cursor.moveNext()) {
      checked++;
      final raw = cursor.current.key; // [encodedTerm][primaryKey]
      final term = decodeOrderedString(raw, 0);
      final primaryKey = Uint8List.sublistView(raw, term.length);
      final document = _engine.get(
        _composeKey(definition.collectionId, primaryKey),
      );
      if (document == null) {
        dangling++;
        continue;
      }
      final text =
          DocView.parse(document.asUint8List()).getString(definition.fieldId) ??
          '';
      if (!definition.tokenize(text).contains(term.value)) stale++;
    }
    return (checked: checked, dangling: dangling, stale: stale);
  }

  static Object? _decodeIndexValue(IndexDefinition definition, Uint8List raw) {
    switch (definition.type) {
      case VxsType.string:
        return decodeOrderedString(raw, 0).value;
      case VxsType.boolean:
        return raw[0] == 1;
      case VxsType.int32:
      case VxsType.int64:
        final negative = raw[0] == 0x00;
        var magnitude = 0;
        for (var i = 1; i <= 8; i++) {
          final byte = negative ? raw[i] ^ 0xFF : raw[i];
          magnitude = (magnitude << 8) | byte;
        }
        return negative ? -magnitude : magnitude;
      default:
        return null;
    }
  }

  static Uint8List _namespace(int id) =>
      Uint8List.fromList(<int>[(id >> 8) & 0xFF, id & 0xFF]);

  static Uint8List _composeKey(int collectionId, Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (collectionId >> 8) & 0xFF;
    out[1] = collectionId & 0xFF;
    out.setRange(2, out.length, key);
    return out;
  }

  static Uint8List? _prefixUpperBound(Uint8List prefix) {
    final out = Uint8List.fromList(prefix);
    for (var i = out.length - 1; i >= 0; i--) {
      if (out[i] != 0xFF) {
        out[i]++;
        return Uint8List.sublistView(out, 0, i + 1);
      }
    }
    return null;
  }

  /// Closes the engine and unmaps segments.
  ///
  /// [flush] writes the memtable to a segment first. A graceful shutdown should
  /// pass `flush: true`: reopening then only reads the manifest and maps
  /// segments, instead of replaying the whole WAL (1.5 s vs 11 ms for 100k
  /// unflushed documents in the comparison harness).
  Future<void> close({bool flush = false}) async {
    closeSync(flush: flush);
  }

  /// Synchronous close, used by the worker isolate.
  void closeSync({bool flush = false}) {
    if (_closed) return;
    _closed = true;
    if (flush && !_readOnly) flushSync();
    _engine.closeSync();
  }
}
