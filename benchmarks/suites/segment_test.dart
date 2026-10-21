// Segment build, point lookup, scan, and segment-backed engine reads.
//
// The flushed engine runs on an in-memory directory: the segment bytes are real
// and the bloom/binary-search path is real, but no disk is touched. On-disk
// segment reads are covered by `compare/` and by `scenarios/open_rss_bench.dart`.
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

  // An engine with one flushed segment, for segment-backed point reads.
  final directory = MemoryStorageDirectory();
  final flushedEngine = StorageEngine(directory: directory)..openSync();
  for (var i = 0; i < 256; i++) {
    flushedEngine.putSync(flushKey(i), doc);
  }
  flushedEngine.flushSync();

  // A small segment reused for lookup and scan benchmarks.
  final segmentKeys = <Uint8List>[
    for (var i = 0; i < kSegmentDocs; i++) segmentKey(i),
  ];
  final segmentBuilder = SegmentBuilder(blockTargetSize: 4096);
  for (final key in segmentKeys) {
    segmentBuilder.add(key, doc);
  }
  final segmentBytes = segmentBuilder.finish();
  final segment = SegmentReader(segmentBytes.asUint8List());

  group('storage', () {
    benchmark('segment.build', () {
      for (var round = 0; round < kBatch; round++) {
        final builder = SegmentBuilder(blockTargetSize: 4096);
        for (final key in segmentKeys) {
          builder.add(key, doc);
        }
        sink = builder.finish().length;
      }
    });

    benchmark('segment.find', () {
      for (var round = 0; round < kBatch; round++) {
        for (final key in segmentKeys) {
          sink += segment.find(key)?.byteLength ?? -1;
        }
      }
    });

    benchmark('segment.scan', () {
      var acc = 0;
      for (var round = 0; round < kBatch; round++) {
        segment.forEach((document) {
          acc += document.byteLength;
        });
      }
      sink = acc;
    });

    benchmark('engine.get.segment', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kSegmentDocs; i++) {
          sink += flushedEngine.get(flushKey(i))?.length ?? -1;
        }
      }
    });
  });
}
