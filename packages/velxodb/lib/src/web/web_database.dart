import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../query/catalog.dart';
import '../storage/io/opfs_store.dart';
import '../storage/object_engine.dart';

/// One document returned by [WebCollection.scan].
typedef WebEntry = ({Uint8List key, Bytes value});

/// Async Web database over OPFS.
///
/// This is the first async facade: collections, document CRUD, ordered scans and
/// key-cursor pages, with the same document encoding and two-byte collection
/// prefixes as the VM engine. Secondary indexes, references, graph, full-text
/// and transactions are not in this layer yet.
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
    final catalogKey = '${prefix}CATALOG';
    final raw = await store.get(catalogKey);
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
      await _store.put(
        '${_engine.prefix}CATALOG',
        _catalog.encode(),
      );
      id = _catalog.idOf(name)!;
    }
    final collection = WebCollection._(_engine, id);
    _collections[name] = collection;
    return collection;
  }

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

/// Async collection: CRUD, ordered scan and key-cursor pagination.
final class WebCollection {
  WebCollection._(this._engine, this._id);

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

  /// Reads one document.
  Future<Bytes?> get(Uint8List key) => _engine.get(_key(key));

  /// Inserts or replaces one document.
  Future<void> put(Uint8List key, Bytes document) =>
      _engine.put(_key(key), document);

  /// Deletes one document.
  Future<void> delete(Uint8List key) => _engine.delete(_key(key));

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
}
