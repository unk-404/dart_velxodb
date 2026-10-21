import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../errors.dart';
import 'arena.dart';
import 'check.dart';
import 'directory.dart';
import 'file.dart';
import 'maintenance.dart';
import 'manifest.dart';
import 'memtable.dart';
import 'segment.dart';
import 'wal.dart';

/// How long a committed write may stay in the OS page cache.
enum Durability {
  /// fsync after every WAL frame, including single puts and deletes.
  ///
  /// The strongest guarantee, the slowest mode. A batch or a transaction is
  /// still one frame, so one fsync covers the whole group.
  always,

  /// fsync on flush, close and explicit `sync()` (default).
  ///
  /// A committed write survives a process crash; an OS or power failure may
  /// lose the frames written since the last sync.
  batched,

  /// Never fsync automatically; the caller owns durability.
  none,
}

/// Local storage engine: WAL → memtable → immutable segments.
///
/// The core is synchronous and this is the only class that knows about all the
/// pieces: the WAL knows nothing about memtables or segments, the memtable
/// knows nothing about files, and segments are pure byte codecs.
///
/// Durability ordering on every write:
///
/// 1. append the frame to the WAL,
/// 2. apply it to the arena and memtable.
///
/// Durability ordering on a flush:
///
/// 1. write and flush the segment file,
/// 2. write and flush the manifest (the commit point),
/// 3. truncate the WAL and drop the memtable.
///
/// A crash between 2 and 3 replays the WAL again, which is idempotent: the same
/// key/value pairs overwrite themselves in the new memtable.
final class StorageEngine {
  /// Creates an engine over [directory].
  StorageEngine({
    required SyncStorageDirectory directory,
    int arenaChunkSize = 1 << 20,
    this.maxMemtableBytes = 64 << 20,
    this.blockTargetSize = 64 * 1024,
    this.durability = Durability.batched,
    this.autoFlush = false,
    this.autoCompact = true,
    this.compactionThreshold = 4,
    this.maintenanceScheduler,
  }) : _directory = directory,
       _arenaChunkSize = arenaChunkSize,
       _walFile = directory.openSync(walFileName),
       _arena = DocArena(chunkSize: arenaChunkSize) {
    _wal = Wal(_walFile);
  }

  /// Name of the write-ahead log file.
  static const String walFileName = 'wal.log';

  /// Prefix of segment files.
  static const String segmentPrefix = 'SEG-';

  /// Suffix of segment files.
  static const String segmentSuffix = '.seg';

  final SyncStorageDirectory _directory;
  final int _arenaChunkSize;
  final SyncStorageFile _walFile;
  late final Wal _wal;
  DocArena _arena;
  final MemTable _memtable = MemTable();

  /// Buffered writes while a transaction is open, coalesced by key.
  Map<String, WalOp>? _txOps;

  final List<SegmentReader> _segments = <SegmentReader>[];
  final List<MappedFile> _segmentMaps = <MappedFile>[];
  final List<SegmentInfo> _segmentInfos = <SegmentInfo>[];
  Manifest? _manifest;
  int _nextSegmentId = 1;
  bool _closed = false;

  /// Threshold at which [shouldFlush] becomes true.
  final int maxMemtableBytes;

  /// Target block size when building a segment.
  final int blockTargetSize;

  /// Whether every write flushes the WAL before returning.
  ///
  /// See [Durability]; use [durability] to configure, this getter is for
  /// diagnostics.
  bool get autoSync => durability == Durability.always;

  /// Durability level for committed writes.
  final Durability durability;

  /// Whether crossing [compactionThreshold] segments compacts automatically.
  final bool autoCompact;

  /// Number of segments that triggers an automatic compaction after a flush.
  final int compactionThreshold;

  /// Whether crossing [maxMemtableBytes] flushes to a segment automatically.
  ///
  /// With a [maintenanceScheduler] the flush is deferred, so the write that
  /// crosses the threshold returns first. Without one it runs inline.
  final bool autoFlush;

  /// Optional scheduler for deferred flush/compaction.
  ///
  /// Today the engine is single-isolate: the scheduler is a seam for a future
  /// worker isolate. With [MicrotaskMaintenanceScheduler] the work still runs
  /// on this isolate, but after the triggering write returns.
  final MaintenanceScheduler? maintenanceScheduler;

  bool _maintenanceScheduled = false;

  /// Whether deferred maintenance is scheduled but has not run yet.
  bool get maintenanceScheduled => _maintenanceScheduled;

  /// The memtable, exposed for flushing and tests.
  MemTable get memtable => _memtable;

  /// The document arena, exposed for flushing.
  DocArena get arena => _arena;

  /// Segments currently searched, oldest first.
  List<SegmentReader> get segments => List.unmodifiable(_segments);

  /// Manifest generation, or 0 when nothing has been flushed yet.
  int get generation => _manifest?.generation ?? 0;

  /// Bytes of document payload plus keys currently held in memory.
  int get memoryBytes => _arena.bytesUsed + _memtable.keyBytes;

  /// Whether the write buffer should be flushed to a segment.
  bool get shouldFlush => memoryBytes >= maxMemtableBytes;

  /// Loads the manifest and replays the WAL. Call once before serving reads.
  void openSync() {
    final store = ManifestStore(_directory);
    final manifest = store.loadSync();
    if (manifest != null) {
      _manifest = manifest;
      for (final info in manifest.segments) {
        // Segments are immutable: map them instead of copying. The view stays
        // valid until close(), which unmaps after the engine stops serving.
        final mapped = _directory.mapSync(info.name);
        try {
          final reader = SegmentReader(mapped.bytes);
          _segmentMaps.add(mapped);
          _segments.add(reader);
          _segmentInfos.add(info);
          _trackSegmentId(info.name);
        } on Object catch (error) {
          mapped.closeSync();
          throw VelxoCorruptException(
            'segment ${info.name} is corrupt',
            error,
          );
        }
      }
    }
    for (final name in _directory.listSync()) {
      if (name.startsWith(segmentPrefix) && name.endsWith(segmentSuffix)) {
        _trackSegmentId(name);
      }
    }
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
  ///
  /// Inside a transaction the write is buffered and applied at commit.
  void putSync(Uint8List key, Bytes document) {
    _checkOpen();
    final bytes = document.asUint8List();
    if (_txOps != null) {
      _record(WalOp.put(key, Uint8List.fromList(bytes)));
      return;
    }
    _wal.appendPutSync(key, bytes);
    final ref = _arena.append(bytes);
    _memtable.put(key, ref.chunk, ref.offset, ref.length);
    _afterWrite();
  }

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, Bytes document) async =>
      putSync(key, document);

  /// Inserts or replaces several documents with a single WAL frame.
  void putManySync(List<({Uint8List key, Bytes document})> entries) {
    _checkOpen();
    if (entries.isEmpty) return;
    final ops = <WalOp>[
      for (final entry in entries)
        WalOp.put(entry.key, entry.document.asUint8List()),
    ];
    applyBatchSync(ops);
  }

  /// Async facade over [putManySync].
  Future<void> putMany(
    List<({Uint8List key, Bytes document})> entries,
  ) async => putManySync(entries);

  /// Deletes [key]. Deleting a missing key is allowed.
  ///
  /// Inside a transaction the delete is buffered and applied at commit.
  void deleteSync(Uint8List key) {
    _checkOpen();
    if (_txOps != null) {
      _record(WalOp.delete(key));
      return;
    }
    _wal.appendDeleteSync(key);
    _memtable.putTombstone(key);
    _afterWrite();
  }

  /// Async facade over [deleteSync].
  Future<void> delete(Uint8List key) async => deleteSync(key);

  /// Whether a transaction is currently open.
  bool get inTransaction => _txOps != null;

  /// Runs [body] as one atomic transaction.
  ///
  /// Writes performed through this engine while [body] runs (including writes
  /// made by [Collection] methods) are buffered, become visible to point reads
  /// inside the transaction, and are committed as a single WAL frame. If [body]
  /// throws, nothing is applied.
  ///
  /// Limitations: one writer, no nesting, and scans/cursors do not see
  /// uncommitted writes (point reads do). This is a deliberate, documented
  /// single-process model, not MVCC.
  T transactionSync<T>(T Function() body) {
    _checkOpen();
    if (_txOps != null) {
      throw const VelxoConflictException(
        'nested transactions are not supported',
      );
    }
    _txOps = <String, WalOp>{};
    try {
      final result = body();
      final ops = _txOps!.values.toList(growable: false);
      _txOps = null;
      if (ops.isNotEmpty) _applyBatch(ops);
      return result;
    } catch (_) {
      _txOps = null;
      rethrow;
    }
  }

  void _record(WalOp op) {
    // Coalesce by key: only the last operation per key reaches the WAL.
    _txOps![String.fromCharCodes(op.key)] = op;
  }

  /// Applies puts and deletes as one WAL frame.
  ///
  /// A crash either keeps the whole batch or none of it, which is what lets a
  /// document and its derived entries (index, reverse reference) land together.
  void applyBatchSync(List<WalOp> ops) {
    _checkOpen();
    if (ops.isEmpty) return;
    if (_txOps != null) {
      for (final op in ops) {
        _record(
          op.kind == WalOpKind.put
              ? WalOp.put(op.key, Uint8List.fromList(op.value!))
              : WalOp.delete(op.key),
        );
      }
      return;
    }
    _applyBatch(ops);
  }

  void _applyBatch(List<WalOp> ops) {
    _wal.appendBatchSync(ops);
    for (final op in ops) {
      if (op.kind == WalOpKind.put) {
        final ref = _arena.append(op.value!);
        _memtable.put(op.key, ref.chunk, ref.offset, ref.length);
      } else {
        _memtable.putTombstone(op.key);
      }
    }
    _afterWrite();
  }

  /// Reads [key], or `null` when absent, deleted, or shadowed by a tombstone.
  ///
  /// Views returned from a segment point into the segment's buffer; views from
  /// the memtable point into the arena. Both stay valid until the next flush.
  Bytes? get(Uint8List key) {
    _checkOpen();
    final transaction = _txOps;
    if (transaction != null) {
      final pending = transaction[String.fromCharCodes(key)];
      if (pending != null) {
        if (pending.kind == WalOpKind.delete) return null;
        final bytes = pending.value!;
        return Bytes.view(bytes, 0, bytes.length);
      }
    }
    final ref = _memtable.get(key);
    if (ref != null) {
      return ref.length < 0 ? null : _arena.view(ref.chunk, ref.offset, ref.length);
    }
    for (var i = _segments.length - 1; i >= 0; i--) {
      final hit = _segments[i].lookup(key);
      if (hit == null) continue;
      return hit.tombstone ? null : hit.document?.toBytes();
    }
    return null;
  }

  /// Flushes the memtable into a new segment and resets the WAL.
  ///
  /// Does nothing when the memtable is empty. Returns the new segment info.
  SegmentInfo? flushSync() {
    _checkOpen();
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
    _writeFile(name, bytes.asUint8List());

    final info = SegmentInfo(
      name: name,
      entryCount: builder.docCount,
      byteLength: bytes.length,
    );
    _manifest = ManifestStore(_directory).saveSync(<SegmentInfo>[
      ..._segmentInfos,
      info,
    ]);

    _segments.add(SegmentReader(bytes.asUint8List()));
    _segmentInfos.add(info);

    // Commit point passed: the WAL is no longer needed.
    _walFile.truncateSync(0);
    _walFile.flushSync();
    _memtable.clear();
    _arena = DocArena(chunkSize: _arenaChunkSize);

    // Bounded segment count: compaction runs on the write that crosses the
    // threshold. This costs latency on that one write and keeps reads from
    // degrading silently.
    if (autoCompact && _segments.length >= compactionThreshold) {
      compactSync();
      return _segmentInfos.isEmpty ? info : _segmentInfos.last;
    }
    return info;
  }

  /// Async facade over [flushSync].
  Future<SegmentInfo?> flush() async => flushSync();

  /// Flushes when [shouldFlush] is true.
  bool maybeFlushSync() {
    if (!shouldFlush) return false;
    flushSync();
    return true;
  }

  /// Merges every segment into one, keeping the newest version of each key.
  ///
  /// This is a full compaction: because it rewrites every segment, tombstones
  /// can be dropped entirely — after the merge no older copy of a deleted key
  /// remains. Returns `false` when there was nothing to do.
  bool compactSync() {
    _checkOpen();
    if (_segments.length < 2) return false;

    final builder = SegmentBuilder(blockTargetSize: blockTargetSize);
    final seen = MemTable();
    for (var i = _segments.length - 1; i >= 0; i--) {
      _segments[i].forEachEntry((key, document) {
        if (seen.contains(key)) return;
        seen.put(key, 0, 0, 0);
        if (document == null) return; // tombstone: drop with the old data
        builder.add(key, document.toBytes());
      });
    }

    final oldNames = <String>[for (final info in _segmentInfos) info.name];
    final bytes = builder.finish();
    final name = _segmentName(_nextSegmentId++);
    _writeFile(name, bytes.asUint8List());

    final info = SegmentInfo(
      name: name,
      entryCount: builder.docCount,
      byteLength: bytes.length,
    );
    _manifest = ManifestStore(_directory).saveSync(<SegmentInfo>[info]);

    _segments
      ..clear()
      ..add(SegmentReader(bytes.asUint8List()));
    _segmentInfos
      ..clear()
      ..add(info);
    for (final old in oldNames) {
      _directory.deleteSync(old);
    }
    return true;
  }

  /// Makes everything appended so far durable.
  void syncNow() {
    _checkOpen();
    _walFile.flushSync();
  }

  /// Async facade over [syncNow].
  Future<void> sync() async => syncNow();

  /// Flushes pending writes and releases the directory lock.
  ///
  /// After this call the engine refuses reads as well as writes: a mapped
  /// segment must not be used after it is unmapped.
  void closeSync() {
    if (_closed) return;
    _closed = true;
    _walFile.flushSync();
    _walFile.closeSync();
    for (final mapped in _segmentMaps) {
      mapped.closeSync();
    }
    _segmentMaps.clear();
    _segments.clear();
    _directory.closeSync();
  }

  /// Async facade over [closeSync].
  Future<void> close() async => closeSync();

  /// Verifies the manifest, every referenced segment and the file set.
  ///
  /// This is a read-only diagnostic: it does not repair anything. With
  /// [verifyBlocks] (default) every block's CRC is checked and every document
  /// is parsed, which costs time proportional to the data size.
  CheckReport checkSync({bool verifyBlocks = true}) {
    _checkOpen();
    final issues = <CheckIssue>[];
    final stats = <String, int>{};

    final segmentNames = <String>[
      for (final name in _directory.listSync())
        if (name.startsWith(segmentPrefix) && name.endsWith(segmentSuffix)) name,
    ];
    stats['segmentFiles'] = segmentNames.length;

    Manifest? manifest;
    try {
      manifest = ManifestStore(_directory).loadSync();
    } on Object catch (error) {
      issues.add(
        CheckIssue(CheckSeverity.error, 'manifest', 'read failed: $error'),
      );
    }

    if (manifest == null) {
      if (segmentNames.isNotEmpty) {
        issues.add(
          const CheckIssue(
            CheckSeverity.error,
            'no-manifest',
            'segment files exist but no manifest decodes',
          ),
        );
      }
    } else {
      stats['manifestGeneration'] = manifest.generation;
      stats['segments'] = manifest.segments.length;
      final referenced = <String>{};
      var entries = 0;
      var bytes = 0;
      var documents = 0;
      for (final info in manifest.segments) {
        referenced.add(info.name);
        entries += info.entryCount;
        bytes += info.byteLength;
        if (!_directory.existsSync(info.name)) {
          issues.add(
            CheckIssue(CheckSeverity.error, 'missing-segment', info.name),
          );
          continue;
        }
        SyncStorageFile? file;
        try {
          file = _directory.openSync(info.name, create: false);
          final data = file.readAllSync();
          if (data.length != info.byteLength) {
            issues.add(
              CheckIssue(
                CheckSeverity.warning,
                'segment-size',
                '${info.name}: expected ${info.byteLength}, found ${data.length}',
              ),
            );
          }
          final reader = SegmentReader(data);
          if (verifyBlocks) {
            reader.forEach((_) => documents++);
          }
        } on Object catch (error) {
          issues.add(
            CheckIssue(
              CheckSeverity.error,
              'segment-read',
              '${info.name}: $error',
            ),
          );
        } finally {
          file?.closeSync();
        }
      }
      stats['entries'] = entries;
      stats['bytes'] = bytes;
      if (verifyBlocks) stats['documents'] = documents;
      for (final name in segmentNames) {
        if (!referenced.contains(name)) {
          issues.add(
            CheckIssue(CheckSeverity.warning, 'orphan-segment', name),
          );
        }
      }
    }

    // Use the engine's own WAL handle: opening a second handle and closing it
    // would close the shared handle in in-memory directories.
    stats['walBytes'] = _walFile.lengthSync;
    return CheckReport(issues, stats);
  }

  void _afterWrite() {
    if (durability == Durability.always) _walFile.flushSync();
    if (!autoFlush || !shouldFlush) return;
    final scheduler = maintenanceScheduler;
    // A long synchronous write loop never yields, so a deferred flush must not
    // let memory grow without bound. Past 4x the threshold, flush inline.
    if (scheduler == null || memoryBytes > maxMemtableBytes * 4) {
      flushSync();
      return;
    }
    if (_maintenanceScheduled) return;
    _maintenanceScheduled = true;
    scheduler.schedule(() {
      _maintenanceScheduled = false;
      if (_closed) return;
      flushSync();
    });
  }

  void _writeFile(String name, Uint8List bytes) {
    final file = _directory.openSync(name);
    try {
      file.writeAllSync(bytes);
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }

  void _trackSegmentId(String name) {
    if (!name.startsWith(segmentPrefix) || !name.endsWith(segmentSuffix)) {
      return;
    }
    final digits = name.substring(
      segmentPrefix.length,
      name.length - segmentSuffix.length,
    );
    final id = int.tryParse(digits);
    if (id != null && id >= _nextSegmentId) {
      _nextSegmentId = id + 1;
    }
  }

  static String _segmentName(int id) =>
      '$segmentPrefix${id.toString().padLeft(6, '0')}$segmentSuffix';

  void _checkOpen() {
    if (_closed) throw const VelxoClosedException('engine is closed');
  }
}
