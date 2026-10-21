// Storage-layer benchmarks: blocks, WAL, memtable and the write path.
//   dart run benchmark_test --output jsonl benchmark
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

const int batch = 100;
const int docsPerBlock = 20;

Bytes chatMessage() => (DocBuilder(schemaId: 1)
      ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
      ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
      ..putInt(3, 7)
      ..putInt(4, 1750000000000)
      ..putString(5, '在吗？今天下午三点开会，别忘了带材料。'))
    .finish();

void main() {
  final doc = chatMessage();
  final writer = BlockWriter(targetSize: 8 * 1024);
  for (var i = 0; i < docsPerBlock; i++) {
    writer.append(doc);
  }
  final block = writer.finish();
  final reader = BlockReader(block.asUint8List());

  final walPayload = WalBatch.encode(<WalOp>[
    WalOp.put(
      Uint8List.fromList('01J8Z4K2M3N4P5Q6R7S8T9V0W1'.codeUnits),
      doc.asUint8List(),
    ),
  ]);

  final memtable = MemTable(initialEntries: 256);
  final keys = <Uint8List>[
    for (var i = 0; i < 64; i++)
      Uint8List.fromList('key-${i.toString().padLeft(4, '0')}'.codeUnits),
  ];
  for (final key in keys) {
    memtable.put(key, 0, 0, 130);
  }

  // The engine benchmark swallows WAL bytes so a long run does not turn into
  // hundreds of megabytes of log.
  final engine = StorageEngine(directory: _NullDirectory());
  engine.openSync();

  // An engine with one flushed segment, for segment-backed point reads.
  final flushedDirectory = MemoryStorageDirectory();
  final flushedEngine = StorageEngine(directory: flushedDirectory);
  flushedEngine.openSync();
  for (var i = 0; i < 256; i++) {
    flushedEngine.putSync(
      Uint8List.fromList('flush-${i.toString().padLeft(4, '0')}'.codeUnits),
      doc,
    );
  }
  flushedEngine.flushSync();

  // A small segment reused for lookup and scan benchmarks.
  const segmentDocs = 64;
  final segmentKeys = <Uint8List>[
    for (var i = 0; i < segmentDocs; i++)
      Uint8List.fromList('seg-${i.toString().padLeft(3, '0')}'.codeUnits),
  ];
  final segmentBuilder = SegmentBuilder(blockTargetSize: 4096);
  for (final key in segmentKeys) {
    segmentBuilder.add(key, doc);
  }
  final segmentBytes = segmentBuilder.finish();
  final segment = SegmentReader(segmentBytes.asUint8List());

  group('storage', () {
    benchmark('block.write', () {
      final w = BlockWriter(targetSize: 8 * 1024);
      for (var round = 0; round < batch; round++) {
        w.reset();
        for (var i = 0; i < docsPerBlock; i++) {
          w.append(doc);
        }
        sink = w.finish().length;
      }
    });

    benchmark('block.read', () {
      var acc = 0;
      for (var round = 0; round < batch; round++) {
        reader.forEach((document) {
          acc += document.byteLength;
        });
      }
      sink = acc;
    });

    benchmark('wal.frame', () {
      for (var round = 0; round < batch; round++) {
        sink = WalFrame.encode(walPayload).length;
      }
    });

    benchmark('wal.batch', () {
      for (var round = 0; round < batch; round++) {
        WalBatch.decode(walPayload, (_, _, _) {});
      }
    });

    benchmark('memtable.get', () {
      for (var round = 0; round < batch; round++) {
        for (final key in keys) {
          sink += memtable.get(key)?.length ?? -1;
        }
      }
    });

    benchmark('memtable.put', () {
      for (var round = 0; round < batch; round++) {
        for (var i = 0; i < keys.length; i++) {
          memtable.put(keys[i], 0, i, 130 + (round & 3));
        }
      }
    });

    benchmark('engine.put', () {
      for (var round = 0; round < batch; round++) {
        for (var i = 0; i < keys.length; i++) {
          engine.putSync(keys[i], doc);
        }
      }
    });

    benchmark('engine.get', () {
      for (var round = 0; round < batch; round++) {
        for (var i = 0; i < keys.length; i++) {
          sink += engine.get(keys[i])?.length ?? -1;
        }
      }
    });

    benchmark('segment.build', () {
      for (var round = 0; round < batch; round++) {
        final builder = SegmentBuilder(blockTargetSize: 4096);
        for (final key in segmentKeys) {
          builder.add(key, doc);
        }
        sink = builder.finish().length;
      }
    });

    benchmark('segment.find', () {
      for (var round = 0; round < batch; round++) {
        for (final key in segmentKeys) {
          sink += segment.find(key)?.byteLength ?? -1;
        }
      }
    });

    benchmark('segment.scan', () {
      var acc = 0;
      for (var round = 0; round < batch; round++) {
        segment.forEach((document) {
          acc += document.byteLength;
        });
      }
      sink = acc;
    });

    benchmark('engine.get.segment', () {
      for (var round = 0; round < batch; round++) {
        for (var i = 0; i < 64; i++) {
          final key = Uint8List.fromList(
            'flush-${i.toString().padLeft(4, '0')}'.codeUnits,
          );
          sink += flushedEngine.get(key)?.length ?? -1;
        }
      }
    });
  });
}

/// Counts bytes but never stores them.
final class _NullStorageFile implements SyncStorageFile {
  int _length = 0;

  @override
  int get lengthSync => _length;

  @override
  void appendSync(Uint8List bytes) => _length += bytes.length;

  @override
  Uint8List readAtSync(int offset, int length) =>
      throw UnsupportedError('null file');

  @override
  void truncateSync(int length) => _length = length;

  @override
  void flushSync() {}

  @override
  Uint8List readAllSync() => Uint8List(0);

  @override
  void writeAllSync(Uint8List bytes) => _length = bytes.length;

  @override
  void closeSync() {}
}

/// Hands out the null WAL file and refuses everything else.
final class _NullDirectory implements SyncStorageDirectory {
  final _NullStorageFile _wal = _NullStorageFile();

  @override
  SyncStorageFile openSync(String name, {bool create = true}) {
    if (name == StorageEngine.walFileName) return _wal;
    throw UnsupportedError('null directory does not support $name');
  }

  @override
  bool existsSync(String name) => false;

  @override
  void deleteSync(String name) {}

  @override
  void renameSync(String from, String to) {}

  @override
  List<String> listSync() => const <String>[];

  @override
  MappedFile mapSync(String name) =>
      throw UnsupportedError('null directory');
}
