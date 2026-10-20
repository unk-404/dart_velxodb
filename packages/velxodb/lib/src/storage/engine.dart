import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'arena.dart';
import 'file.dart';
import 'memtable.dart';
import 'wal.dart';

/// Write path of the storage engine: WAL → arena → memtable.
///
/// This is deliberately the *only* place that knows about all three pieces. The
/// WAL knows nothing about memtables, the memtable knows nothing about files,
/// and the arena only hands out stable byte references.
///
/// The core is synchronous. `await`-ing three nested futures per insert costs
/// more than the insert, so the async API is a thin `async` facade over the
/// sync methods — callers that need throughput call the sync ones directly.
///
/// Durability contract: [putSync] and [deleteSync] append to the WAL before the
/// change becomes visible in memory. [syncNow] is what makes those appends
/// durable; the caller decides the policy (per batch, timed, or on close).
final class StorageEngine {
  /// Creates an engine writing to [walFile].
  StorageEngine({
    required SyncStorageFile walFile,
    int arenaChunkSize = 1 << 20,
    this.maxMemtableBytes = 64 << 20,
  }) : _walFile = walFile,
       _wal = Wal(walFile),
       _arena = DocArena(chunkSize: arenaChunkSize);

  final SyncStorageFile _walFile;
  final Wal _wal;
  final DocArena _arena;
  final MemTable _memtable = MemTable();

  /// Threshold at which [shouldFlush] becomes true.
  final int maxMemtableBytes;

  bool _closed = false;

  /// The memtable, exposed for flushing and tests.
  MemTable get memtable => _memtable;

  /// The document arena, exposed for flushing.
  DocArena get arena => _arena;

  /// Bytes of document payload plus keys currently held in memory.
  int get memoryBytes => _arena.bytesUsed + _memtable.keyBytes;

  /// Whether the write buffer should be flushed to a segment.
  bool get shouldFlush => memoryBytes >= maxMemtableBytes;

  /// Replays the WAL into the memtable. Call once before serving reads.
  void openSync() {
    _wal.replaySync((payload) {
      WalBatch.decode(payload, (kind, key, value) {
        if (kind == WalOpKind.put) {
          final ref = _arena.append(value!);
          _memtable.put(key, ref.chunk, ref.offset, ref.length);
        } else {
          _memtable.putTombstone(key);
        }
      });
    });
  }

  /// Async facade over [openSync].
  Future<void> open() async => openSync();

  /// Inserts or replaces [key] with the encoded [document].
  void putSync(Uint8List key, Bytes document) {
    _checkOpen();
    final bytes = document.asUint8List();
    _wal.appendPutSync(key, bytes);
    final ref = _arena.append(bytes);
    _memtable.put(key, ref.chunk, ref.offset, ref.length);
  }

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, Bytes document) async => putSync(key, document);

  /// Inserts or replaces several documents with a single WAL frame.
  ///
  /// Batching is the difference between one checksum and append per document
  /// and one per batch, which is where most of the write-path cost lives.
  void putManySync(List<({Uint8List key, Bytes document})> entries) {
    _checkOpen();
    if (entries.isEmpty) return;
    final ops = <WalOp>[
      for (final entry in entries)
        WalOp.put(entry.key, entry.document.asUint8List()),
    ];
    _wal.appendBatchSync(ops);
    for (final entry in entries) {
      final ref = _arena.append(entry.document.asUint8List());
      _memtable.put(entry.key, ref.chunk, ref.offset, ref.length);
    }
  }

  /// Async facade over [putManySync].
  Future<void> putMany(
    List<({Uint8List key, Bytes document})> entries,
  ) async => putManySync(entries);

  /// Deletes [key]. Deleting a missing key is allowed.
  void deleteSync(Uint8List key) {
    _checkOpen();
    _wal.appendDeleteSync(key);
    _memtable.putTombstone(key);
  }

  /// Async facade over [deleteSync].
  Future<void> delete(Uint8List key) async => deleteSync(key);

  /// Reads [key], or `null` when absent or deleted.
  ///
  /// The returned view points into the arena and stays valid until the next
  /// flush drops the memtable.
  Bytes? get(Uint8List key) {
    final ref = _memtable.get(key);
    if (ref == null || ref.length < 0) return null;
    return _arena.view(ref.chunk, ref.offset, ref.length);
  }

  /// Makes everything appended so far durable.
  void syncNow() {
    _checkOpen();
    _walFile.flushSync();
  }

  /// Async facade over [syncNow].
  Future<void> sync() async => syncNow();

  /// Flushes pending writes. The underlying file stays owned by the caller.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _walFile.flushSync();
  }

  void _checkOpen() {
    if (_closed) throw StateError('engine is closed');
  }
}
