/// Severity of one check finding.
enum CheckSeverity {
  /// Suspicious but not necessarily broken (orphan file, size mismatch).
  warning,

  /// The database would lose or serve wrong data.
  error,
}

/// One finding from [CheckReport].
final class CheckIssue {
  /// Creates an issue.
  const CheckIssue(this.severity, this.code, this.message);

  /// How bad it is.
  final CheckSeverity severity;

  /// Stable machine-readable code, for example `orphan-segment`.
  final String code;

  /// Human-readable detail.
  final String message;

  @override
  String toString() => '${severity.name}: $code: $message';
}

/// Result of an integrity check.
final class CheckReport {
  /// Creates a report.
  CheckReport(List<CheckIssue> issues, Map<String, int> stats)
    : issues = List<CheckIssue>.unmodifiable(issues),
      stats = Map<String, int>.unmodifiable(stats);

  /// Findings, in discovery order.
  final List<CheckIssue> issues;

  /// Counts gathered while checking.
  final Map<String, int> stats;

  /// Whether no error-severity issue was found.
  bool get ok => !issues.any((issue) => issue.severity == CheckSeverity.error);

  /// Number of error findings.
  int get errorCount =>
      issues.where((issue) => issue.severity == CheckSeverity.error).length;

  /// Number of warnings.
  int get warningCount =>
      issues.where((issue) => issue.severity == CheckSeverity.warning).length;

  /// Short summary for logs.
  String describe() {
    final buffer = StringBuffer(ok ? 'ok' : 'FAILED');
    buffer.write(' errors=$errorCount warnings=$warningCount');
    for (final entry in stats.entries) {
      buffer.write(' ${entry.key}=${entry.value}');
    }
    return buffer.toString();
  }
}
