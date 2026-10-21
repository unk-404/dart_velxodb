import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/view.dart';
import '../storage/engine.dart';
import 'cursor.dart';
import 'types.dart';

/// A named namespace of documents inside a database.
///
/// Collections share one engine: every key is prefixed with a two-byte
/// big-endian collection id. Because the prefix is fixed-width, ordering inside
/// a collection is exactly the ordering of the user key bytes, which is what
/// lets segment index range scans work.
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

  /// Opens a streaming cursor over an optional prefix and key range.
  ///
  /// [start] is inclusive and [end] exclusive by default; both are user keys.
  /// [prefix] restricts to keys that begin with it. The cursor merges the
  /// memtable with segments newest-first and skips tombstoned keys.
  CollectionCursor cursor({
    Uint8List? prefix,
    Uint8List? start,
    Uint8List? end,
    bool includeStart = true,
    bool includeEnd = false,
  }) {
    final fullPrefix = composeKey(prefix ?? Uint8List(0));
    final lower = start != null ? composeKey(start) : fullPrefix;
    Uint8List? upper;
    if (end != null) {
      upper = composeKey(end);
    } else {
      final bound = _prefixUpperBound(fullPrefix);
      if (bound != null) upper = bound;
    }
    return buildCollectionCursor(
      engine: engine,
      fullPrefix: fullPrefix,
      lower: lower,
      includeLower: includeStart,
      upper: upper,
      includeUpper: includeEnd,
    );
  }

  /// Scans into a list, optionally filtering decoded documents and limiting.
  List<ScanEntry> scanSync({
    Uint8List? prefix,
    Uint8List? start,
    Uint8List? end,
    bool includeStart = true,
    bool includeEnd = false,
    bool Function(DocView document)? where,
    int? limit,
  }) {
    final cursor = this.cursor(
      prefix: prefix,
      start: start,
      end: end,
      includeStart: includeStart,
      includeEnd: includeEnd,
    );
    final out = <ScanEntry>[];
    while (cursor.moveNext()) {
      final entry = cursor.current;
      if (where != null && !where(viewOf(entry.value))) continue;
      out.add(entry);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  /// Async facade over [scanSync].
  Future<List<ScanEntry>> scan({
    Uint8List? prefix,
    Uint8List? start,
    Uint8List? end,
    bool includeStart = true,
    bool includeEnd = false,
    bool Function(DocView document)? where,
    int? limit,
  }) async => scanSync(
    prefix: prefix,
    start: start,
    end: end,
    includeStart: includeStart,
    includeEnd: includeEnd,
    where: where,
    limit: limit,
  );

  /// Returns every entry whose key starts with [prefix], sorted by key.
  List<ScanEntry> scanPrefixSync([Uint8List? prefix]) =>
      scanSync(prefix: prefix);

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

  /// Smallest key greater than every key with [prefix], or `null`.
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
}
