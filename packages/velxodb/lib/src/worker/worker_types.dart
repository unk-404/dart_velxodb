import 'dart:typed_data';

/// One key/value pair returned by [VelxoWorker.page].
typedef WorkerEntry = ({Uint8List key, Uint8List value});

/// One page of results plus the key to resume after.
typedef WorkerPage = ({List<WorkerEntry> entries, Uint8List? next});

/// Result of [VelxoWorker.check].
final class WorkerCheck {
  /// Creates a check result.
  const WorkerCheck({
    required this.ok,
    required this.issues,
    required this.stats,
  });

  /// Whether no error-severity issue was found.
  final bool ok;

  /// Findings, already formatted.
  final List<String> issues;

  /// Counts gathered while checking.
  final Map<String, int> stats;

  @override
  String toString() =>
      'WorkerCheck(ok: $ok, issues: ${issues.length}, stats: $stats)';
}
