import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import '../storage/engine.dart';
import '../storage/wal.dart';
import 'cursor.dart';
import 'index.dart';
import 'plan.dart';
import 'reference.dart';
import 'types.dart';

/// A named namespace of documents inside a database.
///
/// Collections share one engine: every key is prefixed with a two-byte
/// big-endian collection id. Because the prefix is fixed-width, ordering inside
/// a collection is exactly the ordering of the user key bytes, which is what
/// lets segment index range scans work.
///
/// Secondary indexes live in the same engine under their own two-byte id, with
/// entries shaped `[indexId][encodedValue][primaryKey]`. A document and its
/// index entries are written in one WAL frame, so they commit together.
final class Collection {
  /// Creates a collection handle. Use [VelxoDatabase.collection] instead.
  Collection(this.engine, this.id, this.name, {CollectionCatalog? catalog})
    : _catalog = catalog {
    if (catalog != null) {
      for (final definition in catalog.indexesFor(id)) {
        _indexes[definition.fieldId] = definition;
      }
      for (final reference in catalog.referencesFor(id)) {
        _references[reference.fieldId] = reference;
      }
    }
  }

  /// Underlying engine.
  final StorageEngine engine;

  /// Stable numeric id, assigned by the catalog.
  final int id;

  /// Collection name.
  final String name;

  final CollectionCatalog? _catalog;
  final Map<int, IndexDefinition> _indexes = <int, IndexDefinition>{};
  final Map<int, ReferenceDefinition> _references = <int, ReferenceDefinition>{};

  /// Whether writes verify that referenced documents exist.
  ///
  /// Off by default: enforcement costs one point read per reference field.
  bool enforceReferences = false;

  static final Bytes _emptyDocument = DocBuilder().finish();

  /// Declared secondary indexes by field id.
  Map<int, IndexDefinition> get indexes => Map.unmodifiable(_indexes);

  /// Declared reference bindings by field id.
  Map<int, ReferenceDefinition> get references => Map.unmodifiable(_references);

  /// Reads [key], or `null` when absent or deleted.
  Bytes? get(Uint8List key) => engine.get(composeKey(key));

  /// Inserts or replaces [key], maintaining indexes and references.
  ///
  /// The document and every derived entry go into one WAL frame, so a crash
  /// cannot leave an index entry pointing at a document that was never written.
  void putSync(Uint8List key, Bytes document) {
    final full = composeKey(key);
    final old = engine.get(full);
    final oldView = old == null ? null : DocView.parse(old.asUint8List());
    final newView = DocView.parse(document.asUint8List());
    _checkReferences(newView);
    final ops = <WalOp>[WalOp.put(full, document.asUint8List())];
    _collectIndexOps(ops, key, oldView, newView);
    engine.applyBatchSync(ops);
  }

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, Bytes document) async =>
      putSync(key, document);

  /// Inserts or replaces several documents.
  ///
  /// Each document is atomic on its own; batching across documents needs the
  /// previous value of every key, so it stays a loop for now.
  void putManySync(List<ScanEntry> entries) {
    for (final entry in entries) {
      putSync(entry.key, entry.value);
    }
  }

  /// Deletes [key], removing index entries and applying reference policies.
  void deleteSync(Uint8List key) => _deleteInternal(key, <String>{}, 0);

  /// Async facade over [deleteSync].
  Future<void> delete(Uint8List key) async => deleteSync(key);

  /// Creates a reference binding from [fieldId] to the [targetName] collection.
  ///
  /// The field must hold the target's key as a UTF-8 string; a secondary index
  /// on it is created (or reused) so reverse lookups are O(degree).
  ReferenceDefinition createReference(
    int fieldId,
    String targetName, {
    OnDelete onDelete = OnDelete.restrict,
  }) {
    final catalog = _catalog;
    if (catalog == null) {
      throw StateError('this collection handle has no catalog; '
          'open it through VelxoDatabase.collection');
    }
    final targetId = catalog.collectionIdOf(targetName);
    if (targetId == null) {
      throw StateError('target collection "$targetName" does not exist');
    }
    final definition = catalog.registerReference(
      id,
      fieldId,
      targetId,
      onDelete,
    );
    _references[fieldId] = definition;
    createIndex(fieldId, VxsType.string);
    return definition;
  }

  /// Creates (and backfills) a secondary index on [fieldId].
  IndexDefinition createIndex(int fieldId, VxsType type) {
    final existing = _indexes[fieldId];
    if (existing != null) {
      if (existing.type != type) {
        throw ArgumentError('field $fieldId is already indexed as '
            '${existing.type.name}');
      }
      return existing;
    }
    final catalog = _catalog;
    if (catalog == null) {
      throw StateError('this collection handle has no catalog; '
          'open it through VelxoDatabase.collection');
    }
    final definition = catalog.registerIndex(id, fieldId, type);
    _indexes[fieldId] = definition;
    _backfill(definition);
    return definition;
  }

  /// Looks up primary keys whose indexed [fieldId] equals [value].
  ///
  /// Stale entries (a document that changed while its index entry survived a
  /// crash) are filtered by re-reading and comparing the field, so results are
  /// always correct even without transactional index updates.
  List<ScanEntry> lookupByIndexSync(int fieldId, Object value) {
    final definition = _indexes[fieldId];
    if (definition == null) {
      throw StateError('no index on field $fieldId');
    }
    final prefix = definition.valuePrefix(value);
    final encodedLength = prefix.length - 2;
    final cursor = buildCollectionCursor(
      engine: engine,
      fullPrefix: prefix,
      lower: prefix,
      includeLower: true,
      upper: _prefixUpperBound(prefix),
      includeUpper: false,
    );
    final out = <ScanEntry>[];
    while (cursor.moveNext()) {
      final raw = cursor.current.key;
      final primaryKey = Uint8List.sublistView(raw, encodedLength);
      final document = get(primaryKey);
      if (document == null) continue;
      final view = DocView.parse(document.asUint8List());
      if (definition.readValue(view) != value) continue;
      out.add((key: primaryKey, value: document));
    }
    return out;
  }

  /// Looks up primary keys whose indexed [fieldId] lies in `[from, to)`.
  ///
  /// Bounds are encoded with the same order-preserving codec, so this is a
  /// contiguous range over the index namespace. Entries are verified against
  /// the document for the same reason [lookupByIndexSync] does it.
  List<ScanEntry> lookupByIndexRangeSync(
    int fieldId, {
    Object? from,
    Object? to,
    bool includeFrom = true,
    bool includeTo = false,
    int? limit,
  }) {
    final definition = _indexes[fieldId];
    if (definition == null) {
      throw StateError('no index on field $fieldId');
    }
    final namespace = definition.namespacePrefix;
    Uint8List? lower;
    if (from != null) {
      final prefix = definition.valuePrefix(from);
      lower = includeFrom ? prefix : _prefixUpperBound(prefix);
    }
    Uint8List? upper;
    if (to != null) {
      final prefix = definition.valuePrefix(to);
      upper = includeTo ? _prefixUpperBound(prefix) : prefix;
    } else {
      upper = _prefixUpperBound(namespace);
    }

    final cursor = buildCollectionCursor(
      engine: engine,
      fullPrefix: namespace,
      lower: lower ?? namespace,
      includeLower: true,
      upper: upper,
      includeUpper: true,
    );
    final out = <ScanEntry>[];
    while (cursor.moveNext()) {
      final raw = cursor.current.key;
      final encodedLength = definition.encodedValueLength(raw, 0);
      final primaryKey = Uint8List.sublistView(raw, encodedLength);
      final document = get(primaryKey);
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

  /// Runs [query], using an index when one covers part of the predicate.
  ///
  /// Key-range fields of the query are ignored on an index plan; the residual
  /// predicate still runs, so results are identical either way.
  List<ScanEntry> findSync(Query query) {
    final hit = indexHitFor(query, _indexes.keys);
    if (hit == null) {
      return scanSync(
        prefix: query.prefix,
        start: query.start,
        end: query.end,
        includeStart: query.includeStart,
        includeEnd: query.includeEnd,
        where: query.where?.test,
        limit: query.limit,
      );
    }
    final limit = query.limit;
    final candidates = hit.isEquality
        ? lookupByIndexSync(hit.fieldId, hit.value!)
        : lookupByIndexRangeSync(
            hit.fieldId,
            from: hit.from,
            to: hit.to,
            includeFrom: hit.includeFrom,
            includeTo: hit.includeTo,
            limit: limit,
          );
    final predicate = query.where;
    if (predicate == null) return candidates;
    final out = <ScanEntry>[];
    for (final entry in candidates) {
      if (!predicate.test(DocView.parse(entry.value.asUint8List()))) continue;
      out.add(entry);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  /// Async facade over [findSync].
  Future<List<ScanEntry>> find(Query query) async => findSync(query);

  /// Describes how [query] would be executed.
  String explainSync(Query query) =>
      planQuery(query, _indexes.keys).explanation;

  /// Returns one page of entries plus the key to resume after.
  /// Keys are the collection's own ordering, so a page token is simply the last
  /// key of the previous page; no offset arithmetic and no drift on writes.
  ScanPage pageSync({
    Uint8List? prefix,
    Uint8List? after,
    int limit = 100,
    bool Function(DocView document)? where,
  }) {
    final cursor = this.cursor(
      prefix: prefix,
      start: after,
      includeStart: after == null,
    );
    final out = <ScanEntry>[];
    while (out.length < limit && cursor.moveNext()) {
      final entry = cursor.current;
      if (where != null && !where(viewOf(entry.value))) continue;
      out.add(entry);
    }
    return (
      entries: out,
      next: out.length == limit ? out.last.key : null,
    );
  }

  /// Async facade over [pageSync].
  Future<ScanPage> page({
    Uint8List? prefix,
    Uint8List? after,
    int limit = 100,
    bool Function(DocView document)? where,
  }) async => pageSync(prefix: prefix, after: after, limit: limit, where: where);

  /// Opens a streaming cursor over an optional prefix and key range.
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

  void _collectIndexOps(
    List<WalOp> ops,
    Uint8List primaryKey,
    DocView? oldDocument,
    DocView? newDocument,
  ) {
    if (_indexes.isEmpty) return;
    for (final definition in _indexes.values) {
      final oldValue =
          oldDocument == null ? null : definition.readValue(oldDocument);
      final newValue =
          newDocument == null ? null : definition.readValue(newDocument);
      if (oldValue != null && oldValue != newValue) {
        ops.add(WalOp.delete(definition.entryKey(oldValue, primaryKey)));
      }
      if (newValue != null && oldValue != newValue) {
        ops.add(
          WalOp.put(
            definition.entryKey(newValue, primaryKey),
            _emptyDocument.asUint8List(),
          ),
        );
      }
    }
  }

  void _deleteInternal(Uint8List key, Set<String> visited, int depth) {
    if (depth > 32) {
      throw StateError('reference cascade exceeded depth 32');
    }
    if (!visited.add('$id:${String.fromCharCodes(key)}')) return;
    final full = composeKey(key);
    final old = engine.get(full);
    if (old == null) {
      engine.deleteSync(full);
      return;
    }
    final oldView = DocView.parse(old.asUint8List());
    _handleReferrers(key, visited, depth);
    final ops = <WalOp>[WalOp.delete(full)];
    _collectIndexOps(ops, key, oldView, null);
    engine.applyBatchSync(ops);
  }

  void _handleReferrers(Uint8List key, Set<String> visited, int depth) {
    final catalog = _catalog;
    if (catalog == null) return;
    final targetKey = utf8.decode(key);
    for (final reference in catalog.referencesTo(id)) {
      final source = _collectionById(reference.sourceCollectionId);
      if (source == null) continue;
      final referrers = source.lookupByIndexSync(reference.fieldId, targetKey);
      if (referrers.isEmpty) continue;
      switch (reference.onDelete) {
        case OnDelete.restrict:
          throw StateError(
            'cannot delete document: ${referrers.length} document(s) in '
            'collection ${reference.sourceCollectionId} still reference it '
            'through field ${reference.fieldId}',
          );
        case OnDelete.cascade:
          for (final entry in referrers) {
            source._deleteInternal(entry.key, visited, depth + 1);
          }
        case OnDelete.setNull:
          throw UnsupportedError(
            'OnDelete.setNull needs a schema-aware rewrite and is not '
            'implemented yet',
          );
      }
    }
  }

  Collection? _collectionById(int collectionId) {
    if (collectionId == id) return this;
    final catalog = _catalog;
    if (catalog == null) return null;
    return Collection(engine, collectionId, '', catalog: catalog);
  }

  void _checkReferences(DocView document) {
    if (!enforceReferences) return;
    for (final reference in _references.values) {
      final value = document.getString(reference.fieldId);
      if (value == null) continue;
      final targetKey = Uint8List.fromList(utf8.encode(value));
      if (engine.get(composeKeyFor(reference.targetCollectionId, targetKey)) ==
          null) {
        throw StateError(
          'missing referenced document "$value" in collection '
          '${reference.targetCollectionId} (field ${reference.fieldId})',
        );
      }
    }
  }

  /// Encodes [key] for an arbitrary collection id.
  static Uint8List composeKeyFor(int collectionId, Uint8List key) {
    final out = Uint8List(2 + key.length);
    out[0] = (collectionId >> 8) & 0xFF;
    out[1] = collectionId & 0xFF;
    out.setRange(2, 2 + key.length, key);
    return out;
  }

  void _backfill(IndexDefinition definition) {
    final cursor = this.cursor();
    while (cursor.moveNext()) {
      final entry = cursor.current;
      final view = DocView.parse(entry.value.asUint8List());
      final value = definition.readValue(view);
      if (value == null) continue;
      engine.putSync(
        definition.entryKey(value, entry.key),
        _emptyDocument,
      );
    }
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
