import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/string_view.dart';
import '../storage/engine.dart';
import '../storage/memtable.dart';

/// One key/value pair returned by a scan.
typedef ScanEntry = ({Uint8List key, Bytes value});

/// A named namespace of documents inside a database.
///
/// Collections share one engine: every key is prefixed with a two-byte
/// big-endian collection id. Because the prefix is fixed-width, ordering inside
/// a collection is exactly the ordering of the user key bytes, which is what
/// lets segment index range scans work later.
final class Collection {
  /// Creates a collection handle. Use [VelxoDatabase.collection] instead.
  Collection(this.engine, this.id, this.name);

  /// Underlying engine.
  final StorageEngine engine;

  /// Stable numeric id, assigned by the catalog.
  final int id;

  /// Collection name.
  final String name;

  /// Reads [key], or `null` when absent or deleted.
  Bytes? get(Uint8List key) => engine.get(composeKey(key));

  /// Inserts or replaces [key].
  void putSync(Uint8List key, Bytes document) =>
      engine.putSync(composeKey(key), document);

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, Bytes document) async =>
      putSync(key, document);

  /// Inserts or replaces several documents with one WAL frame.
  void putManySync(List<ScanEntry> entries) => engine.putManySync(<
    ({Uint8List key, Bytes document})
  >[
    for (final entry in entries)
      (key: composeKey(entry.key), document: entry.value),
  ]);

  /// Deletes [key].
  void deleteSync(Uint8List key) => engine.deleteSync(composeKey(key));

  /// Async facade over [deleteSync].
  Future<void> delete(Uint8List key) async => deleteSync(key);

  /// Returns every entry whose key starts with [prefix], sorted by key.
  ///
  /// This is a merged scan: the memtable wins over segments, segments are
  /// searched newest-first, and tombstones suppress older copies. It is
  /// materialised on purpose for now; a streaming cursor comes with the query
  /// planner.
  List<ScanEntry> scanPrefixSync([Uint8List? prefix]) {
    final fullPrefix = composeKey(prefix ?? Uint8List(0));
    final seen = MemTable();
    final results = <ScanEntry>[];

    engine.memtable.forEach((key, chunk, offset, length) {
      if (!_startsWith(key, fullPrefix)) return;
      seen.put(key, 0, 0, 0);
      if (length < 0) return;
      results.add((
        key: _stripPrefix(key),
        value: engine.arena.view(chunk, offset, length),
      ));
    });

    for (var i = engine.segments.length - 1; i >= 0; i--) {
      engine.segments[i].forEachEntryPrefix(fullPrefix, (key, document) {
        if (seen.contains(key)) return;
        seen.put(key, 0, 0, 0);
        if (document == null) return;
        results.add((key: _stripPrefix(key), value: document.toBytes()));
      });
    }

    results.sort(
      (a, b) => StringView.compareRanges(
        a.key,
        0,
        a.key.length,
        b.key,
        0,
        b.key.length,
      ),
    );
    return results;
  }

  /// Async facade over [scanPrefixSync].
  Future<List<ScanEntry>> scanPrefix([Uint8List? prefix]) async =>
      scanPrefixSync(prefix);

  /// Encodes [key] as `[id high, id low, key...]`.
  Uint8List composeKey(Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (id >> 8) & 0xFF;
    out[1] = id & 0xFF;
    out.setRange(2, 2 + key.length, key);
    return out;
  }

  Uint8List _stripPrefix(Uint8List key) =>
      Uint8List.sublistView(key, 2, key.length);

  static bool _startsWith(Uint8List key, Uint8List prefix) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }
}
