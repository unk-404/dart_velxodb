import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'arena.dart';
import 'manifest.dart';
import 'memtable.dart';
import 'object_store.dart';
import 'segment.dart';
import 'wal.dart';

/// Object-store backed engine (S3-style): segments and the manifest are
/// objects, and every write batch appends one small WAL object.
///
/// Request shape per operation, which is what an S3 bill is based on:
///
/// | operation | requests |
/// | --- | --- |
/// | put/delete batch | 1 PUT (WAL) |
/// | flush | 1 PUT segment + 1 PUT manifest + 1 batch DELETE of WAL objects |
/// | open | 1 GET manifest + 1 LIST WAL + K GET WAL |
/// | first read of a segment | 1 GET, then served from the LRU cache |
/// | compact | S GET segments + 1 PUT segment + 1 PUT manifest + 1 batch DELETE |
///
/// Segments are fetched lazily and cached in memory ([segmentCacheSize]); the
/// manifest is the only object read at open, so startup does not scale with
/// database size.
final class ObjectStoreEngine {
  /// Creates an engine over [store] under [prefix].
  ObjectStoreEngine({
    required this.store,
    this.prefix = 'db/',
    this.blockTargetSize = 64 * 1024,
    int arenaChunkSize = 1 << 20,
    this.segmentCacheSize = 4,
  }) : _arenaChunkSize = arenaChunkSize,
       _arena = DocArena(chunkSize: arenaChunkSize);

  /// Backing object store.
  final ObjectStore store;

  /// Key prefix for this database.
  final String prefix;

  /// Target block size inside a segment.
  final int blockTargetSize;

  /// How many fetched segments stay in memory (LRU).
  final int segmentCacheSize;

  final int _arenaChunkSize;
  final MemTable _memtable = MemTable();
  DocArena _arena;
  final List<SegmentInfo> _segmentInfos = <SegmentInfo>[];
  final List<String> _walKeys = <String>[];
  final Map<int, SegmentReader> _segmentCache = <int, SegmentReader>{};
  final List<int> _lru = <int>[];

  int _generation = 0;
  int _nextSegmentId = 1;
  int _nextWalSeq = 1;

  static const String manifestKey = 'MANIFEST';
  static const String segmentPrefix = 'SEG-';
  static const String segmentSuffix = '.seg';
  static const String walPrefix = 'wal/';

  /// Segments known from the manifest, oldest first.
  List<SegmentInfo> get segments => List.unmodifiable(_segmentInfos);

  /// Manifest generation.
  int get generation => _generation;

  /// Bytes buffered in the memtable (payload plus keys).
  int get memoryBytes => _arena.bytesUsed + _memtable.keyBytes;

  /// Segments currently cached in memory.
  int get cachedSegments => _segmentCache.length;

  /// Loads the manifest metadata and replays pending WAL objects.
  ///
  /// Segment payloads are not downloaded here; the first read of a segment
  /// fetches it.
  Future<void> open() async {
    final manifestBytes = await store.get(_key(manifestKey));
    if (manifestBytes != null) {
      final manifest = Manifest.decode(manifestBytes);
      _generation = manifest.generation;
      for (final info in manifest.segments) {
        _segmentInfos.add(info);
        _trackSegmentId(info.name);
      }
    }

    final walKeys = await store.list(_key(walPrefix));
    walKeys.sort();
    for (final key in walKeys) {
      final payload = await store.get(key);
      if (payload == null) continue;
      WalBatch.decode(payload, (kind, walKey, value) {
        if (kind == WalOpKind.put) {
          final ref = _arena.append(value!);
          _memtable.put(walKey, ref.chunk, ref.offset, ref.length);
        } else {
          _memtable.putTombstone(walKey);
        }
      });
      _walKeys.add(key);
      _trackWalSeq(key);
    }
  }

  /// Reads [key], or `null`. Fetches a segment object on a cache miss.
  Future<Bytes?> get(Uint8List key) async {
    final ref = _memtable.get(key);
    if (ref != null) {
      return ref.length < 0
          ? null
          : _arena.view(ref.chunk, ref.offset, ref.length);
    }
    for (var i = _segmentInfos.length - 1; i >= 0; i--) {
      final reader = await _readerAt(i);
      final hit = reader.lookup(key);
      if (hit == null) continue;
      return hit.tombstone ? null : hit.document?.toBytes();
    }
    return null;
  }

  /// Inserts or replaces one key.
  Future<void> put(Uint8List key, Bytes document) async {
    await putMany(<({Uint8List key, Bytes document})>[
      (key: key, document: document),
    ]);
  }

  /// Appends one WAL object containing every put.
  Future<void> putMany(
    List<({Uint8List key, Bytes document})> entries,
  ) async {
    if (entries.isEmpty) return;
    final ops = <WalOp>[
      for (final entry in entries)
        WalOp.put(entry.key, entry.document.asUint8List()),
    ];
    await _appendWal(ops);
  }

  /// Deletes [key].
  Future<void> delete(Uint8List key) async {
    await _appendWal(<WalOp>[WalOp.delete(key)]);
  }

  /// Deletes several keys with one WAL object.
  Future<void> deleteMany(List<Uint8List> keys) async {
    if (keys.isEmpty) return;
    await _appendWal(<WalOp>[for (final key in keys) WalOp.delete(key)]);
  }

  /// Flushes the memtable into a segment object and commits the manifest.
  Future<SegmentInfo?> flush() async {
    if (_memtable.length == 0) return null;
    final builder = SegmentBuilder(blockTargetSize: blockTargetSize);
    _memtable.forEachSorted((key, chunk, offset, length) {
      if (length < 0) {
        builder.addTombstone(key);
      } else {
        builder.add(key, _arena.view(chunk, offset, length));
      }
    });
    final bytes = builder.finish();
    final name = _segmentName(_nextSegmentId++);
    await store.put(_key(name), bytes.asUint8List());

    final info = SegmentInfo(
      name: name,
      entryCount: builder.docCount,
      byteLength: bytes.length,
    );
    _segmentInfos.add(info);
    _generation++;
    await store.put(
      _key(manifestKey),
      Manifest(generation: _generation, segments: _segmentInfos).encode(),
    );

    // The manifest is the commit point; WAL objects can go now.
    await store.deleteMany(<String>[..._walKeys]);
    _walKeys.clear();

    _memtable.clear();
    _arena = DocArena(chunkSize: _arenaChunkSize);
    return info;
  }

  /// Merges every segment into one, dropping tombstones.
  Future<bool> compact() async {
    if (_segmentInfos.length < 2) return false;
    final builder = SegmentBuilder(blockTargetSize: blockTargetSize);
    final seen = MemTable();
    for (var i = _segmentInfos.length - 1; i >= 0; i--) {
      final reader = await _readerAt(i);
      reader.forEachEntry((key, document) {
        if (seen.contains(key)) return;
        seen.put(key, 0, 0, 0);
        if (document == null) return;
        builder.add(key, document.toBytes());
      });
    }
    final bytes = builder.finish();
    final name = _segmentName(_nextSegmentId++);
    await store.put(_key(name), bytes.asUint8List());

    final info = SegmentInfo(
      name: name,
      entryCount: builder.docCount,
      byteLength: bytes.length,
    );
    final oldNames = <String>[
      for (final segment in _segmentInfos) segment.name,
    ];
    _generation++;
    await store.put(
      _key(manifestKey),
      Manifest(generation: _generation, segments: <SegmentInfo>[info]).encode(),
    );
    await store.deleteMany(<String>[for (final old in oldNames) _key(old)]);

    _segmentInfos
      ..clear()
      ..add(info);
    _segmentCache.clear();
    _lru.clear();
    return true;
  }

  /// Flushes pending writes.
  Future<void> close({bool flush = true}) async {
    if (flush) await this.flush();
  }

  Future<SegmentReader> _readerAt(int index) async {
    final cached = _segmentCache[index];
    if (cached != null) {
      _touch(index);
      return cached;
    }
    final info = _segmentInfos[index];
    final bytes = await store.get(_key(info.name));
    if (bytes == null) {
      throw StateError('manifest references missing segment ${info.name}');
    }
    final reader = SegmentReader(bytes);
    _segmentCache[index] = reader;
    _touch(index);
    while (_lru.length > segmentCacheSize) {
      _segmentCache.remove(_lru.removeAt(0));
    }
    return reader;
  }

  void _touch(int index) {
    _lru.remove(index);
    _lru.add(index);
  }

  Future<void> _appendWal(List<WalOp> ops) async {
    final payload = WalBatch.encode(ops);
    final seq = _nextWalSeq++;
    final key = _key('$walPrefix${seq.toString().padLeft(12, '0')}');
    await store.put(key, payload);
    _walKeys.add(key);
    for (final op in ops) {
      if (op.kind == WalOpKind.put) {
        final ref = _arena.append(op.value!);
        _memtable.put(op.key, ref.chunk, ref.offset, ref.length);
      } else {
        _memtable.putTombstone(op.key);
      }
    }
  }

  String _key(String name) => '$prefix$name';

  void _trackSegmentId(String name) {
    if (!name.startsWith(segmentPrefix) || !name.endsWith(segmentSuffix)) {
      return;
    }
    final digits = name.substring(
      segmentPrefix.length,
      name.length - segmentSuffix.length,
    );
    final id = int.tryParse(digits);
    if (id != null && id >= _nextSegmentId) _nextSegmentId = id + 1;
  }

  void _trackWalSeq(String key) {
    final name = key.substring(key.lastIndexOf(walPrefix) + walPrefix.length);
    final seq = int.tryParse(name);
    if (seq != null && seq >= _nextWalSeq) _nextWalSeq = seq + 1;
  }

  static String _segmentName(int id) =>
      '$segmentPrefix${id.toString().padLeft(6, '0')}$segmentSuffix';
}
