// Open time, resident memory and on-disk size on the real filesystem.
//
//   dart run scenarios/open_rss_bench.dart [--quick|--large]
//
// The numbers README claims for "1e6 documents open in N ms with M MB of RSS"
// were never backed by a benchmark; this is that benchmark. Scales:
//   --quick  ->  10k documents
//   (default)-> 100k documents
//   --large  ->   1M documents   (nightly only: writes ~130 MB)
//
// Caveats that are printed with the result:
//   * RSS is sampled around `openSync` in the same process, so the numbers
//     include allocator slack; a cold process would report less.
//   * the OS page cache is warm after the import; this is not a cold-start test.
import 'dart:io';
import 'dart:typed_data';

import 'package:velxodb/velxodb.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/report.dart';
import 'package:velxodb_benchmarks/stats.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Marks a row as lower-is-better.
const String kLower = 'lower';

/// Reads sampled for the latency percentiles.
const int kLatencyReads = 2000;

/// Warm-up reads before the sampled ones.
const int kWarmupReads = 1000;

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final large = args.contains('--large');
  final scale = quick
      ? kOpenDocsSmall
      : large
      ? kOpenDocsHuge
      : kOpenDocsLarge;

  final doc = sampleDocument();
  final readKeys = <Uint8List>[
    for (var i = 0; i < kLatencyReads; i++) _keyOf(i),
  ];

  late int importMs;
  late int diskBytes;
  late int reopenMs;
  late int rssDeltaBytes;
  late List<double> readMicros;

  await withTempDir('open_rss', (Directory dir) async {
    var db = VelxoDatabase.openSync(dir.path);
    var collection = db.collection('docs');

    final importWatch = Stopwatch()..start();
    for (var offset = 0; offset < scale; offset += kImportBatch) {
      final end = offset + kImportBatch > scale ? scale : offset + kImportBatch;
      collection.putManySync(<ScanEntry>[
        for (var i = offset; i < end; i++) (key: _keyOf(i), value: doc),
      ]);
    }
    importWatch.stop();
    importMs = importWatch.elapsedMilliseconds;

    db.flushSync();
    await db.close(flush: true);
    diskBytes = directoryBytes(dir);

    // Reopen: the measurement is the open call alone, no reads inside it.
    final rssBefore = ProcessInfo.currentRss;
    final openWatch = Stopwatch()..start();
    db = VelxoDatabase.openSync(dir.path);
    openWatch.stop();
    reopenMs = openWatch.elapsedMilliseconds;
    rssDeltaBytes = ProcessInfo.currentRss - rssBefore;

    collection = db.collection('docs');
    for (var i = 0; i < kWarmupReads; i++) {
      collection.get(readKeys[i]);
    }
    readMicros = <double>[];
    for (final key in readKeys) {
      final watch = Stopwatch()..start();
      collection.get(key);
      watch.stop();
      readMicros.add(watch.elapsedMicroseconds.toDouble());
    }
    await db.close(flush: false);

    stdout.writeln('scale=$scale docs, payload=${mb(scale * doc.length)}');
    stdout.writeln(
      'import ${importMs}ms, '
      'reopen ${reopenMs}ms, rss delta ${mb(rssDeltaBytes)}, '
      'disk ${mb(diskBytes)}',
    );
    stdout.writeln(
      'reads p50=${percentile(readMicros, 0.5).toStringAsFixed(2)}us '
      'p95=${percentile(readMicros, 0.95).toStringAsFixed(2)}us',
    );
  });

  final docsPerSecond = importMs > 0 ? scale * 1000 / importMs : 0.0;
  final payloadBytes = scale * doc.length;

  final report = BenchReport(tool: 'velxo-open');
  void add({
    required String id,
    required String label,
    required String unit,
    required num value,
    String direction = 'higher',
    required String note,
  }) {
    report.add(
      BenchmarkResult(
        id: id,
        group: 'Real filesystem',
        label: label,
        unit: unit,
        value: value.toDouble(),
        direction: direction,
        note: note,
      ),
    );
  }

  add(
    id: 'open.import.docs_per_s',
    label: 'Import $scale docs',
    unit: 'docs/s',
    value: docsPerSecond,
    note: 'batches of $kImportBatch on a real directory',
  );
  add(
    id: 'open.reopen.ms',
    label: 'Reopen $scale docs',
    unit: 'ms',
    value: reopenMs,
    direction: kLower,
    note: 'openSync only, warm page cache',
  );
  add(
    id: 'open.rss_mb',
    label: 'RSS increase on reopen',
    unit: 'MB',
    value: rssDeltaBytes / 1e6,
    direction: kLower,
    note: 'same process, allocator slack included',
  );
  add(
    id: 'open.disk_mb',
    label: 'On-disk size',
    unit: 'MB',
    value: diskBytes / 1e6,
    direction: kLower,
    note: 'payload is ${(payloadBytes / 1e6).toStringAsFixed(1)} MB',
  );
  add(
    id: 'open.read_p50_us',
    label: 'Point read p50',
    unit: 'us',
    value: percentile(readMicros, 0.5),
    direction: kLower,
    note: '$kLatencyReads reads after reopen',
  );
  add(
    id: 'open.read_p95_us',
    label: 'Point read p95',
    unit: 'us',
    value: percentile(readMicros, 0.95),
    direction: kLower,
    note: '$kLatencyReads reads after reopen',
  );

  report.write('results/open_rss.json');
  stdout.writeln('wrote results/open_rss.json (${report.rows.length} rows)');

  // Deterministic bounds: a format regression shows up here even on a slow CI
  // runner, because these are ratios, not times.
  final failures = <String>[];
  final diskRatio = diskBytes / payloadBytes;
  final rssRatio = rssDeltaBytes / payloadBytes;
  if (diskRatio > 1.5) {
    failures.add(
      'on-disk size is ${diskRatio.toStringAsFixed(2)}x the payload, '
      'expected <= 1.5x',
    );
  }
  if (rssRatio > 4.0) {
    failures.add(
      'open RSS increase is ${rssRatio.toStringAsFixed(2)}x the '
      'payload, expected <= 4x',
    );
  }
  if (failures.isNotEmpty) {
    for (final failure in failures) {
      stderr.writeln('FAIL: $failure');
    }
    exitCode = 1;
  }
}

Uint8List _keyOf(int index) =>
    Uint8List.fromList('key-${index.toString().padLeft(9, '0')}'.codeUnits);
