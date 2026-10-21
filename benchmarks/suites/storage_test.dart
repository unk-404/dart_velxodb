// Block, WAL and memtable codecs, plus the engine write path.
//
// The engine here runs over a counting no-I/O directory: this file measures the
// WAL/arena/memtable machine, not the disk. Real files and fsync policy are
// measured by `scenarios/durability_bench.dart`.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

void main() {
  final doc = chatDocument();
  final writer = BlockWriter(targetSize: 8 * 1024);
  for (var i = 0; i < kDocsPerBlock; i++) {
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
  final keys = keysFor(kKeyCount);
  for (final key in keys) {
    memtable.put(key, 0, 0, kDocBytes);
  }

  final engine = StorageEngine(directory: CountingDirectory())..openSync();

  group('storage', () {
    benchmark('block.write', () {
      final w = BlockWriter(targetSize: 8 * 1024);
      for (var round = 0; round < kBatch; round++) {
        w.reset();
        for (var i = 0; i < kDocsPerBlock; i++) {
          w.append(doc);
        }
        sink = w.finish().length;
      }
    });

    benchmark('block.read', () {
      var acc = 0;
      for (var round = 0; round < kBatch; round++) {
        reader.forEach((document) {
          acc += document.byteLength;
        });
      }
      sink = acc;
    });

    benchmark('wal.frame', () {
      for (var round = 0; round < kBatch; round++) {
        sink = WalFrame.encode(walPayload).length;
      }
    });

    benchmark('wal.batch', () {
      for (var round = 0; round < kBatch; round++) {
        WalBatch.decode(walPayload, (_, _, _) {});
      }
    });

    benchmark('memtable.get', () {
      for (var round = 0; round < kBatch; round++) {
        for (final key in keys) {
          sink += memtable.get(key)?.length ?? -1;
        }
      }
    });

    benchmark('memtable.put', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < keys.length; i++) {
          memtable.put(keys[i], 0, i, kDocBytes + (round & 3));
        }
      }
    });

    benchmark('engine.put', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < keys.length; i++) {
          engine.putSync(keys[i], doc);
        }
      }
    });

    benchmark('engine.get', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < keys.length; i++) {
          sink += engine.get(keys[i])?.length ?? -1;
        }
      }
    });
  });
}
