// VXS format benchmarks: encode, decode, projection, key comparison, CRC.
//
// Each iteration performs `kBatch` operations: the benchmark harness has
// microsecond-granularity overhead that would otherwise dominate a 130 B encode.
// The per-operation numbers are derived from `lib/manifest.dart`.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

void main() {
  final builder = DocBuilder(schemaId: 1, schemaVersion: 1);
  writeChat(builder);
  final encoded = builder.finish();
  final view = DocView.parse(encoded.asUint8List());
  final docSink = DocSink(capacity: 1 << 16);

  group('serde', () {
    benchmark('encode.5field', () {
      final b = DocBuilder(schemaId: 1, schemaVersion: 1);
      for (var i = 0; i < kBatch; i++) {
        b.reset();
        writeChat(b);
        sink += b.finish().length;
      }
    });

    benchmark('encode.sink', () {
      for (var i = 0; i < kBatch; i++) {
        if (docSink.length > (1 << 12)) docSink.reset();
        docSink.beginDoc(schemaId: 1, schemaVersion: 1);
        writeChatSink(docSink);
        docSink.endDoc();
      }
      sink += docSink.length;
    });

    benchmark('decode.getters', () {
      for (var i = 0; i < kBatch; i++) {
        sink =
            (view.getString(1)?.length ?? 0) +
            (view.getString(2)?.length ?? 0) +
            (view.getInt(3) ?? 0) +
            (view.getInt(4) ?? 0) +
            (view.getString(5)?.length ?? 0);
      }
    });

    final schema = VxsSchema(
      id: 1,
      version: 1,
      fields: const <VxsField>[
        VxsField(1, 'messageId', VxsType.string),
        VxsField(2, 'conversationId', VxsType.string),
        VxsField(3, 'senderId', VxsType.int64),
        VxsField(4, 'createdAt', VxsType.int64),
        VxsField(5, 'text', VxsType.string),
      ],
    );
    const projection = <int>[1, 2, 3, 4, 5];

    benchmark('project.fields', () {
      for (var i = 0; i < kBatch; i++) {
        final values = view.project(schema, projection);
        sink = values.length;
      }
    });

    benchmark('decode.singleScan', () {
      var acc = 0;
      for (var i = 0; i < kBatch; i++) {
        final cursor = view.cursor();
        while (cursor.next()) {
          acc += cursor.wireType == VxsWire.varint
              ? cursor.intValue
              : cursor.valueLength;
        }
      }
      sink = acc;
    });

    benchmark('project.one', () {
      for (var i = 0; i < kBatch; i++) {
        sink += view.getString(5)?.length ?? 0;
      }
    });

    final a = StringView.of(
      Uint8List.fromList('01J8Z4K2M3N4P5Q6R7S8T9V0W1'.codeUnits),
    );
    final b = StringView.of(
      Uint8List.fromList('01J8Z4K2M3N4P5Q6R7S8T9V0W2'.codeUnits),
    );
    benchmark('view.compare', () {
      for (var i = 0; i < kBatch; i++) {
        if (a.compareTo(b) < 0) sink++;
      }
    });

    final kib = Uint8List(kCrcBytes);
    for (var i = 0; i < kib.length; i++) {
      kib[i] = i % 251;
    }
    benchmark('crc.1KiB', () {
      for (var i = 0; i < kBatch; i++) {
        sink += VxsCrc32c.compute(kib);
      }
    });
  });
}
