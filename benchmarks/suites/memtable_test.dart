// Memtable range-seek benchmark, isolated so the 50k-entry table does not
// perturb the other benchmark files' heap behaviour.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

void main() {
  final table = MemTable(initialEntries: 1 << 16);
  for (var i = 0; i < kMemtableDocs; i++) {
    table.put(
      Uint8List.fromList('key-${i.toString().padLeft(6, '0')}'.codeUnits),
      0,
      0,
      kDocBytes,
    );
  }
  final lower = Uint8List.fromList('key-025000'.codeUnits);
  final upper = Uint8List.fromList('key-026000'.codeUnits);

  group('storage', () {
    benchmark('memtable.range', () {
      var acc = 0;
      for (var round = 0; round < kBatch; round++) {
        table.forEachRange(lower, upper, (_, _, _, _) {
          acc++;
        });
      }
      sink = acc;
    });
  });
}
