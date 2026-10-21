import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/string_view.dart';
import '../serde/view.dart';
import '../storage/engine.dart';
import '../storage/segment.dart';
import 'types.dart';

/// Streaming, ordered cursor over one collection's key range.
///
/// Sources are merged on the fly instead of materialising the result:
/// the memtable (newest), then segments newest to oldest. The first entry for a
/// key wins; a winning tombstone suppresses older copies.
///
/// The memtable is unordered, so it is collected and sorted once per cursor.
/// That set is bounded by the memtable size; segments are consumed through
/// their sorted index with a binary-seeked start, so a range query does not
/// walk the whole segment.
final class CollectionCursor implements Iterator<ScanEntry> {
  CollectionCursor._(this._sources);

  final List<_Source> _sources;
  ScanEntry? _current;

  @override
  ScanEntry get current => _current!;

  /// Advances to the next live entry. Returns `false` at the end.
  @override
  bool moveNext() {
    while (true) {
      _Source? winner;
      Uint8List? smallest;
      for (final source in _sources) {
        final key = source.key;
        if (key == null) continue;
        if (smallest == null) {
          smallest = key;
          winner = source;
          continue;
        }
        final comparison = _compare(key, smallest);
        if (comparison < 0) {
          smallest = key;
          winner = source;
        } else if (comparison == 0 && source.priority < winner!.priority) {
          winner = source;
        }
      }
      if (winner == null) {
        _current = null;
        return false;
      }
      final value = winner.value;
      final key = smallest!;
      for (final source in _sources) {
        final sourceKey = source.key;
        if (sourceKey != null && _compare(sourceKey, key) == 0) {
          source.advance();
        }
      }
      if (value == null) continue; // tombstone wins: skip the key entirely
      _current = (key: Uint8List.sublistView(key, 2), value: value);
      return true;
    }
  }

  /// Materialises the rest of the cursor.
  List<ScanEntry> toList({int? limit}) {
    final out = <ScanEntry>[];
    while (moveNext()) {
      out.add(current);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  static int _compare(Uint8List a, Uint8List b) =>
      StringView.compareRanges(a, 0, a.length, b, 0, b.length);
}

abstract interface class _Source {
  /// Lower is newer.
  int get priority;

  Uint8List? get key;

  /// `null` means the winning entry is a tombstone.
  Bytes? get value;

  void advance();
}

final class _MemTableSource implements _Source {
  _MemTableSource(this._engine, this._bounds) {
    _entries = <_MemEntry>[];
    // The memtable keeps a skip list, so this seeks instead of scanning.
    _engine.memtable.forEachRange(
      _bounds.lower,
      _bounds.upper,
      (key, chunk, offset, length) {
        _entries.add((
          key: key,
          chunk: chunk,
          offset: offset,
          length: length,
        ));
      },
      includeLower: _bounds.includeLower,
      includeUpper: _bounds.includeUpper,
    );
  }

  final StorageEngine _engine;
  final _Bounds _bounds;
  late final List<_MemEntry> _entries;
  int _index = 0;

  @override
  int get priority => 0;

  @override
  Uint8List? get key =>
      _index < _entries.length ? _entries[_index].key : null;

  @override
  Bytes? get value {
    final entry = _entries[_index];
    return entry.length < 0
        ? null
        : _engine.arena.view(entry.chunk, entry.offset, entry.length);
  }

  @override
  void advance() => _index++;
}

typedef _MemEntry = ({Uint8List key, int chunk, int offset, int length});

final class _SegmentSource implements _Source {
  _SegmentSource(this._cursor, this.priority) {
    _has = _cursor.moveNext();
  }

  final SegmentEntryCursor _cursor;

  @override
  final int priority;

  bool _has = false;

  @override
  Uint8List? get key => _has ? _cursor.key : null;

  @override
  Bytes? get value => _cursor.document?.toBytes();

  @override
  void advance() => _has = _cursor.moveNext();
}

/// Key bounds over full keys, prefix included.
final class _Bounds {
  _Bounds(this.lower, this.includeLower, this.upper, this.includeUpper);

  final Uint8List? lower;
  final bool includeLower;
  final Uint8List? upper;
  final bool includeUpper;
}

/// Builds a cursor over the engine's memtable and segments.
CollectionCursor buildCollectionCursor({
  required StorageEngine engine,
  required Uint8List fullPrefix,
  Uint8List? lower,
  bool includeLower = true,
  Uint8List? upper,
  bool includeUpper = false,
}) {
  final bounds = _Bounds(lower, includeLower, upper, includeUpper);
  final sources = <_Source>[_MemTableSource(engine, bounds)];
  for (var i = engine.segments.length - 1; i >= 0; i--) {
    sources.add(
      _SegmentSource(
        engine.segments[i].entryCursor(
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
        engine.segments.length - i,
      ),
    );
  }
  return CollectionCursor._(sources);
}

/// Parses a value for a predicate without copying.
DocView viewOf(Bytes value) => DocView.parse(value.asUint8List());
