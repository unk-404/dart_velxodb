// Memtable range-seek benchmark, isolated so the 50k-entry table does not
// perturb the other benchmark files' heap behaviour.
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/storage.dart';

int sink = 0;
const int batch = 100;
const int docs = 50000;
const int window = 1000;

void main() {
  final table = MemTable(initialEntries: 1 << 16);
  for (var i = 0; i < docs; i++) {
    table.put(
      Uint8List.fromList('key-${i.toString().padLeft(6, '0')}'.codeUnits),
      0,
      0,
      130,
    );
  }
  final lower = Uint8List.fromList('key-025000'.codeUnits);
  final upper = Uint8List.fromList('key-026000'.codeUnits);

  group('storage', () {
    benchmark('memtable.range', () {
      var acc = 0;
      for (var round = 0; round < batch; round++) {
        table.forEachRange(lower, upper, (_, _, _, _) {
          acc++;
        });
      }
      sink = acc;
    });
  });
}
