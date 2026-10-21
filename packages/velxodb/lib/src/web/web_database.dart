import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../errors.dart';
import '../query/catalog.dart';
import '../query/graph.dart';
import '../query/index.dart';
import '../query/reference.dart';
import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import '../storage/io/opfs_store.dart';
import '../storage/object_engine.dart';
import '../storage/wal.dart';

/// One document returned by [WebCollection.scan] and index lookups.
typedef WebEntry = ({Uint8List key, Bytes value});

/// Async Web database over OPFS.
///
/// Collections, document CRUD, ordered scans, key-cursor pages and secondary
/// indexes (equality and range) with the same document encoding, collection
/// prefixes and index key layout as the VM. Transactions, references, graph
/// and full-text are not in this layer yet.
final class VelxoWebDatabase {
  VelxoWebDatabase._(this._store, this._engine, this._catalog);

  /// Opens (or creates) a database under the OPFS logical [root].
  static Future<VelxoWebDatabase> open({
    String root = 'velxodb',
    String prefix = 'db/',
  }) async {
    final store = await OpfsObjectStore.open(root: root);
    final engine = ObjectStoreEngine(store: store, prefix: prefix);
    await engine.open();
    final raw = await store.get('${prefix}CATALOG');
    final catalog = raw == null ? Catalog.empty() : Catalog.decode(raw);
    return VelxoWebDatabase._(store, engine, catalog);
  }

  final OpfsObjectStore _store;
  final ObjectStoreEngine _engine;
  Catalog _catalog;
  final Map<String, WebCollection> _collections = <String, WebCollection>{};

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

  WebGraph? _graph;

  /// Flushes the memtable into an object-store segment.
  Future<void> flush() async {
    await _engine.flush();
  }

  /// Runs [body] and commits every buffered put/delete as one WAL object.
  ///
  /// If [body] throws, nothing is written. Index maintenance is part of the
  /// same batch. Reads inside [body] see the transaction's own writes.
  Future<T> writeTxn<T>(Future<T> Function(WebTransaction transaction) body) async {
    final transaction = WebTransaction._(_engine);
    final result = await body(transaction);
    await transaction.commit();
    return result;
  }

  /// Alias for [writeTxn].
  Future<T> transaction<T>(Future<T> Function(WebTransaction transaction) body) =>
      writeTxn(body);

  /// Flushes and closes the engine and the OPFS store.
  Future<void> close({bool flush = true}) async {
    await _engine.close(flush: flush);
    await _store.close();
  }
}

/// Async collection: CRUD, ordered scan, pagination and secondary indexes.
final class WebCollection {
  WebCollection._(this._db, this._engine, this._id);

  static final Bytes _empty = DocBuilder(schemaId: 1).finish();

  final VelxoWebDatabase _db;
  final ObjectStoreEngine _engine;
  final int _id;

  /// Stable collection id.
  int get id => _id;

  Uint8List _key(Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (_id >> 8) & 0xFF;
    out[1] = _id & 0xFF;
    out.setRange(2, out.length, key);
    return out;
  }

  Uint8List get _prefix => Uint8List.fromList(<int>[
    (_id >> 8) & 0xFF,
    _id & 0xFF,
  ]);

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

  /// Inserts or replaces one document, maintaining every index.
  Future<void> put(Uint8List key, Bytes document) async {
    final old = await get(key);
    if (old != null) await _removeIndexes(key, old);
    await _validateReferences(document);
    await _engine.put(_key(key), document);
    await _addIndexes(key, document);
  }

  /// Deletes one document, checking/cascading references first.
  Future<void> delete(Uint8List key) async {
    final old = await get(key);
    if (old != null) {
      await _handleReferrers(key);
      await _removeIndexes(key, old);
    }
    await _engine.delete(_key(key));
  }

  /// Binds [fieldId] to [targetName] and indexes the field.
  Future<ReferenceDefinition> createReference(
    int fieldId,
    String targetName, {
    OnDelete onDelete = OnDelete.restrict,
  }) async {
    final targetId = _db._catalog.idOf(targetName);
    if (targetId == null) {
      throw VelxoNotFoundException(
        'target collection "$targetName" does not exist',
      );
    }
    _db._catalog = _db._catalog.withReference(
      _id,
      fieldId,
      targetId,
      onDelete,
    );
    await _db._saveCatalog();
    await createIndex(fieldId, VxsType.string);
    return _db._catalog.referenceFor(_id, fieldId)!;
  }

  Future<void> _validateReferences(Bytes document) async {
    final view = DocView.parse(document.asUint8List());
    for (final reference in _db._catalog.references) {
      if (reference.sourceCollectionId != _id) continue;
      final value = view.getString(reference.fieldId);
      if (value == null) continue;
      final targetKey = Uint8List.fromList(utf8.encode(value));
      final target = await _engine.get(
        WebCollection._compose(reference.targetCollectionId, targetKey),
      );
      if (target == null) {
        throw StateError(
          'missing referenced document "$value" in collection '
          '${reference.targetCollectionId} (field ${reference.fieldId})',
        );
      }
    }
  }

  Future<void> _handleReferrers(Uint8List key) async {
    final targetKey = utf8.decode(key);
    for (final reference in _db._catalog.references) {
      if (reference.targetCollectionId != _id) continue;
      final source = _db._collectionById(reference.sourceCollectionId);
      if (source == null) continue;
      final referrers = await source.lookupByIndex(
        reference.fieldId,
        targetKey,
      );
      if (referrers.isEmpty) continue;
      switch (reference.onDelete) {
        case OnDelete.restrict:
          throw StateError(
            'cannot delete document: ${referrers.length} document(s) still '
            'reference it through field ${reference.fieldId}',
          );
        case OnDelete.cascade:
          for (final entry in referrers) {
            await source.delete(entry.key);
          }
        case OnDelete.setNull:
          throw UnsupportedError('OnDelete.setNull is not implemented');
      }
    }
  }

  static Uint8List _compose(int collectionId, Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (collectionId >> 8) & 0xFF;
    out[1] = collectionId & 0xFF;
    out.setRange(2, out.length, key);
    return out;
  }

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
  Future<void> createIndex(int fieldId, VxsType type) async {
    if (_db._catalog.indexFor(_id, fieldId) != null) return;
    _db._catalog = _db._catalog.withIndex(_id, fieldId, type);
    await _db._saveCatalog();
    final definition = _db._catalog.indexFor(_id, fieldId)!;
    for (final entry in await scan()) {
      final value = definition.readValue(DocView.parse(entry.value.asUint8List()));
      if (value != null) {
        await _engine.put(
          definition.entryKey(value, entry.key),
          _empty,
        );
      }
    }
  }

  IndexDefinition _index(int fieldId) {
    final definition = _db._catalog.indexFor(_id, fieldId);
    if (definition == null) {
      throw VelxoNotFoundException('no index on field $fieldId');
    }
    return definition;
  }

  /// Finds documents whose indexed [fieldId] equals [value].
  Future<List<WebEntry>> lookupByIndex(int fieldId, Object value) async {
    final definition = _index(fieldId);
    final prefix = definition.valuePrefix(value);
    final entries = await _engine.scanRange(
      start: prefix,
      end: _upper(prefix),
    );
    final out = <WebEntry>[];
    for (final entry in entries) {
      final primaryKey = Uint8List.fromList(
        entry.key.sublist(prefix.length),
      );
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
      final value = definition.readValue(
        DocView.parse(document.asUint8List()),
      );
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

  Future<void> _addIndexes(Uint8List key, Bytes document) async {
    final view = DocView.parse(document.asUint8List());
    for (final definition in _db._catalog.indexes) {
      if (definition.collectionId != _id) continue;
      final value = definition.readValue(view);
      if (value == null) continue;
      await _engine.put(definition.entryKey(value, key), _empty);
    }
  }

  Future<void> _removeIndexes(Uint8List key, Bytes document) async {
    final view = DocView.parse(document.asUint8List());
    for (final definition in _db._catalog.indexes) {
      if (definition.collectionId != _id) continue;
      final value = definition.readValue(view);
      if (value == null) continue;
      await _engine.delete(definition.entryKey(value, key));
    }
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
    final names = relations ??
        <String>[
          for (final relation in _db._catalog.relations) relation.name,
        ];
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
            final neighbour =
                direction == EdgeDirection.outbound ? edge.to : edge.from;
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
      truncated: levels.length - 1 == maxDepth && frontier.isNotEmpty,
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
    final entries = await _engine.scanRange(
      start: prefix,
      end: _upper(prefix),
    );
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
///
/// Document and index mutations share one WAL object, so the commit is atomic
/// at the object store level. Reads see the transaction's own writes.
final class WebTransaction {
  WebTransaction._(this._engine) : _ops = <String, WalOp>{};

  final ObjectStoreEngine _engine;
  final Map<String, WalOp> _ops;
  bool _committed = false;

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

  /// Buffers a put and its index maintenance.
  Future<void> put(
    WebCollection collection,
    Uint8List key,
    Bytes document,
  ) async {
    final old = await get(collection, key);
    if (old != null) _removeIndexes(collection, key, old);
    final full = collection._key(key);
    _ops[String.fromCharCodes(full)] = WalOp.put(
      full,
      Uint8List.fromList(document.asUint8List()),
    );
    _addIndexes(collection, key, document);
  }

  /// Buffers a delete and its index maintenance.
  Future<void> delete(WebCollection collection, Uint8List key) async {
    final old = await get(collection, key);
    if (old != null) _removeIndexes(collection, key, old);
    final full = collection._key(key);
    _ops[String.fromCharCodes(full)] = WalOp.delete(full);
  }

  /// Writes every buffered operation as one WAL object.
  Future<void> commit() async {
    if (_committed) return;
    _committed = true;
    await _engine.applyBatch(_ops.values.toList(growable: false));
  }

  void _addIndexes(WebCollection collection, Uint8List key, Bytes document) {
    final view = DocView.parse(document.asUint8List());
    for (final definition in collection._db._catalog.indexes) {
      if (definition.collectionId != collection._id) continue;
      final value = definition.readValue(view);
      if (value == null) continue;
      _putPosting(definition, value, key);
    }
  }

  void _removeIndexes(WebCollection collection, Uint8List key, Bytes document) {
    final view = DocView.parse(document.asUint8List());
    for (final definition in collection._db._catalog.indexes) {
      if (definition.collectionId != collection._id) continue;
      final value = definition.readValue(view);
      if (value == null) continue;
      final posting = definition.entryKey(value, key);
      _ops[String.fromCharCodes(posting)] = WalOp.delete(posting);
    }
  }

  void _putPosting(IndexDefinition definition, Object value, Uint8List key) {
    final posting = definition.entryKey(value, key);
    _ops[String.fromCharCodes(posting)] = WalOp.put(
      posting,
      WebCollection._empty.asUint8List(),
    );
  }
}
