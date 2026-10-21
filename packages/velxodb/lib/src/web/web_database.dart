import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../errors.dart';
import '../query/catalog.dart';
import '../query/fulltext.dart';
import '../query/graph.dart';
import '../query/index.dart';
import '../query/reference.dart';
import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/string_view.dart';
import '../serde/view.dart';
import '../storage/io/opfs_store.dart';
import '../storage/io/opfs_write_lock.dart';
import '../storage/object_engine.dart';
import '../storage/wal.dart';
import '../version.dart';

/// One document returned by [WebCollection.scan] and index lookups.
typedef WebEntry = ({Uint8List key, Bytes value});

/// Async Web database over OPFS.
///
/// Collections, document CRUD, ordered scans, key-cursor pages, secondary
/// indexes (equality and range), write transactions, reference bindings,
/// graph edges and full-text search, with the same document encoding,
/// collection prefixes and index key layout as the VM.
///
/// Every mutation — a document plus its index entries, text postings and
/// reference checks — is one WAL object, so it either lands whole or not at
/// all. The database root also carries the same `FORMAT` stamp as the VM, so a
/// major upgrade is refused here too.
final class VelxoWebDatabase {
  VelxoWebDatabase._(this._store, this._engine, this._catalog);

  /// Opens (or creates) a database under the OPFS logical [root].
  ///
  /// The `prefix` must be unique per database inside [root]; it is the object
  /// name prefix (`db/` by default).
  static Future<VelxoWebDatabase> open({
    String root = 'velxodb',
    String prefix = 'db/',
    bool repairIndexes = true,
  }) async {
    // One tab per database: OPFS has no cross-tab exclusion, so the Web Lock is
    // what keeps two tabs from interleaving writes into one WAL.
    final lock = await OpfsWriteLock.acquire('velxodb:$root:$prefix');
    OpfsObjectStore? store;
    try {
      store = await OpfsObjectStore.open(root: root);
      await _checkFormat(store, prefix);
      final engine = ObjectStoreEngine(store: store, prefix: prefix);
      await engine.open();
      final raw = await store.get('${prefix}CATALOG');
      final catalog = raw == null ? Catalog.empty() : Catalog.decode(raw);
      final database = VelxoWebDatabase._(store, engine, catalog).._lock = lock;
      if (repairIndexes) await database._finishPendingIndexes();
      return database;
    } on Object {
      await store?.close();
      await lock.release();
      rethrow;
    }
  }

  static String _formatKey(String prefix) => '${prefix}FORMAT';

  /// Enforces the same A/B/C policy as the local engine, using an object as the
  /// database root marker.
  static Future<void> _checkFormat(OpfsObjectStore store, String prefix) async {
    final key = _formatKey(prefix);
    final raw = await store.get(key);
    if (raw == null) {
      // A database created before stamping: treat it as 1.0 and stamp it.
      await store.put(key, encodeFormatStamp());
      return;
    }
    final stamp = decodeFormatStamp(raw);
    if (stamp.major > formatMajor) {
      throw VelxoIncompatibleException(
        'database format ${stamp.major}.${stamp.minor} is newer than this '
        'build ($formatMajor.$formatMinor)',
      );
    }
    if (stamp.major < formatMajor) {
      throw const VelxoUpgradeRequiredException(
        'database format is older than this build; there is no object-store '
        'upgrade path yet',
      );
    }
    if (stamp.minor < formatMinor) {
      await store.put(key, encodeFormatStamp());
    }
  }

  final OpfsObjectStore _store;
  final ObjectStoreEngine _engine;
  Catalog _catalog;
  final Map<String, WebCollection> _collections = <String, WebCollection>{};
  WebGraph? _graph;
  OpfsWriteLock? _lock;

  /// Transaction nesting depth, used to make `collection.put` inside a
  /// `writeTxn` body fail loudly instead of committing behind the caller's back.
  int _txDepth = 0;

  /// Serializes read-modify-write mutations. The engine is single-writer; an
  /// async `put` must not interleave with another `put` or a backfill between
  /// its read and its commit, or index postings would be lost or duplicated.
  Future<void> _writeTail = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    if (_txDepth > 0) {
      throw const VelxoConflictException(
        'a transaction is running; finish it before creating or repairing '
        'indexes or references',
      );
    }
    final previous = _writeTail;
    final done = Completer<void>();
    _writeTail = done.future;
    await previous;
    try {
      return await body();
    } finally {
      done.complete();
    }
  }

  /// Opens (creating when needed) a collection.
  Future<WebCollection> collection(String name) async {
    final cached = _collections[name];
    if (cached != null) return cached;
    var id = _catalog.idOf(name);
    if (id == null) {
      _catalog = _catalog.withCollection(name);
      await _saveCatalog();
      id = _catalog.idOf(name)!;
    }
    final collection = WebCollection._(this, _engine, id);
    _collections[name] = collection;
    return collection;
  }

  Future<void> _saveCatalog() =>
      _store.put('${_engine.prefix}CATALOG', _catalog.encode());

  WebCollection? _collectionById(int id) {
    for (final entry in _catalog.entries) {
      if (entry.id == id) {
        return _collections.putIfAbsent(
          entry.name,
          () => WebCollection._(this, _engine, id),
        );
      }
    }
    return null;
  }

  /// Async graph over the same objects.
  WebGraph get graph => _graph ??= WebGraph._(this, _engine);

  /// Flushes the memtable into an object-store segment.
  Future<void> flush() async {
    await _engine.flush();
  }

  /// Runs [body] and commits every buffered put/delete as one WAL object.
  ///
  /// If [body] throws, nothing is written. `transaction.get` sees the pending
  /// writes; collection-level reads (scan, page, index lookup) observe the
  /// committed state. Reference checks and cascades run against the
  /// transaction's view. Call `transaction.put` / `transaction.delete` inside
  /// [body]; calling `collection.put` there throws, because it would commit
  /// immediately and could not be rolled back.
  Future<T> writeTxn<T>(
    Future<T> Function(WebTransaction transaction) body,
  ) async {
    if (_txDepth > 0) {
      throw const VelxoConflictException(
        'nested writeTxn is not supported; use the open transaction',
      );
    }
    return _exclusive(() async {
      _txDepth++;
      try {
        final transaction = WebTransaction._(this, _engine);
        final result = await body(transaction);
        await transaction.commit();
        return result;
      } finally {
        _txDepth--;
      }
    });
  }

  /// Alias for [writeTxn].
  Future<T> transaction<T>(
    Future<T> Function(WebTransaction transaction) body,
  ) => writeTxn(body);

  /// Finishes backfills that a crash interrupted.
  Future<void> _finishPendingIndexes() async {
    for (final entry in List<CollectionEntry>.of(_catalog.entries)) {
      final pending =
          _catalog.indexes.any(
            (index) => index.collectionId == entry.id && !index.ready,
          ) ||
          _catalog.textIndexes.any(
            (index) => index.collectionId == entry.id && !index.ready,
          );
      if (!pending) continue;
      final collection = await this.collection(entry.name);
      await collection._repairPendingIndexes();
    }
  }

  /// Flushes and closes the engine, the OPFS store and the cross-tab lock.
  Future<void> close({bool flush = true}) async {
    try {
      await _engine.close(flush: flush);
      await _store.close();
    } finally {
      await _lock?.release();
      _lock = null;
    }
  }
}

/// Async collection: CRUD, ordered scan, pagination and secondary indexes.
final class WebCollection {
  WebCollection._(this._db, this._engine, this._id);

  static final Bytes _empty = DocBuilder(schemaId: 1).finish();

  final VelxoWebDatabase _db;
  final ObjectStoreEngine _engine;
  final int _id;

  /// Whether writes verify that referenced documents exist.
  ///
  /// Off by default, matching the VM: a bulk import may write referrers before
  /// targets, and a cycle cannot be created in one pass when every insert is
  /// checked. Deletion policies are always enforced.
  bool enforceReferences = false;

  /// Stable collection id.
  int get id => _id;

  Uint8List _key(Uint8List key) => _compose(_id, key);

  Uint8List get _prefix =>
      Uint8List.fromList(<int>[(_id >> 8) & 0xFF, _id & 0xFF]);

  static Uint8List _compose(int collectionId, Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (collectionId >> 8) & 0xFF;
    out[1] = collectionId & 0xFF;
    out.setRange(2, out.length, key);
    return out;
  }

  static Uint8List? _upper(Uint8List prefix) {
    final out = Uint8List.fromList(prefix);
    for (var i = out.length - 1; i >= 0; i--) {
      if (out[i] != 0xFF) {
        out[i]++;
        return Uint8List.sublistView(out, 0, i + 1);
      }
    }
    return null;
  }

  /// Reads one document.
  Future<Bytes?> get(Uint8List key) => _engine.get(_key(key));

  /// Inserts or replaces one document.
  ///
  /// The document, its index entries and its text postings are written as one
  /// WAL object. A missing reference rejects the write when
  /// [enforceReferences] is enabled.
  Future<void> put(Uint8List key, Bytes document) async {
    if (_db._txDepth > 0) {
      throw const VelxoConflictException(
        'inside writeTxn use transaction.put; collection.put would commit '
        'outside the transaction',
      );
    }
    await _db.writeTxn((transaction) => transaction.put(this, key, document));
  }

  /// Deletes one document, applying reference policies.
  ///
  /// `restrict` rejects the whole delete, `cascade` deletes every referrer in
  /// the same WAL object, and a reference cycle is broken by a visited set.
  Future<void> delete(Uint8List key) async {
    if (_db._txDepth > 0) {
      throw const VelxoConflictException(
        'inside writeTxn use transaction.delete; collection.delete would '
        'commit outside the transaction',
      );
    }
    await _db.writeTxn((transaction) => transaction.delete(this, key));
  }

  /// Creates (and backfills) a full-text index on [fieldId].
  ///
  /// The catalog marks the index as not ready while the backfill runs, so an
  /// interrupted build is repaired on the next open instead of answering
  /// queries with a partial index. Backfills and writes share one lock, so a
  /// concurrent put cannot resurrect a stale posting.
  Future<void> createTextIndex(
    int fieldId, {
    Tokenizer tokenizer = const WordTokenizer(),
  }) => _db._exclusive(() => _createTextIndex(fieldId, tokenizer));

  Future<void> _createTextIndex(int fieldId, Tokenizer tokenizer) async {
    if (_db._catalog.textIndexFor(_id, fieldId) != null) return;
    _db._catalog = _db._catalog.withTextIndex(
      _id,
      fieldId,
      tokenizer,
      ready: false,
    );
    await _db._saveCatalog();
    await _backfillText(fieldId);
    _db._catalog = _db._catalog.withTextIndexReady(_id, fieldId, true);
    await _db._saveCatalog();
  }

  /// Searches a full-text index.
  Future<List<WebEntry>> searchText(
    int fieldId,
    String query, {
    TextQueryMode mode = TextQueryMode.any,
    int? limit,
  }) async {
    final definition = _db._catalog.textIndexFor(_id, fieldId);
    if (definition == null) {
      throw VelxoNotFoundException('no text index on field $fieldId');
    }
    if (!definition.ready) {
      throw VelxoConflictException(
        'text index on field $fieldId is still being built',
      );
    }
    final terms = definition.tokenize(query).toSet();
    Set<String>? candidates;
    for (final term in terms) {
      final prefix = definition.termPrefix(term);
      final postings = await _engine.scanRange(
        start: prefix,
        end: _upper(prefix),
      );
      final keys = <String>{
        for (final posting in postings)
          String.fromCharCodes(posting.key.sublist(prefix.length)),
      };
      candidates = candidates == null
          ? keys
          : (mode == TextQueryMode.all
                ? candidates.intersection(keys)
                : candidates.union(keys));
      if (mode == TextQueryMode.all && candidates.isEmpty) break;
    }
    final out = <WebEntry>[];
    for (final encoded in candidates ?? const <String>{}) {
      final primaryKey = Uint8List.fromList(encoded.codeUnits);
      final document = await get(primaryKey);
      if (document == null) continue;
      final text =
          DocView.parse(document.asUint8List()).getString(fieldId) ?? '';
      final tokens = definition.tokenize(text).toSet();
      final matches = mode == TextQueryMode.all
          ? terms.every(tokens.contains)
          : terms.any(tokens.contains);
      if (!matches) continue;
      out.add((key: primaryKey, value: document));
      if (limit != null && out.length >= limit) break;
    }
    out.sort(
      (a, b) => StringView.compareRanges(
        a.key,
        0,
        a.key.length,
        b.key,
        0,
        b.key.length,
      ),
    );
    return out;
  }

  /// Binds [fieldId] to [targetName] and indexes the field.
  Future<ReferenceDefinition> createReference(
    int fieldId,
    String targetName, {
    OnDelete onDelete = OnDelete.restrict,
  }) => _db._exclusive(() async {
    final targetId = _db._catalog.idOf(targetName);
    if (targetId == null) {
      throw VelxoNotFoundException(
        'target collection "$targetName" does not exist',
      );
    }
    await _createIndex(fieldId, VxsType.string);
    _db._catalog = _db._catalog.withReference(_id, fieldId, targetId, onDelete);
    await _db._saveCatalog();
    return _db._catalog.referenceFor(_id, fieldId)!;
  });

  /// Scans the collection in key order.
  Future<List<WebEntry>> scan({
    Uint8List? start,
    Uint8List? end,
    bool includeStart = true,
    bool includeEnd = false,
    int? limit,
  }) async {
    final entries = await _engine.scanRange(
      start: start == null ? _prefix : _key(start),
      end: end == null ? _upper(_prefix) : _key(end),
      includeStart: start == null ? true : includeStart,
      includeEnd: includeEnd,
      limit: limit,
    );
    return <WebEntry>[
      for (final entry in entries)
        (key: Uint8List.fromList(entry.key.sublist(2)), value: entry.document!),
    ];
  }

  /// Returns one page plus the key to resume after.
  Future<({List<WebEntry> entries, Uint8List? next})> page({
    Uint8List? after,
    int limit = 100,
  }) async {
    final entries = await _engine.scanRange(
      start: after == null ? _prefix : _key(after),
      end: _upper(_prefix),
      includeStart: after == null,
      limit: limit,
    );
    final mapped = <WebEntry>[
      for (final entry in entries)
        (key: Uint8List.fromList(entry.key.sublist(2)), value: entry.document!),
    ];
    return (
      entries: mapped,
      next: mapped.length == limit ? mapped.last.key : null,
    );
  }

  /// Creates (and backfills) an index on [fieldId].
  Future<void> createIndex(int fieldId, VxsType type) =>
      _db._exclusive(() => _createIndex(fieldId, type));

  Future<void> _createIndex(int fieldId, VxsType type) async {
    final existing = _db._catalog.indexFor(_id, fieldId);
    if (existing != null) {
      if (existing.type != type) {
        throw ArgumentError(
          'field $fieldId is already indexed as ${existing.type.name}',
        );
      }
      if (!existing.ready) {
        await _backfillIndex(fieldId);
        _db._catalog = _db._catalog.withIndexReady(_id, fieldId, true);
        await _db._saveCatalog();
      }
      return;
    }
    _db._catalog = _db._catalog.withIndex(_id, fieldId, type, ready: false);
    await _db._saveCatalog();
    await _backfillIndex(fieldId);
    _db._catalog = _db._catalog.withIndexReady(_id, fieldId, true);
    await _db._saveCatalog();
  }

  Future<void> _repairPendingIndexes() async {
    for (final definition in List<IndexDefinition>.of(_db._catalog.indexes)) {
      if (definition.collectionId != _id || definition.ready) continue;
      await _backfillIndex(definition.fieldId);
      _db._catalog = _db._catalog.withIndexReady(_id, definition.fieldId, true);
      await _db._saveCatalog();
    }
    for (final definition in List<TextIndexDefinition>.of(
      _db._catalog.textIndexes,
    )) {
      if (definition.collectionId != _id || definition.ready) continue;
      await _backfillText(definition.fieldId);
      _db._catalog = _db._catalog.withTextIndexReady(
        _id,
        definition.fieldId,
        true,
      );
      await _db._saveCatalog();
    }
  }

  Future<void> _backfillIndex(int fieldId) async {
    final definition = _db._catalog.indexFor(_id, fieldId);
    if (definition == null) return;
    final ops = <WalOp>[];
    for (final entry in await scan()) {
      final value = definition.readValue(
        DocView.parse(entry.value.asUint8List()),
      );
      if (value == null) continue;
      ops.add(
        WalOp.put(definition.entryKey(value, entry.key), _empty.asUint8List()),
      );
      if (ops.length >= 1000) {
        await _engine.applyBatch(ops);
        ops.clear();
      }
    }
    if (ops.isNotEmpty) await _engine.applyBatch(ops);
  }

  Future<void> _backfillText(int fieldId) async {
    final definition = _db._catalog.textIndexFor(_id, fieldId);
    if (definition == null) return;
    final ops = <WalOp>[];
    for (final entry in await scan()) {
      final text =
          DocView.parse(entry.value.asUint8List()).getString(fieldId) ?? '';
      for (final term in definition.tokenize(text).toSet()) {
        ops.add(
          WalOp.put(definition.entryKey(term, entry.key), _empty.asUint8List()),
        );
        if (ops.length >= 1000) {
          await _engine.applyBatch(ops);
          ops.clear();
        }
      }
    }
    if (ops.isNotEmpty) await _engine.applyBatch(ops);
  }

  IndexDefinition _index(int fieldId) {
    final definition = _db._catalog.indexFor(_id, fieldId);
    if (definition == null) {
      throw VelxoNotFoundException('no index on field $fieldId');
    }
    if (!definition.ready) {
      throw VelxoConflictException(
        'index on field $fieldId is still being built',
      );
    }
    return definition;
  }

  /// Finds documents whose indexed [fieldId] equals [value].
  Future<List<WebEntry>> lookupByIndex(int fieldId, Object value) async {
    final definition = _index(fieldId);
    final prefix = definition.valuePrefix(value);
    final entries = await _engine.scanRange(start: prefix, end: _upper(prefix));
    final out = <WebEntry>[];
    for (final entry in entries) {
      final primaryKey = Uint8List.fromList(entry.key.sublist(prefix.length));
      final document = await _engine.get(_key(primaryKey));
      if (document == null) continue;
      final actual = definition.readValue(
        DocView.parse(document.asUint8List()),
      );
      if (actual != value) continue;
      out.add((key: primaryKey, value: document));
    }
    return out;
  }

  /// Finds documents whose indexed [fieldId] lies in a value range.
  Future<List<WebEntry>> lookupByIndexRange(
    int fieldId, {
    Object? from,
    Object? to,
    bool includeFrom = true,
    bool includeTo = false,
    int? limit,
  }) async {
    final definition = _index(fieldId);
    final namespace = definition.namespacePrefix;
    final lower = from == null
        ? namespace
        : (includeFrom
              ? definition.valuePrefix(from)
              : _upper(definition.valuePrefix(from))!);
    final upper = to == null
        ? _upper(namespace)!
        : (includeTo
              ? _upper(definition.valuePrefix(to))!
              : definition.valuePrefix(to));
    final entries = await _engine.scanRange(start: lower, end: upper);
    final out = <WebEntry>[];
    for (final entry in entries) {
      final encodedLength = definition.encodedValueLength(entry.key, 2);
      final primaryKey = Uint8List.fromList(
        entry.key.sublist(2 + encodedLength),
      );
      final document = await _engine.get(_key(primaryKey));
      if (document == null) continue;
      final value = definition.readValue(DocView.parse(document.asUint8List()));
      if (value == null) continue;
      if (from != null) {
        final comparison = definition.compareValues(value, from);
        if (comparison < 0 || (comparison == 0 && !includeFrom)) continue;
      }
      if (to != null) {
        final comparison = definition.compareValues(value, to);
        if (comparison > 0 || (comparison == 0 && !includeTo)) continue;
      }
      out.add((key: primaryKey, value: document));
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }
}

/// Async typed graph over OPFS.
final class WebGraph {
  WebGraph._(this._db, this._engine);

  static final Bytes _empty = DocBuilder(schemaId: 1).finish();

  final VelxoWebDatabase _db;
  final ObjectStoreEngine _engine;

  /// Registers (or resolves) a relation id.
  Future<int> relationId(String relation) async {
    var id = _db._catalog.relationIdOf(relation);
    if (id == null) {
      _db._catalog = _db._catalog.withRelation(relation);
      await _db._saveCatalog();
      id = _db._catalog.relationIdOf(relation)!;
    }
    return id;
  }

  /// Links two nodes in one WAL object (forward + reverse edge).
  Future<void> link(
    String relation,
    NodeRef from,
    NodeRef to, {
    Bytes? properties,
  }) async {
    final id = await relationId(relation);
    final props = (properties ?? _empty).asUint8List();
    final fromBytes = from.encode();
    final toBytes = to.encode();
    await _engine.applyBatch(<WalOp>[
      WalOp.put(_edgeKey(id, 1, fromBytes, toBytes), props),
      WalOp.put(_edgeKey(id, 2, toBytes, fromBytes), props),
    ]);
  }

  /// Removes both directions of an edge.
  Future<void> unlink(String relation, NodeRef from, NodeRef to) async {
    final id = _db._catalog.relationIdOf(relation);
    if (id == null) return;
    final fromBytes = from.encode();
    final toBytes = to.encode();
    await _engine.applyBatch(<WalOp>[
      WalOp.delete(_edgeKey(id, 1, fromBytes, toBytes)),
      WalOp.delete(_edgeKey(id, 2, toBytes, fromBytes)),
    ]);
  }

  /// Outgoing edges of [node].
  Future<List<GraphEdge>> outgoing(String relation, NodeRef node) =>
      _scan(relation, node, EdgeDirection.outbound);

  /// Incoming edges of [node].
  Future<List<GraphEdge>> incoming(String relation, NodeRef node) =>
      _scan(relation, node, EdgeDirection.inbound);

  /// Breadth-first walk, capped at [maxDepth].
  Future<GraphWalk> walk(
    NodeRef start, {
    int maxDepth = 2,
    Set<String>? relations,
    EdgeDirection direction = EdgeDirection.outbound,
  }) async {
    final names =
        relations ??
        <String>[for (final relation in _db._catalog.relations) relation.name];
    final visited = <NodeRef>{start};
    final levels = <List<NodeRef>>[
      <NodeRef>[start],
    ];
    var frontier = <NodeRef>[start];
    for (var depth = 1; depth <= maxDepth; depth++) {
      final next = <NodeRef>[];
      for (final node in frontier) {
        for (final name in names) {
          final edges = await _scan(name, node, direction);
          for (final edge in edges) {
            final neighbour = direction == EdgeDirection.outbound
                ? edge.to
                : edge.from;
            if (visited.add(neighbour)) next.add(neighbour);
          }
        }
      }
      if (next.isEmpty) break;
      levels.add(next);
      frontier = next;
    }
    return GraphWalk(
      levels: levels,
      truncated:
          maxDepth > 0 && levels.length - 1 == maxDepth && frontier.isNotEmpty,
    );
  }

  Future<List<GraphEdge>> _scan(
    String relation,
    NodeRef node,
    EdgeDirection direction,
  ) async {
    final id = _db._catalog.relationIdOf(relation);
    if (id == null) return const <GraphEdge>[];
    final nodeBytes = node.encode();
    final prefix = Uint8List(3 + 2 + nodeBytes.length);
    prefix[0] = (id >> 8) & 0xFF;
    prefix[1] = id & 0xFF;
    prefix[2] = direction == EdgeDirection.outbound ? 1 : 2;
    prefix[3] = (nodeBytes.length >> 8) & 0xFF;
    prefix[4] = nodeBytes.length & 0xFF;
    prefix.setRange(5, prefix.length, nodeBytes);
    final entries = await _engine.scanRange(start: prefix, end: _upper(prefix));
    final edges = <GraphEdge>[];
    for (final entry in entries) {
      final other = NodeRef.decode(
        Uint8List.sublistView(entry.key, 5 + nodeBytes.length),
      );
      edges.add(
        GraphEdge(
          relation: relation,
          from: direction == EdgeDirection.outbound ? node : other,
          to: direction == EdgeDirection.outbound ? other : node,
          properties: entry.document!,
        ),
      );
    }
    return edges;
  }

  static Uint8List _edgeKey(
    int relationId,
    int direction,
    Uint8List known,
    Uint8List other,
  ) {
    final out = Uint8List(3 + 2 + known.length + other.length);
    out[0] = (relationId >> 8) & 0xFF;
    out[1] = relationId & 0xFF;
    out[2] = direction;
    out[3] = (known.length >> 8) & 0xFF;
    out[4] = known.length & 0xFF;
    out.setRange(5, 5 + known.length, known);
    out.setRange(5 + known.length, out.length, other);
    return out;
  }
}

Uint8List? _upper(Uint8List prefix) {
  final out = Uint8List.fromList(prefix);
  for (var i = out.length - 1; i >= 0; i--) {
    if (out[i] != 0xFF) {
      out[i]++;
      return Uint8List.sublistView(out, 0, i + 1);
    }
  }
  return null;
}

/// Buffered writes over an object store.
///
/// Document and index mutations share one WAL object, so the commit is atomic
/// at the object-store level. Reads see the transaction's own writes; reference
/// checks and cascades use the same view.
final class WebTransaction {
  WebTransaction._(this._db, this._engine) : _ops = <String, WalOp>{};

  final VelxoWebDatabase _db;
  final ObjectStoreEngine _engine;
  final Map<String, WalOp> _ops;
  bool _committed = false;

  /// Whether anything is buffered.
  bool get isEmpty => _ops.isEmpty;

  /// Reads [key] from [collection], including buffered writes.
  Future<Bytes?> get(WebCollection collection, Uint8List key) async {
    final full = collection._key(key);
    final pending = _ops[String.fromCharCodes(full)];
    if (pending != null) {
      if (pending.kind == WalOpKind.delete) return null;
      final bytes = pending.value!;
      return Bytes.view(bytes, 0, bytes.length);
    }
    return _engine.get(full);
  }

  /// Buffers a put, its index/text maintenance and the reference checks.
  Future<void> put(
    WebCollection collection,
    Uint8List key,
    Bytes document,
  ) async {
    if (collection.enforceReferences) {
      await _validateReferences(collection, document);
    }
    final old = await get(collection, key);
    if (old != null) {
      _collectIndexOps(collection, key, old, null);
      _collectTextOps(collection, key, old, null);
    }
    final full = collection._key(key);
    _ops[String.fromCharCodes(full)] = WalOp.put(
      full,
      Uint8List.fromList(document.asUint8List()),
    );
    _collectIndexOps(collection, key, null, document);
    _collectTextOps(collection, key, null, document);
  }

  /// Buffers a delete and applies `restrict` / `cascade` reference policies.
  ///
  /// A cascade uses a visited set and a depth limit, so a reference cycle ends.
  Future<void> delete(WebCollection collection, Uint8List key) =>
      _delete(collection, key, <String>{}, 0);

  Future<void> _delete(
    WebCollection collection,
    Uint8List key,
    Set<String> visited,
    int depth,
  ) async {
    if (depth > 32) {
      throw VelxoConflictException(
        'reference cascade exceeded depth 32 while deleting '
        '${String.fromCharCodes(key)}',
      );
    }
    if (!visited.add('${collection.id}:${String.fromCharCodes(key)}')) return;
    final old = await get(collection, key);
    if (old == null) {
      final full = collection._key(key);
      _ops[String.fromCharCodes(full)] = WalOp.delete(full);
      return;
    }
    await _handleReferrers(collection, key, visited, depth);
    _collectIndexOps(collection, key, old, null);
    _collectTextOps(collection, key, old, null);
    final full = collection._key(key);
    _ops[String.fromCharCodes(full)] = WalOp.delete(full);
  }

  /// Writes every buffered operation as one WAL object.
  Future<void> commit() async {
    if (_committed) return;
    _committed = true;
    if (_ops.isEmpty) return;
    await _engine.applyBatch(_ops.values.toList(growable: false));
  }

  Future<void> _validateReferences(
    WebCollection collection,
    Bytes document,
  ) async {
    final view = DocView.parse(document.asUint8List());
    for (final reference in _db._catalog.references) {
      if (reference.sourceCollectionId != collection.id) continue;
      final value = view.getString(reference.fieldId);
      if (value == null) continue;
      final targetKey = Uint8List.fromList(utf8.encode(value));
      final composed = WebCollection._compose(
        reference.targetCollectionId,
        targetKey,
      );
      final pending = _ops[String.fromCharCodes(composed)];
      final exists = pending != null
          ? pending.kind == WalOpKind.put
          : await _engine.get(composed) != null;
      if (!exists) {
        throw VelxoConstraintException(
          'missing referenced document "$value" in collection '
          '${reference.targetCollectionId} (field ${reference.fieldId})',
        );
      }
    }
  }

  Future<void> _handleReferrers(
    WebCollection target,
    Uint8List key,
    Set<String> visited,
    int depth,
  ) async {
    final String targetKey;
    try {
      targetKey = utf8.decode(key);
    } on FormatException {
      // A binary primary key can never be the target of a string reference.
      return;
    }
    for (final reference in _db._catalog.references) {
      if (reference.targetCollectionId != target.id) continue;
      final source = _db._collectionById(reference.sourceCollectionId);
      if (source == null) continue;
      final referrers = await _referrers(source, reference.fieldId, targetKey);
      final live = <WebEntry>[];
      for (final entry in referrers) {
        // A referrer already buffered as deleted in this transaction is gone.
        if (await get(source, entry.key) == null) continue;
        live.add(entry);
      }
      if (live.isEmpty) continue;
      switch (reference.onDelete) {
        case OnDelete.restrict:
          throw VelxoConstraintException(
            'cannot delete document: ${live.length} document(s) still '
            'reference it through field ${reference.fieldId}',
          );
        case OnDelete.cascade:
          for (final entry in live) {
            await _delete(source, entry.key, visited, depth + 1);
          }
        case OnDelete.setNull:
          throw UnsupportedError('OnDelete.setNull is not implemented');
      }
    }
  }

  /// Referrers of [value], including postings this transaction has buffered.
  ///
  /// The committed index cannot see a referrer written earlier in the same
  /// block, so a `restrict` would pass and a `cascade` would miss it.
  Future<List<WebEntry>> _referrers(
    WebCollection source,
    int fieldId,
    Object value,
  ) async {
    final definition = _db._catalog.indexFor(source.id, fieldId);
    if (definition == null) return const <WebEntry>[];
    final merged = <String, WebEntry>{
      for (final entry in await source.lookupByIndex(fieldId, value))
        String.fromCharCodes(entry.key): entry,
    };
    final prefix = definition.valuePrefix(value);
    for (final op in _ops.values) {
      final posting = op.key;
      if (posting.length < prefix.length) continue;
      if (!_startsWith(posting, prefix)) continue;
      final primaryKey = Uint8List.sublistView(posting, prefix.length);
      final id = String.fromCharCodes(primaryKey);
      if (op.kind == WalOpKind.delete) {
        merged.remove(id);
      } else {
        merged[id] = (
          key: primaryKey,
          value: Bytes.view(op.value!, 0, op.value!.length),
        );
      }
    }
    return merged.values.toList();
  }

  static bool _startsWith(Uint8List bytes, Uint8List prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  void _collectIndexOps(
    WebCollection collection,
    Uint8List key,
    Bytes? oldDocument,
    Bytes? newDocument,
  ) {
    for (final definition in _db._catalog.indexes) {
      if (definition.collectionId != collection.id) continue;
      final oldValue = oldDocument == null
          ? null
          : definition.readValue(DocView.parse(oldDocument.asUint8List()));
      final newValue = newDocument == null
          ? null
          : definition.readValue(DocView.parse(newDocument.asUint8List()));
      if (oldValue != null && oldValue != newValue) {
        final posting = definition.entryKey(oldValue, key);
        _ops[String.fromCharCodes(posting)] = WalOp.delete(posting);
      }
      if (newValue != null && oldValue != newValue) {
        final posting = definition.entryKey(newValue, key);
        _ops[String.fromCharCodes(posting)] = WalOp.put(
          posting,
          WebCollection._empty.asUint8List(),
        );
      }
    }
  }

  void _collectTextOps(
    WebCollection collection,
    Uint8List key,
    Bytes? oldDocument,
    Bytes? newDocument,
  ) {
    for (final definition in _db._catalog.textIndexes) {
      if (definition.collectionId != collection.id) continue;
      final oldText = oldDocument == null
          ? ''
          : DocView.parse(oldDocument.asUint8List())
                    .getString(definition.fieldId) ??
                '';
      final newText = newDocument == null
          ? ''
          : DocView.parse(newDocument.asUint8List())
                    .getString(definition.fieldId) ??
                '';
      final oldTerms = definition.tokenize(oldText).toSet();
      final newTerms = definition.tokenize(newText).toSet();
      for (final term in oldTerms.difference(newTerms)) {
        final posting = definition.entryKey(term, key);
        _ops[String.fromCharCodes(posting)] = WalOp.delete(posting);
      }
      for (final term in newTerms.difference(oldTerms)) {
        final posting = definition.entryKey(term, key);
        _ops[String.fromCharCodes(posting)] = WalOp.put(
          posting,
          WebCollection._empty.asUint8List(),
        );
      }
    }
  }
}
