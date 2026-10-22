// Object-store benchmark with request/byte accounting.
//
//   dart run scenarios/object_store_bench.dart [--quick]
//
// No network: SimulatedObjectStore counts every request and byte, so the numbers
// describe the engine's request *shape* and the local CPU cost. The engine is
// backend-agnostic; any store implementing get/put/delete/list can host the same
// segments.
//
// The phase table goes to stdout; the same numbers are written to
// `results/objectstore.json` so a card can render them and so a deterministic
// CI gate can assert the request shape (request counts do not depend on machine
// speed, throughput does).
import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/report.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// S3 caps one LIST response at 1000 keys.
const int kListPageSize = 1000;

/// Marks a row as lower-is-better.
const String kLower = 'lower';

/// Wraps a store and charges one LIST request per 1000 returned keys.
///
/// This is the only S3 billing detail the raw [ObjectStore] interface hides: a
/// real LIST is paginated, so a store with 5k WAL objects costs 5 LIST
/// requests, not one.
final class PagingObjectStore implements ObjectStore {
  /// Creates the decorator around [inner].
  PagingObjectStore(this.inner);

  /// The wrapped store.
  final ObjectStore inner;

  /// LIST requests implied by pagination, beyond what [inner] counted.
  int extraListRequests = 0;

  @override
  Future<Uint8List?> get(String key) => inner.get(key);

  @override
  Future<void> put(String key, Uint8List bytes) => inner.put(key, bytes);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<void> deleteMany(List<String> keys) => inner.deleteMany(keys);

  @override
  Future<List<String>> list(String prefix) async {
    final keys = await inner.list(prefix);
    final pages = (keys.length + kListPageSize - 1) ~/ kListPageSize;
    if (pages > 1) extraListRequests += pages - 1;
    return keys;
  }
}

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final divisor = quick ? 10 : 1;
  final totalDocs = kObjectStoreDocs ~/ divisor;
  final updates = 40000 ~/ divisor;
  final deletes = 20000 ~/ divisor;
  final reads = kScenarioReads ~/ divisor;
  final flushEvery = 50000 ~/ divisor;

  final inner = SimulatedObjectStore();
  final store = PagingObjectStore(inner);
  final engine = ObjectStoreEngine(store: store);
  final doc = sampleDocument();
  final bytes = doc.asUint8List();
  final phases = <String, ObjectStoreStats>{};
  final wall = <String, int>{};
  final rng = Rng();

  Future<void> phase(String name, Future<void> Function() body) async {
    final before = inner.stats;
    final stopwatch = Stopwatch()..start();
    await body();
    stopwatch.stop();
    phases[name] = inner.stats - before;
    wall[name] = stopwatch.elapsedMilliseconds;
  }

  Uint8List keyOfDoc(int index) =>
      Uint8List.fromList('doc-${index.toString().padLeft(9, '0')}'.codeUnits);

  await phase('open (empty)', engine.open);

  await phase('import $totalDocs docs', () async {
    for (var offset = 0; offset < totalDocs; offset += kImportBatch) {
      final count = (offset + kImportBatch > totalDocs)
          ? totalDocs - offset
          : kImportBatch;
      await engine.putMany(<({Uint8List key, Bytes document})>[
        for (var i = offset; i < offset + count; i++)
          (key: keyOfDoc(i), document: doc),
      ]);
      if ((offset + count) % flushEvery == 0) {
        await engine.flush();
      }
    }
  });

  await phase('churn $updates updates + $deletes deletes', () async {
    for (var offset = 0; offset < updates; offset += kImportBatch) {
      final count = (offset + kImportBatch > updates)
          ? updates - offset
          : kImportBatch;
      await engine.putMany(<({Uint8List key, Bytes document})>[
        for (var i = offset; i < offset + count; i++)
          (key: keyOfDoc(rng.nextIndex(totalDocs)), document: doc),
      ]);
    }
    for (var offset = 0; offset < deletes; offset += kImportBatch) {
      final count = (offset + kImportBatch > deletes)
          ? deletes - offset
          : kImportBatch;
      await engine.deleteMany(<Uint8List>[
        for (var i = offset; i < offset + count; i++)
          keyOfDoc(rng.nextIndex(totalDocs)),
      ]);
    }
    await engine.flush();
  });

  await phase('compact', engine.compact);

  await phase('$reads random reads', () async {
    var hits = 0;
    for (var i = 0; i < reads; i++) {
      if (await engine.get(keyOfDoc(rng.nextIndex(totalDocs))) != null) hits++;
    }
    stdout.writeln('  hits=$hits');
  });

  await phase('close', engine.close);

  // Cold start: a fresh engine over the same objects.
  final reopened = ObjectStoreEngine(store: store);
  await phase('reopen', reopened.open);

  final payloadBytes = totalDocs * bytes.length;
  final total = inner.stats;

  stdout.writeln('');
  stdout.writeln(
    'phase                          wall    requests   '
    '(get/put/del/list)      out        in',
  );
  for (final entry in phases.entries) {
    final stats = entry.value;
    stdout.writeln(
      '${entry.key.padRight(28)} '
      '${wall[entry.key]!.toString().padLeft(6)}ms '
      '${stats.requests.toString().padLeft(10)} '
      '(${stats.gets}/${stats.puts}/${stats.deletes}/${stats.lists})'
      '${mb(stats.requestBytes).padLeft(11)}'
      '${mb(stats.responseBytes).padLeft(11)}',
    );
  }
  stdout.writeln('');
  stdout.writeln(
    'objects=${inner.objectCount} '
    'stored=${mb(inner.storedBytes)} '
    'totalRequests=${total.requests} '
    'out=${mb(total.requestBytes)} in=${mb(total.responseBytes)}',
  );
  stdout.writeln(
    'payload=${mb(payloadBytes)} '
    'requestAmplification='
    '${(total.requestBytes / payloadBytes).toStringAsFixed(2)}x',
  );
  stdout.writeln(
    'S3 note: LIST is paginated at $kListPageSize keys; '
    '+${store.extraListRequests} implied page requests',
  );

  // ---------------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------------
  final importKey = 'import $totalDocs docs';
  final importPhase = phases[importKey]!;
  final importWall = wall[importKey]!;
  final docsPerSecond = importWall > 0
      ? totalDocs * 1000 / importWall
      : totalDocs * 1000.0;

  final report = BenchReport(tool: 'velxo-objectstore');
  void add({
    required String id,
    required String label,
    required String unit,
    required num value,
    String direction = 'higher',
    String note = 'simulated store, no network',
  }) {
    report.add(
      BenchmarkResult(
        id: id,
        group: 'Object store requests',
        label: label,
        unit: unit,
        value: value.toDouble(),
        direction: direction,
        note: note,
      ),
    );
  }

  add(
    id: 'objectstore.open.requests',
    label: 'Open requests',
    unit: 'requests',
    value: phases['open (empty)']!.requests,
    direction: kLower,
    note: '1 GET manifest + 1 LIST',
  );
  add(
    id: 'objectstore.import.requests',
    label: 'Import requests',
    unit: 'requests',
    value: importPhase.requests,
    direction: kLower,
    note: '$totalDocs docs in batches of $kImportBatch',
  );
  add(
    id: 'objectstore.import.docs_per_s',
    label: 'Import throughput',
    unit: 'docs/s',
    value: docsPerSecond,
    note: 'local CPU only, no network latency',
  );
  add(
    id: 'objectstore.import.bytes_out',
    label: 'Import bytes out',
    unit: 'MB',
    value: importPhase.requestBytes / 1e6,
    direction: kLower,
  );
  add(
    id: 'objectstore.churn.requests',
    label: 'Churn requests',
    unit: 'requests',
    value: phases['churn $updates updates + $deletes deletes']!.requests,
    direction: kLower,
    note: '$updates updates + $deletes deletes',
  );
  add(
    id: 'objectstore.compact.requests',
    label: 'Compaction requests',
    unit: 'requests',
    value: phases['compact']!.requests,
    direction: kLower,
  );
  add(
    id: 'objectstore.reopen.requests',
    label: 'Reopen requests',
    unit: 'requests',
    value: phases['reopen']!.requests,
    direction: kLower,
    note: 'no segment download',
  );
  add(
    id: 'objectstore.reads.requests',
    label: '$reads random reads requests',
    unit: 'requests',
    value: phases['$reads random reads']!.requests,
    direction: kLower,
    note: 'one segment GET, then the LRU cache',
  );
  add(
    id: 'objectstore.request_amplification',
    label: 'Request amplification',
    unit: 'x',
    value: total.requestBytes / payloadBytes,
    direction: kLower,
    note: 'bytes out / payload bytes',
  );
  add(
    id: 'objectstore.stored',
    label: 'Stored bytes',
    unit: 'MB',
    value: inner.storedBytes / 1e6,
    direction: kLower,
    note: 'payload is ${(payloadBytes / 1e6).toStringAsFixed(1)} MB',
  );

  report.write('results/objectstore.json');
  stdout.writeln('wrote results/objectstore.json (${report.rows.length} rows)');

  await reopened.close(flush: false);

  // Deterministic properties: these must hold on any machine, so a regression
  // in the request shape fails the run instead of quietly moving a bar.
  final failures = <String>[];
  final openRequests = phases['open (empty)']!.requests;
  final reopenRequests = phases['reopen']!.requests;
  final flushes = totalDocs ~/ flushEvery;
  final expectedImportPuts = totalDocs ~/ kImportBatch + 2 * flushes;
  final expectedImportDeletes = flushes;
  final expectedChurnPuts =
      updates ~/ kImportBatch + deletes ~/ kImportBatch + 2;
  const expectedChurnDeletes = 1;
  final importCheck = phases['import $totalDocs docs']!;
  final churnCheck = phases['churn $updates updates + $deletes deletes']!;
  if (openRequests != 2) {
    failures.add(
      'open issued $openRequests requests, expected 2 '
      '(1 GET manifest + 1 LIST)',
    );
  }
  if (reopenRequests != 2) {
    failures.add(
      'reopen issued $reopenRequests requests, expected 2 '
      '(1 GET manifest + 1 LIST)',
    );
  }
  if (importCheck.puts != expectedImportPuts ||
      importCheck.deletes != expectedImportDeletes) {
    failures.add(
      'import issued ${importCheck.puts} PUT / '
      '${importCheck.deletes} DELETE, expected $expectedImportPuts / '
      '$expectedImportDeletes (one WAL object per batch, segment + manifest per '
      'flush)',
    );
  }
  if (churnCheck.puts != expectedChurnPuts ||
      churnCheck.deletes != expectedChurnDeletes) {
    failures.add(
      'churn issued ${churnCheck.puts} PUT / '
      '${churnCheck.deletes} DELETE, expected $expectedChurnPuts / '
      '$expectedChurnDeletes',
    );
  }
  final storedRatio = inner.storedBytes / payloadBytes;
  if (storedRatio > 1.5) {
    failures.add(
      'stored bytes are ${storedRatio.toStringAsFixed(2)}x the '
      'payload, expected <= 1.5x',
    );
  }
  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('FAIL: $failure');
    }
    exitCode = 1;
  }
}
