// Post-run sanity gate over the produced card reports.
//
//   dart run tool/gate.dart [--timing=warn|fail|off] [--tolerance=30]
//   dart run tool/gate.dart --update-baseline
//
// It checks the things that must hold on any machine:
//   * every card report exists and has rows,
//   * no row carries a zero/NaN/infinite value (a broken measurement),
//   * no measured row lost its card.
// and the things that are machine dependent:
//   * a timing row may not regress more than `--tolerance` percent against
//     `results/baseline.json` (warn by default; pass `--timing=fail` on a
//     dedicated runner).
//
// The deterministic, physics-level properties (object-store request counts,
// disk/payload ratios) are asserted by the scenarios themselves; this gate does
// not duplicate them.
import 'dart:convert';
import 'dart:io';

import 'package:velxodb_benchmarks/manifest.dart';

/// Card reports to verify, with the file each one lives in.
const List<String> kReports = <String>[
  'hero',
  'format',
  'storage',
  'query',
  'objectstore',
];

Future<void> main(List<String> args) async {
  var timing = 'warn';
  var tolerance = 30.0;
  final updateBaseline = args.contains('--update-baseline');
  for (final arg in args) {
    if (arg.startsWith('--timing=')) timing = arg.substring(9);
    if (arg.startsWith('--tolerance=')) {
      tolerance = double.tryParse(arg.substring(12)) ?? tolerance;
    }
  }

  final failures = <String>[];
  final warnings = <String>[];
  final current = <String, double>{};

  for (final card in kReports) {
    final file = File('results/$card.json');
    if (!file.existsSync()) {
      failures.add('missing $card report (results/$card.json)');
      continue;
    }
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      failures.add('$card report is not a JSON object');
      continue;
    }
    final rows = decoded['benchmarks'];
    if (rows is! List<Object?> || rows.isEmpty) {
      failures.add('$card report has no rows');
      continue;
    }
    for (final row in rows) {
      if (row is! Map<String, Object?>) continue;
      final id = row['id'];
      final value = row['value'];
      if (id is! String || value is! num) {
        failures.add('$card: malformed row $row');
        continue;
      }
      final number = value.toDouble();
      if (!number.isFinite || number <= 0) {
        failures.add('$card: $id has value $number');
        continue;
      }
      current[id] = number;
    }
  }

  // Every measured micro row should be reachable from some card.
  for (final row in kRows) {
    if (!current.containsKey(row.id)) {
      warnings.add('measured but not charted: ${row.id}');
    }
  }

  final baselineFile = File('results/baseline.json');
  final regressions = <String>[];
  if (baselineFile.existsSync()) {
    final Object? decoded = jsonDecode(baselineFile.readAsStringSync());
    if (decoded is Map<String, Object?>) {
      for (final entry in decoded.entries) {
        final base = entry.value;
        final now = current[entry.key];
        if (base is! num || now == null) continue;
        final row = rowById(entry.key);
        final lowerIsBetter = row?.direction == 'lower';
        final changePct = (now - base) / base * 100;
        final worse = lowerIsBetter ? changePct : -changePct;
        if (worse > tolerance) {
          regressions.add(
            '${entry.key}: ${base.toStringAsFixed(2)} -> '
            '${now.toStringAsFixed(2)} (${changePct.toStringAsFixed(1)}%)',
          );
        }
      }
    }
  }

  if (updateBaseline) {
    final out = File('results/baseline.json');
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(current)}\n',
    );
    stdout.writeln('wrote ${out.path} (${current.length} rows)');
  }

  for (final warning in warnings) {
    stdout.writeln('warn: $warning');
  }
  for (final regression in regressions) {
    if (timing == 'fail') {
      failures.add('timing regression: $regression');
    } else if (timing != 'off') {
      stdout.writeln('warn: timing regression: $regression');
    }
  }

  if (failures.isEmpty) {
    stdout.writeln('gate ok (${current.length} rows checked)');
    return;
  }
  for (final failure in failures) {
    stderr.writeln('FAIL: $failure');
  }
  exitCode = 1;
}
