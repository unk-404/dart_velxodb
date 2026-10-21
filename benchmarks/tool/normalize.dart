// Turns raw results into the per-card `benchcat/report@1` files the cards read.
//
//   dart run tool/normalize.dart [--strict] [--results=results]
//
// Inputs (missing ones are skipped with a warning):
//   results/main.jsonl        benchmark_test JSONL from the micro suites
//   results/open_rss.json     scenarios/open_rss_bench.dart
//   results/durability.json   scenarios/durability_bench.dart
//   results/objectstore.json  scenarios/object_store_bench.dart
//
// Outputs: results/<card>.json for every card in `lib/manifest.dart`.
//
// This is the single place where a measurement becomes a charted number, so the
// unit and the workload factor live in exactly one table (`lib/manifest.dart`)
// instead of being re-encoded in every card row.
import 'dart:convert';
import 'dart:io';

import 'package:velxodb_benchmarks/manifest.dart';
import 'package:velxodb_benchmarks/report.dart';

/// One measurement from `benchmark_test`.
final class _Sample {
  /// Creates a sample.
  const _Sample({
    required this.iterationsPerSecond,
    required this.errorPct,
    required this.samples,
  });

  /// Iterations per second of the whole benchmark closure.
  final double iterationsPerSecond;

  /// `benchmark_test`'s relative margin of error, in percent.
  final double errorPct;

  /// Number of samples behind the rate.
  final int samples;
}

Future<void> main(List<String> args) async {
  final strict = args.contains('--strict');
  var resultsDir = 'results';
  for (final arg in args) {
    if (arg.startsWith('--results=')) {
      resultsDir = arg.substring('--results='.length);
    }
  }

  final mainJsonl = File('$resultsDir/main.jsonl');
  if (!mainJsonl.existsSync()) {
    stderr.writeln(
      'error: ${mainJsonl.path} not found.\n'
      'Run: dart run benchmark_test --output jsonl suites '
      '> $resultsDir/main.jsonl',
    );
    exitCode = 2;
    return;
  }

  final samples = _readJsonl(mainJsonl);
  final extras = <String, BenchmarkResult>{
    ..._readReport('$resultsDir/open_rss.json'),
    ..._readReport('$resultsDir/durability.json'),
    ..._readReport('$resultsDir/objectstore.json'),
  };

  // A measurement that no card can show is a silent loss; report it.
  final known = <String>{for (final row in kRows) row.id, ...extras.keys};
  var problems = 0;
  for (final id in samples.keys) {
    if (!known.contains(id)) {
      stderr.writeln('warning: measured but not in the manifest: $id');
      problems++;
    }
  }

  var written = 0;
  for (final entry in kCards.entries) {
    final report = BenchReport(tool: 'velxo-bench');
    var missing = 0;
    for (final id in entry.value) {
      final row = rowById(id);
      if (row != null) {
        final sample = samples[id];
        if (sample == null) {
          stderr.writeln('warning: ${entry.key}: no measurement for $id');
          missing++;
          continue;
        }
        final value = row.valueFor(sample.iterationsPerSecond);
        report.add(
          BenchmarkResult(
            id: row.id,
            group: row.group,
            label: row.label,
            unit: row.unit,
            value: value,
            note: _noteWithStats(row.note, sample),
            direction: row.direction,
            samples: sample.samples,
            errorPct: sample.errorPct,
          ),
        );
        continue;
      }
      final extra = extras[id];
      if (extra != null) {
        report.add(extra);
        continue;
      }
      stderr.writeln('warning: ${entry.key}: unknown row $id');
      missing++;
    }
    if (missing > 0) problems += missing;
    final target = File('$resultsDir/${entry.key}.json');
    report.write(target.path);
    written++;
    stdout.writeln(
      '${entry.key}: ${report.rows.length} rows -> ${target.path}',
    );
  }

  if (problems > 0 && strict) {
    stderr.writeln('error: $problems row(s) could not be charted (--strict)');
    exitCode = 1;
    return;
  }
  stdout.writeln('wrote $written card report(s)');
}

/// Replaces the trailing note with one that carries the spread.
String _noteWithStats(String note, _Sample sample) {
  final spread =
      '±${sample.errorPct.toStringAsFixed(2)}% '
      '(${sample.samples} samples)';
  return note.isEmpty ? spread : '$note · $spread';
}

Map<String, _Sample> _readJsonl(File file) {
  final out = <String, _Sample>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) continue;
    final name = decoded['name'];
    final throughput = decoded['throughput'];
    if (name is! String || throughput is! Map<String, Object?>) continue;
    final value = throughput['value'];
    if (value is! num) continue;
    final statistics = decoded['statistics'];
    var errorPct = 0.0;
    var count = 1;
    if (statistics is Map<String, Object?>) {
      final rme = statistics['relativeMarginOfError'];
      if (rme is num) errorPct = rme.toDouble();
      final n = statistics['samples'];
      if (n is num) count = n.toInt();
    }
    out[name] = _Sample(
      iterationsPerSecond: value.toDouble(),
      errorPct: errorPct,
      samples: count,
    );
  }
  return out;
}

Map<String, BenchmarkResult> _readReport(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('note: $path not found, rows from it are skipped');
    return <String, BenchmarkResult>{};
  }
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) return <String, BenchmarkResult>{};
  final benchmarks = decoded['benchmarks'];
  if (benchmarks is! List<Object?>) return <String, BenchmarkResult>{};
  final out = <String, BenchmarkResult>{};
  for (final item in benchmarks) {
    if (item is! Map<String, Object?>) continue;
    final id = item['id'];
    final value = item['value'];
    final unit = item['unit'];
    final label = item['label'];
    if (id is! String || value is! num || unit is! String || label is! String) {
      continue;
    }
    final stats = item['stats'];
    var samples = 1;
    var errorPct = 0.0;
    if (stats is Map<String, Object?>) {
      final n = stats['samples'];
      if (n is num) samples = n.toInt();
      final rme = stats['rme_pct'];
      if (rme is num) errorPct = rme.toDouble();
    }
    final group = item['group'];
    final note = item['note'];
    final direction = item['direction'];
    out[id] = BenchmarkResult(
      id: id,
      group: group is String ? group : 'Other',
      label: label,
      unit: unit,
      value: value.toDouble(),
      direction: direction is String ? direction : 'higher',
      note: note is String ? note : '',
      samples: samples,
      errorPct: errorPct,
    );
  }
  return out;
}
