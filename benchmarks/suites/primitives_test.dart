// BytesMut primitives the storage layer is built on.
//
// This file measures `blit`, not velxodb: it is charted as "VXS format" only
// because the engine sits on the same buffer primitives. zstd is deliberately
// absent: the engine and the object-store engine never call it, so charting it
// would advertise a code path that does not exist.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:convert';
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:test/test.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

/// The 130 B sample document, as raw bytes.
final Uint8List payload = Uint8List.fromList(
  utf8.encode(
    '在吗？今天下午三点开会别忘了带材料，会议纪要整理好了我稍后同步到群里。'
    '这个方案我觉得还需要再讨论一下细节，尤其是索引和压缩的取舍。',
  ),
);

/// Documents written (or read back) per iteration.
const int docsPerIteration = 32;

void main() {
  final capacity = docsPerIteration * (4 + payload.length);

  group('format', () {
    benchmark('bytes.mut.write', () {
      final mut = BytesMut(capacity);
      for (var i = 0; i < docsPerIteration; i++) {
        mut.putUint32Unchecked(i, endian: Endian.little);
        mut.putSliceUnchecked(payload);
      }
      sink = mut.length;
    });

    benchmark('bytes.read.view', () {
      final mut = BytesMut(capacity);
      for (var i = 0; i < docsPerIteration; i++) {
        mut.putUint32Unchecked(i, endian: Endian.little);
        mut.putSliceUnchecked(payload);
      }
      final bytes = mut.freeze();
      var acc = 0;
      for (var i = 0; i < docsPerIteration; i++) {
        acc += bytes.getUint32(i * 4, endian: Endian.little);
      }
      sink = acc;
    });
  });
}
