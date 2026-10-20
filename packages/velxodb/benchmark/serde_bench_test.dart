// VXS format benchmarks. Run from packages/velxodb:
//   dart run benchmark_test --output jsonl benchmark
//
// Each iteration performs [batch] operations: the benchmark harness has
// microsecond-granularity overhead that would otherwise dominate a 130-byte
// encode. Derived per-op numbers live in `benchcat.toml`.
import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

const int batch = 100;

DocBuilder newBuilder() => DocBuilder(schemaId: 1, schemaVersion: 1);

/// A realistic chat message: id, conversation, sender, timestamp, text.
void writeChat(DocBuilder builder) {
  builder
    ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
    ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
    ..putInt(3, 7)
    ..putInt(4, 1750000000000)
    ..putString(5, '在吗？今天下午三点开会，别忘了带材料。');
}

/// The same message written through the batch path (no per-doc allocation).
void writeChatSink(DocSink sink) {
  sink
    ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
    ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
    ..putInt(3, 7)
    ..putInt(4, 1750000000000)
    ..putString(5, '在吗？今天下午三点开会，别忘了带材料。');
}

void main() {
  final builder = newBuilder();
  writeChat(builder);
  final encoded = builder.finish();
  final view = DocView.parse(encoded.asUint8List());
  final docSink = DocSink(capacity: 1 << 16);

  group('serde', () {
    benchmark('encode.5field', () {
      final b = newBuilder();
      for (var i = 0; i < batch; i++) {
        b.reset();
        writeChat(b);
        sink += b.finish().length;
      }
    });

    benchmark('encode.sink', () {
      for (var i = 0; i < batch; i++) {
        if (docSink.length > (1 << 12)) docSink.reset();
        docSink.beginDoc(schemaId: 1, schemaVersion: 1);
        writeChatSink(docSink);
        docSink.endDoc();
      }
      sink += docSink.length;
    });

    benchmark('decode.getters', () {
      for (var i = 0; i < batch; i++) {
        sink =
            (view.getString(1)?.length ?? 0) +
            (view.getString(2)?.length ?? 0) +
            (view.getInt(3) ?? 0) +
            (view.getInt(4) ?? 0) +
            (view.getString(5)?.length ?? 0);
      }
    });

    benchmark('decode.singleScan', () {
      var acc = 0;
      for (var i = 0; i < batch; i++) {
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
      for (var i = 0; i < batch; i++) {
        sink += view.getString(5)?.length ?? 0;
      }
    });
  });
}
