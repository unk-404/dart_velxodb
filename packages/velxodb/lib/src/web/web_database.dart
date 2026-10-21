import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../errors.dart';
import '../query/catalog.dart';
import '../query/index.dart';
import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import '../storage/io/opfs_store.dart';
import '../storage/object_engine.dart';

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

  /// Flushes the memtable into an object-store segment.
  Future<void> flush() async {
    await _engine.flush();
  }

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
    await _engine.put(_key(key), document);
    await _addIndexes(key, document);
  }

  /// Deletes one document and its index entries.
  Future<void> delete(Uint8List key) async {
    final old = await get(key);
    if (old != null) await _removeIndexes(key, old);
    await _engine.delete(_key(key));
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
