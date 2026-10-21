/// Small statistics helpers shared by the scenarios.
///
/// The micro suites do not need them: `benchmark_test` already reports a
/// relative margin of error per benchmark, which `tool/normalize.dart` carries
/// into the cards instead of recomputing.
library;

/// Median of [values]; `0` for an empty list.
double median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = <double>[...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

/// Half the range as a percentage of the median.
///
/// This is the error estimate the comparison cards print: with three samples a
/// standard deviation is meaningless, while the semi-range is at least an
/// honest bound on the observed spread.
double semiRangePct(List<double> values) {
  if (values.length < 2) return 0;
  final med = median(values);
  if (med <= 0) return 0;
  final sorted = <double>[...values]..sort();
  return (sorted.last - sorted.first) / 2 / med * 100;
}

/// Nearest-rank percentile, `p` in `[0, 1]`, on an unsorted list.
double percentile(List<double> values, double p) {
  if (values.isEmpty) return 0;
  final sorted = <double>[...values]..sort();
  final rank = (p * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
  return sorted[rank];
}

/// Rate of `count` operations in [microseconds], in ops per second.
double perSecond(int count, int microseconds) {
  if (microseconds <= 0) return 0;
  return count * 1000000 / microseconds;
}
