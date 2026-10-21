import 'dart:typed_data';

import '../serde/view.dart';

/// A predicate over a decoded document.
///
/// Predicates are plain closures over `DocView`, so evaluating one never
/// allocates. The planner inspects the tree for an indexable shape and leaves
/// the predicate itself as the residual filter.
sealed class Predicate {
  const Predicate();

  /// Value equality on [fieldId].
  factory Predicate.eq(int fieldId, Object value) =>
      EqPredicate(fieldId, value);

  /// `field < value`.
  factory Predicate.lt(int fieldId, Object value) =>
      RangePredicate(fieldId, to: value, includeTo: false);

  /// `field <= value`.
  factory Predicate.lte(int fieldId, Object value) =>
      RangePredicate(fieldId, to: value, includeTo: true);

  /// `field > value`.
  factory Predicate.gt(int fieldId, Object value) =>
      RangePredicate(fieldId, from: value, includeFrom: false);

  /// `field >= value`.
  factory Predicate.gte(int fieldId, Object value) =>
      RangePredicate(fieldId, from: value, includeFrom: true);

  /// `field` in `[from, to)`.
  factory Predicate.between(
    int fieldId, {
    Object? from,
    Object? to,
    bool includeFrom = true,
    bool includeTo = false,
  }) => RangePredicate(
    fieldId,
    from: from,
    to: to,
    includeFrom: includeFrom,
    includeTo: includeTo,
  );

  /// Conjunction.
  factory Predicate.and(List<Predicate> parts) => AndPredicate(parts);

  /// Disjunction.
  factory Predicate.or(List<Predicate> parts) => OrPredicate(parts);

  /// Negation.
  factory Predicate.not(Predicate inner) => NotPredicate(inner);

  /// Evaluates the predicate for [document].
  bool test(DocView document);
}

/// `field == value`.
final class EqPredicate extends Predicate {
  /// Creates an equality predicate.
  const EqPredicate(this.fieldId, this.value);

  /// Field id.
  final int fieldId;

  /// Expected value.
  final Object value;

  @override
  bool test(DocView document) => readField(document, fieldId, value) == value;
}

/// A one-sided or two-sided range over [fieldId].
final class RangePredicate extends Predicate {
  /// Creates a range predicate.
  const RangePredicate(
    this.fieldId, {
    this.from,
    this.to,
    this.includeFrom = true,
    this.includeTo = false,
  });

  /// Field id.
  final int fieldId;

  /// Inclusive/exclusive lower bound, or `null`.
  final Object? from;

  /// Upper bound, or `null`.
  final Object? to;

  /// Whether [from] is included.
  final bool includeFrom;

  /// Whether [to] is included.
  final bool includeTo;

  @override
  bool test(DocView document) {
    final value = readField(document, fieldId, from ?? to!);
    if (value == null) return false;
    if (from != null) {
      final comparison = compareValues(value, from!);
      if (comparison < 0 || (comparison == 0 && !includeFrom)) return false;
    }
    if (to != null) {
      final comparison = compareValues(value, to!);
      if (comparison > 0 || (comparison == 0 && !includeTo)) return false;
    }
    return true;
  }
}

/// Conjunction of [parts].
final class AndPredicate extends Predicate {
  /// Creates a conjunction.
  const AndPredicate(this.parts);

  /// Child predicates.
  final List<Predicate> parts;

  @override
  bool test(DocView document) {
    for (final part in parts) {
      if (!part.test(document)) return false;
    }
    return true;
  }
}

/// Disjunction of [parts].
final class OrPredicate extends Predicate {
  /// Creates a disjunction.
  const OrPredicate(this.parts);

  /// Child predicates.
  final List<Predicate> parts;

  @override
  bool test(DocView document) {
    for (final part in parts) {
      if (part.test(document)) return true;
    }
    return false;
  }
}

/// Negation.
final class NotPredicate extends Predicate {
  /// Wraps [inner].
  const NotPredicate(this.inner);

  /// Predicate being negated.
  final Predicate inner;

  @override
  bool test(DocView document) => !inner.test(document);
}

/// Reads [fieldId] from [document], using [sample]'s runtime type.
Object? readField(DocView document, int fieldId, Object sample) {
  if (sample is int) return document.getInt(fieldId);
  if (sample is String) return document.getString(fieldId);
  if (sample is bool) return document.getBool(fieldId);
  throw ArgumentError('unsupported predicate value type ${sample.runtimeType}');
}

/// Compares two values of the same supported type.
int compareValues(Object a, Object b) {
  if (a is int && b is int) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
  throw ArgumentError('cannot compare ${a.runtimeType} with ${b.runtimeType}');
}

/// A query: optional predicate, optional key range, and a limit.
final class Query {
  /// Creates a query.
  const Query({
    this.where,
    this.prefix,
    this.start,
    this.end,
    this.includeStart = true,
    this.includeEnd = false,
    this.limit,
  });

  /// Residual predicate, or `null`.
  final Predicate? where;

  /// Key prefix restriction.
  final Uint8List? prefix;

  /// Inclusive user-key lower bound.
  final Uint8List? start;

  /// Exclusive user-key upper bound.
  final Uint8List? end;

  /// Whether [start] is included.
  final bool includeStart;

  /// Whether [end] is included.
  final bool includeEnd;

  /// Maximum number of results.
  final int? limit;
}

/// How a query will be executed.
enum ScanStrategy {
  /// Walk the collection's key order.
  scan,

  /// Look up one indexed value.
  indexEquality,

  /// Walk one indexed value range.
  indexRange,
}

/// The chosen execution plan.
final class QueryPlan {
  QueryPlan._(this.strategy, this.fieldId, this.explanation);

  /// Strategy.
  final ScanStrategy strategy;

  /// Indexed field, when [strategy] is not [ScanStrategy.scan].
  final int? fieldId;

  /// Human-readable summary, used by `explain`.
  final String explanation;

  /// Whether the plan reads an index.
  bool get usesIndex => strategy != ScanStrategy.scan;
}

/// Picks an index for [query] when one exists on the collection.
QueryPlan planQuery(Query query, Iterable<int> indexedFields) {
  final indexed = indexedFields.toSet();
  final hit = query.where == null ? null : _findIndexHit(query.where!, indexed);
  if (hit == null) {
    return QueryPlan._(ScanStrategy.scan, null, 'scan');
  }
  if (hit.isEquality) {
    return QueryPlan._(
      ScanStrategy.indexEquality,
      hit.fieldId,
      'index:eq field=${hit.fieldId}',
    );
  }
  return QueryPlan._(
    ScanStrategy.indexRange,
    hit.fieldId,
    'index:range field=${hit.fieldId}',
  );
}

/// Indexable leaf found inside a predicate tree.
final class IndexHit {
  /// Creates a hit.
  const IndexHit({
    required this.fieldId,
    this.value,
    this.from,
    this.to,
    this.includeFrom = true,
    this.includeTo = false,
  });

  /// Indexed field.
  final int fieldId;

  /// Equality value, when [isEquality].
  final Object? value;

  /// Range lower bound.
  final Object? from;

  /// Range upper bound.
  final Object? to;

  /// Whether [from] is included.
  final bool includeFrom;

  /// Whether [to] is included.
  final bool includeTo;

  /// Whether this is an equality hit.
  bool get isEquality => value != null;
}

IndexHit? _findIndexHit(Predicate predicate, Set<int> indexed) {
  if (predicate is EqPredicate && indexed.contains(predicate.fieldId)) {
    return IndexHit(fieldId: predicate.fieldId, value: predicate.value);
  }
  if (predicate is RangePredicate) {
    if ((predicate.from != null || predicate.to != null) &&
        indexed.contains(predicate.fieldId)) {
      return IndexHit(
        fieldId: predicate.fieldId,
        from: predicate.from,
        to: predicate.to,
        includeFrom: predicate.includeFrom,
        includeTo: predicate.includeTo,
      );
    }
    return null;
  }
  if (predicate is AndPredicate) {
    // Prefer equality over ranges, then the leftmost hit.
    for (final part in predicate.parts) {
      final hit = _findIndexHit(part, indexed);
      if (hit != null && hit.isEquality) return hit;
    }
    for (final part in predicate.parts) {
      final hit = _findIndexHit(part, indexed);
      if (hit != null) return hit;
    }
  }
  return null;
}

/// Exposes the chosen hit so the executor can read it without re-planning.
IndexHit? indexHitFor(Query query, Iterable<int> indexedFields) =>
    query.where == null
    ? null
    : _findIndexHit(query.where!, indexedFields.toSet());
