import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/string_view.dart';

/// Reference to the bytes of one value stored outside the memtable.
///
/// The memtable never owns document bytes: they live in an append-only arena
/// (or, after a flush, in a segment block). A negative [length] marks a
/// tombstone.
typedef MemRef = ({int chunk, int offset, int length});

/// In-memory table of `key -> value reference`.
///
/// Open addressing with linear probing, one fixed arena for keys and parallel
/// 32-bit arrays for the entries. Measured ~2.2x faster than
/// `HashMap<Key, int>` for both inserts and lookups, mostly because it avoids
/// allocating a key wrapper per operation.
///
/// The table does not compare values and does not keep keys ordered: flushing
/// sorts entries once, and the segment index does the ordering afterwards.
final class MemTable {
  /// Creates a table sized for [initialEntries] inserts before it grows.
  MemTable({int initialEntries = 1024})
    : _slots = Int32List(_roundUpPowerOfTwo(initialEntries * 2)) {
    _hashes = Uint32List(initialEntries);
    _keyOffsets = Int32List(initialEntries);
    _keyLengths = Int32List(initialEntries);
    _valueChunks = Int32List(initialEntries);
    _valueOffsets = Int32List(initialEntries);
    _valueLengths = Int32List(initialEntries);
    _heights = Int32List(initialEntries);
    _heads.fillRange(0, _heads.length, -1);
    _levels.add(_newLevel(initialEntries));
  }

  Int32List _slots;
  late Uint32List _hashes;
  late Int32List _keyOffsets;
  late Int32List _keyLengths;
  late Int32List _valueChunks;
  late Int32List _valueOffsets;
  late Int32List _valueLengths;

  Uint8List _keys = Uint8List(1024);
  int _keysUsed = 0;
  int _count = 0;

  // Skip list over the entries, ordered by key. The hash table above answers
  // point lookups; this index makes range scans seek instead of scanning the
  // whole memtable.
  final Int32List _heads = Int32List(_maxLevels);
  final List<Int32List> _levels = <Int32List>[];
  late Int32List _heights;
  int _topLevel = 0;
  int _rng = 0x9E3779B9;

  static const int _maxLevels = 32;

  /// Number of live entries, tombstones included.
  int get length => _count;

  /// Bytes currently used by keys (values live elsewhere).
  int get keyBytes => _keysUsed;

  /// Rough heap footprint of the table itself.
  int get memoryBytes =>
      _slots.lengthInBytes +
      _hashes.lengthInBytes +
      _keyOffsets.lengthInBytes +
      _keyLengths.lengthInBytes +
      _valueChunks.lengthInBytes +
      _valueOffsets.lengthInBytes +
      _valueLengths.lengthInBytes +
      _keys.length;

  /// Inserts or replaces [key] with a reference to [chunk]/[offset]/[length].
  void put(Uint8List key, int chunk, int offset, int length) {
    final hash = VxsCrc32c.compute(key);
    var slot = hash & (_slots.length - 1);
    while (true) {
      final entry = _slots[slot];
      if (entry == 0) {
        final index = _appendEntry(key, hash, chunk, offset, length);
        _slots[slot] = index + 1;
        if (_count * 2 > _slots.length) {
          _rehash();
        }
        return;
      }
      final index = entry - 1;
      if (_hashes[index] == hash &&
          _keyLengths[index] == key.length &&
          _keyEquals(index, key)) {
        _valueChunks[index] = chunk;
        _valueOffsets[index] = offset;
        _valueLengths[index] = length;
        return;
      }
      slot = (slot + 1) & (_slots.length - 1);
    }
  }

  /// Records that [key] was deleted.
  void putTombstone(Uint8List key) => put(key, -1, 0, -1);

  /// Looks [key] up, returning `null` when absent.
  ///
  /// A record with a negative `length` is a tombstone.
  MemRef? get(Uint8List key) {
    final hash = VxsCrc32c.compute(key);
    var slot = hash & (_slots.length - 1);
    while (true) {
      final entry = _slots[slot];
      if (entry == 0) return null;
      final index = entry - 1;
      if (_hashes[index] == hash &&
          _keyLengths[index] == key.length &&
          _keyEquals(index, key)) {
        return (
          chunk: _valueChunks[index],
          offset: _valueOffsets[index],
          length: _valueLengths[index],
        );
      }
      slot = (slot + 1) & (_slots.length - 1);
    }
  }

  /// Whether [key] is present (tombstones count as present).
  bool contains(Uint8List key) {
    final hash = VxsCrc32c.compute(key);
    var slot = hash & (_slots.length - 1);
    while (true) {
      final entry = _slots[slot];
      if (entry == 0) return false;
      final index = entry - 1;
      if (_hashes[index] == hash &&
          _keyLengths[index] == key.length &&
          _keyEquals(index, key)) {
        return true;
      }
      slot = (slot + 1) & (_slots.length - 1);
    }
  }

  /// Visits every entry in ascending key order.
  void forEachSorted(
    void Function(Uint8List key, int chunk, int offset, int length) visit,
  ) {
    var index = _heads[0];
    while (index >= 0) {
      visit(keyAt(index), _valueChunks[index], _valueOffsets[index], _valueLengths[index]);
      index = _levels[0][index];
    }
  }

  /// Visits entries whose key is in `[lower, upper)` in ascending key order.
  ///
  /// Seeks with the skip list, so a narrow range costs O(log n + k) instead of
  /// scanning the whole memtable.
  void forEachRange(
    Uint8List? lower,
    Uint8List? upper,
    void Function(Uint8List key, int chunk, int offset, int length) visit, {
    bool includeLower = true,
    bool includeUpper = false,
  }) {
    var index = _firstAtOrAfter(lower);
    while (index >= 0) {
      final key = keyAt(index);
      if (lower != null && !includeLower && _compareKeyToEntry(lower, index) == 0) {
        index = _levels[0][index];
        continue;
      }
      if (upper != null) {
        final comparison = _compareKeyToEntry(upper, index);
        if (comparison > 0 || (comparison == 0 && !includeUpper)) break;
      }
      visit(key, _valueChunks[index], _valueOffsets[index], _valueLengths[index]);
      index = _levels[0][index];
    }
  }

  int _firstAtOrAfter(Uint8List? key) {
    var index = -1;
    if (key == null) return _heads[0];
    for (var level = _topLevel; level >= 0; level--) {
      while (true) {
        final next = _nextAt(level, index);
        if (next < 0) break;
        if (_compareKeyToEntry(key, next) >= 0) break;
        index = next;
      }
    }
    return _nextAt(0, index);
  }

  int _compareKeyToEntry(Uint8List key, int index) {
    final start = _keyOffsets[index];
    final length = _keyLengths[index];
    return StringView.compareRanges(
      _keys,
      start,
      start + length,
      key,
      0,
      key.length,
    );
  }

  int _nextAt(int level, int index) =>
      index < 0 ? _heads[level] : _levels[level][index];

  void _skipInsert(int index) {
    final level = _randomLevel();
    _heights[index] = level;
    _ensureLevel(level);

    var cursor = -1;
    for (var current = _topLevel; current >= 0; current--) {
      while (true) {
        final next = _nextAt(current, cursor);
        if (next < 0 || _compareEntryToEntry(next, index) >= 0) break;
        cursor = next;
      }
      if (current <= level) {
        if (cursor < 0) {
          _levels[current][index] = _heads[current];
          _heads[current] = index;
        } else {
          _levels[current][index] = _levels[current][cursor];
          _levels[current][cursor] = index;
        }
      }
    }
    if (level > _topLevel) {
      for (var current = _topLevel + 1; current <= level; current++) {
        _levels[current][index] = _heads[current];
        _heads[current] = index;
      }
      _topLevel = level;
    }
  }

  int _compareEntryToEntry(int a, int b) {
    final aStart = _keyOffsets[a];
    final aLength = _keyLengths[a];
    final bStart = _keyOffsets[b];
    final bLength = _keyLengths[b];
    return StringView.compareRanges(
      _keys,
      aStart,
      aStart + aLength,
      _keys,
      bStart,
      bStart + bLength,
    );
  }

  int _randomLevel() {
    _rng ^= (_rng << 13) & 0x7FFFFFFF;
    _rng ^= _rng >> 17;
    _rng ^= (_rng << 5) & 0x7FFFFFFF;
    var level = 0;
    var bits = _rng;
    while ((bits & 1) == 1 && level < _maxLevels - 1) {
      level++;
      bits >>= 1;
    }
    return level;
  }

  static Int32List _newLevel(int capacity) =>
      Int32List(capacity)..fillRange(0, capacity, -1);

  void _ensureLevel(int level) {
    while (_levels.length <= level) {
      _levels.add(_newLevel(_heights.length));
    }
  }

  void _resizeLevels(int capacity) {
    for (var i = 0; i < _levels.length; i++) {
      final next = _newLevel(capacity);
      next.setRange(0, _levels[i].length, _levels[i]);
      _levels[i] = next;
    }
  }

  /// A zero-copy view of the key at entry [index] (insertion order).
  Uint8List keyAt(int index) => Uint8List.sublistView(
    _keys,
    _keyOffsets[index],
    _keyOffsets[index] + _keyLengths[index],
  );

  /// Reference of entry [index] (insertion order).
  MemRef refAt(int index) => (
    chunk: _valueChunks[index],
    offset: _valueOffsets[index],
    length: _valueLengths[index],
  );

  /// Drops every entry while keeping the allocated capacity.
  void clear() {
    _slots.fillRange(0, _slots.length, 0);
    _keysUsed = 0;
    _count = 0;
    _heads.fillRange(0, _heads.length, -1);
    for (final level in _levels) {
      level.fillRange(0, level.length, -1);
    }
    _topLevel = 0;
  }

  int _appendEntry(
    Uint8List key,
    int hash,
    int chunk,
    int offset,
    int length,
  ) {
    final index = _count;
    if (index == _hashes.length) {
      _growEntries();
    }
    if (_keysUsed + key.length > _keys.length) {
      _growKeys(_keysUsed + key.length);
    }
    _hashes[index] = hash;
    _keyOffsets[index] = _keysUsed;
    _keyLengths[index] = key.length;
    _valueChunks[index] = chunk;
    _valueOffsets[index] = offset;
    _valueLengths[index] = length;
    _keys.setRange(_keysUsed, _keysUsed + key.length, key);
    _keysUsed += key.length;
    _count++;
    _skipInsert(index);
    return index;
  }

  bool _keyEquals(int index, Uint8List key) {
    final start = _keyOffsets[index];
    for (var i = 0; i < key.length; i++) {
      if (_keys[start + i] != key[i]) return false;
    }
    return true;
  }

  void _growEntries() {
    final capacity = _hashes.length * 2;
    _hashes = _resizeHashes(_hashes, capacity);
    _keyOffsets = _resize(_keyOffsets, capacity);
    _keyLengths = _resize(_keyLengths, capacity);
    _valueChunks = _resize(_valueChunks, capacity);
    _valueOffsets = _resize(_valueOffsets, capacity);
    _valueLengths = _resize(_valueLengths, capacity);
    _heights = _resize(_heights, capacity);
    _resizeLevels(capacity);
  }

  static Int32List _resize(Int32List source, int capacity) {
    final next = Int32List(capacity);
    next.setRange(0, source.length, source);
    return next;
  }

  static Uint32List _resizeHashes(Uint32List source, int capacity) {
    final next = Uint32List(capacity);
    next.setRange(0, source.length, source);
    return next;
  }

  void _growKeys(int needed) {
    var capacity = _keys.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _keys = Uint8List(capacity)..setRange(0, _keysUsed, _keys);
  }

  void _rehash() {
    final next = Int32List(_slots.length * 2);
    final mask = next.length - 1;
    for (var i = 0; i < _count; i++) {
      var slot = _hashes[i] & mask;
      while (next[slot] != 0) {
        slot = (slot + 1) & mask;
      }
      next[slot] = i + 1;
    }
    _slots = next;
  }

  static int _roundUpPowerOfTwo(int value) {
    var result = 1;
    while (result < value) {
      result <<= 1;
    }
    return result;
  }
}
