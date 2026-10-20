// Storage-layer benchmarks: block packing and WAL framing.
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
  });
}
