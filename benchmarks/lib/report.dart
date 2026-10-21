/// `benchcat/report@1` writer shared by every scenario.
///
/// One format for every produced number means a card never needs a formula: it
/// renders the value that is already in the JSON, in the unit the row declares.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// One measured row.
final class BenchmarkResult {
  /// Creates a row.
  const BenchmarkResult({
    required this.id,
    required this.group,
    required this.label,
    required this.unit,
    required this.value,
    this.note = '',
    this.direction = 'higher',
    this.samples = 1,
    this.errorPct = 0,
  });

  /// Stable id, `"<area>.<name>"`; a card row references it.
  final String id;

  /// Display group, e.g. `Storage`.
  final String group;

  /// Human label.
  final String label;

  /// Measurement unit, e.g. `Mops/s`.
  final String unit;

  /// Measured value in [unit].
  final double value;

  /// Provenance line (sample count, spread, environment).
  final String note;

  /// `higher` or `lower`; which direction is better.
  final String direction;

  /// Number of samples behind [value].
  final int samples;

  /// Relative error estimate in percent (semi-range for 3 samples).
  final double errorPct;

  /// Encodes the row for a benchcat report.
  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'group': group,
    'label': label,
    'note': note,
    'unit': unit,
    'value': value,
    'direction': direction,
    'stats': <String, Object>{'samples': samples, 'rme_pct': errorPct},
  };
}

/// A collection of rows plus provenance, written as `benchcat/report@1`.
final class BenchReport {
  /// Creates a report for [tool].
  BenchReport({required this.tool, this.toolVersion = '1'});

  /// Producer name shown in the card provenance.
  final String tool;

  /// Producer version.
  final String toolVersion;

  final List<BenchmarkResult> _rows = <BenchmarkResult>[];

  /// Rows added so far.
  List<BenchmarkResult> get rows => List<BenchmarkResult>.unmodifiable(_rows);

  /// Adds a row.
  void add(BenchmarkResult row) => _rows.add(row);

  /// Encodes the whole report.
  Map<String, Object> toJson() => <String, Object>{
    'schema': 'benchcat/report@1',
    'meta': <String, Object>{
      'tool': tool,
      'tool_version': toolVersion,
      'platform': <String, Object>{'os': platformOs(), 'arch': platformArch()},
      'environment': <String, Object>{
        'dart': Platform.version,
        'processors': Platform.numberOfProcessors,
      },
    },
    'benchmarks': <Object>[for (final row in _rows) row.toJson()],
  };

  /// Writes the report as indented JSON.
  void write(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
    );
  }
}

/// Operating system name, benchcat style (`windows`, `linux`, `macos`).
String platformOs() {
  final os = Platform.operatingSystem;
  return os == 'macos' ? 'macos' : os;
}

/// CPU architecture, benchcat style (`x64`, `arm64`).
String platformArch() {
  final abi = Abi.current().toString();
  if (abi.contains('X64')) return 'x64';
  if (abi.contains('Arm64')) return 'arm64';
  if (abi.contains('Arm')) return 'arm';
  if (abi.contains('Ia32')) return 'ia32';
  if (abi.contains('Riscv64')) return 'riscv64';
  if (abi.contains('Riscv32')) return 'riscv32';
  return abi;
}

/// Formatted megabytes.
String mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)} MB';
