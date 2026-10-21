// Object-store benchmark with request/byte accounting.
//
//   dart run benchmark/object_store_bench.dart
//
// No network: SimulatedObjectStore counts every request and byte, so the numbers
// describe the engine's request shape and the local CPU cost. The engine itself
// is backend-agnostic; any store implementing get/put/delete/list can host the
// same segments.
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

const int totalDocs = 200000;
const int batchSize = 500;
const int flushEvery = 50000;
const int updates = 40000;
const int deletes = 20000;
const int reads = 20000;

final Uint8List document = (DocBuilder(schemaId: 1)
      ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
      ..putString(2, '01J8Z4K2M3N4P5Q6R7S8T9V0W2')
      ..putInt(3, 7)
      ..putInt(4, 1750000000000)
      ..putString(5, '在吗？今天下午三点开会，别忘了带材料。'))
    .finish()
    .asUint8List();

Uint8List keyOf(int index) =>
    Uint8List.fromList('doc-${index.toString().padLeft(9, '0')}'.codeUnits);

var seed = 0x9E3779B9;

int nextSeed() {
  seed ^= (seed << 13) & 0xFFFFFFFF;
  seed ^= seed >> 17;
  seed ^= (seed << 5) & 0xFFFFFFFF;
  return seed & 0x7FFFFFFF;
}

String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)}MB';

void main() async {
  final store = SimulatedObjectStore();
  final engine = ObjectStoreEngine(store: store);
  final doc = Bytes.fromUint8List(document);
  final phases = <String, ObjectStoreStats>{};
  final wall = <String, int>{};

  Future<void> phase(String name, Future<void> Function() body) async {
    final before = store.stats;
    final stopwatch = Stopwatch()..start();
    await body();
    stopwatch.stop();
    phases[name] = store.stats - before;
    wall[name] = stopwatch.elapsedMilliseconds;
  }

  await phase('open (empty)', engine.open);

  await phase('import $totalDocs docs', () async {
    for (var offset = 0; offset < totalDocs; offset += batchSize) {
      final count = (offset + batchSize > totalDocs)
          ? totalDocs - offset
          : batchSize;
      await engine.putMany(<({Uint8List key, Bytes document})>[
        for (var i = offset; i < offset + count; i++)
          (key: keyOf(i), document: doc),
      ]);
      if ((offset + count) % flushEvery == 0) {
        await engine.flush();
      }
    }
  });

  await phase('churn $updates updates + $deletes deletes', () async {
    for (var offset = 0; offset < updates; offset += batchSize) {
      final count = (offset + batchSize > updates)
          ? updates - offset
          : batchSize;
      await engine.putMany(<({Uint8List key, Bytes document})>[
        for (var i = offset; i < offset + count; i++)
          (key: keyOf(nextSeed() % totalDocs), document: doc),
      ]);
    }
    for (var offset = 0; offset < deletes; offset += batchSize) {
      final count = (offset + batchSize > deletes)
          ? deletes - offset
          : batchSize;
      await engine.deleteMany(<Uint8List>[
        for (var i = offset; i < offset + count; i++)
          keyOf(nextSeed() % totalDocs),
      ]);
    }
    await engine.flush();
  });

  await phase('compact', engine.compact);

  await phase('$reads random reads', () async {
    var hits = 0;
    for (var i = 0; i < reads; i++) {
      if (await engine.get(keyOf(nextSeed() % totalDocs)) != null) hits++;
    }
    stdoutLine('  hits=$hits');
  });

  await phase('close', engine.close);

  // Cold start: a fresh engine over the same objects.
  final reopened = ObjectStoreEngine(store: store);
  await phase('reopen', reopened.open);

  stdoutLine('');
  stdoutLine('phase                          wall    requests   '
      '(get/put/del/list)      out        in');
  for (final entry in phases.entries) {
    final stats = entry.value;
    stdoutLine(
      '${entry.key.padRight(28)} '
      '${wall[entry.key]!.toString().padLeft(6)}ms '
      '${stats.requests.toString().padLeft(10)} '
      '(${stats.gets}/${stats.puts}/${stats.deletes}/${stats.lists})'
      '${_mb(stats.requestBytes).padLeft(11)}'
      '${_mb(stats.responseBytes).padLeft(11)}',
    );
  }

  final total = store.stats;
  stdoutLine('');
  stdoutLine('objects=${store.objectCount} '
      'stored=${_mb(store.storedBytes)} '
      'totalRequests=${total.requests} '
      'out=${_mb(total.requestBytes)} in=${_mb(total.responseBytes)}');
  stdoutLine('payload=${_mb(totalDocs * document.length)} '
      'requestAmplification='
      '${(total.requestBytes / (totalDocs * document.length)).toStringAsFixed(2)}x');
  await reopened.close(flush: false);
}

void stdoutLine(String line) => print(line);
