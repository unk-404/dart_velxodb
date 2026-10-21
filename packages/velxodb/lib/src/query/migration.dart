import 'dart:typed_data';

import '../serde/builder.dart';
import '../serde/view.dart';
import 'collection.dart';

/// Turns one schema version into the next.
final class MigrationStep {
  /// Creates a step.
  const MigrationStep({
    required this.from,
    required this.to,
    required this.apply,
  });

  /// Version this step accepts.
  final int from;

  /// Version it produces. Must be greater than [from].
  final int to;

  /// Writes the upgraded document into the builder.
  ///
  /// The builder already carries the source schema id and the target version.
  /// Use [copyFields] to carry fields over; write changed or new fields after
  /// it, in ascending id order (the format requires ascending ids).
  final void Function(DocView old, DocBuilder out) apply;
}

/// Outcome of one migration run or page.
final class MigrationReport {
  /// Creates a report.
  const MigrationReport({
    required this.scanned,
    required this.migrated,
    required this.skipped,
    this.next,
  });

  /// Documents visited.
  final int scanned;

  /// Documents rewritten.
  final int migrated;

  /// Documents already at or above the target version.
  final int skipped;

  /// Key to resume after, or `null` when the collection is exhausted.
  final Uint8List? next;

  /// Whether more work remains.
  bool get hasMore => next != null;
}

/// Copies fields of [old] into [out], in stored (ascending id) order.
///
/// [skip] drops ids entirely; [fromId] and [toId] restrict the copy to
/// `fromId <= id < toId`. A step that inserts a field in the middle of the id
/// range can copy below it, write it, then copy above it, keeping the ascending
/// order the format requires.
void copyFields(
  DocView old,
  DocBuilder out, {
  Set<int> skip = const <int>{},
  int? fromId,
  int? toId,
}) {
  old.forEachField((cursor) {
    final id = cursor.fieldId;
    if (skip.contains(id)) return;
    if (fromId != null && id < fromId) return;
    if (toId != null && id >= toId) return;
    out.putRawEntry(
      id,
      cursor.wireType,
      cursor.bytes,
      cursor.valueRawOffset,
      cursor.valueRawEnd,
    );
  });
}

/// Version-aware migration on top of a [Collection].
extension CollectionMigration on Collection {
  /// Migrates one page of documents below [toVersion].
  ///
  /// [steps] must form a path: for every version below [toVersion] some step
  /// accepts it. Documents at or above [toVersion] are skipped, so running the
  /// same migration twice is a no-op. [after] is the token from the previous
  /// page.
  MigrationReport migratePageSync({
    required int toVersion,
    required List<MigrationStep> steps,
    int limit = 1000,
    Uint8List? after,
  }) {
    if (toVersion < 0 || toVersion > 255) {
      throw ArgumentError.value(toVersion, 'toVersion', 'must be in 0..255');
    }
    final chain = <int, MigrationStep>{};
    for (final step in steps) {
      if (step.to <= step.from) {
        throw ArgumentError(
          'migration step ${step.from}->${step.to} '
          'must increase the version',
        );
      }
      if (step.from < toVersion && step.to > toVersion) {
        throw ArgumentError(
          'migration step ${step.from}->${step.to} overshoots target '
          'version $toVersion',
        );
      }
      final existing = chain[step.from];
      if (existing != null && existing.to != step.to) {
        throw ArgumentError('conflicting steps from version ${step.from}');
      }
      chain[step.from] = step;
    }

    final cursor = this.cursor(start: after, includeStart: after == null);
    var scanned = 0;
    var migrated = 0;
    var skipped = 0;
    Uint8List? pending = after;
    while (scanned < limit && cursor.moveNext()) {
      final entry = cursor.current;
      scanned++;
      pending = entry.key;
      var view = DocView.parse(entry.value.asUint8List());
      if (view.schemaVersion >= toVersion) {
        skipped++;
        continue;
      }
      while (view.schemaVersion < toVersion) {
        final step = chain[view.schemaVersion];
        if (step == null) {
          throw StateError(
            'no migration step from version ${view.schemaVersion}; '
            'target is $toVersion',
          );
        }
        final builder = DocBuilder(
          schemaId: view.schemaId,
          schemaVersion: step.to,
        );
        step.apply(view, builder);
        builder.schemaVersion = step.to;
        final bytes = builder.finish();
        view = DocView.parse(bytes.asUint8List());
      }
      putSync(entry.key, view.toBytes());
      migrated++;
    }

    return MigrationReport(
      scanned: scanned,
      migrated: migrated,
      skipped: skipped,
      next: scanned == limit ? pending : null,
    );
  }

  /// Runs [migratePageSync] until the collection is exhausted.
  MigrationReport migrateSync({
    required int toVersion,
    required List<MigrationStep> steps,
    int pageSize = 1000,
    void Function(MigrationReport page)? onPage,
  }) {
    var scanned = 0;
    var migrated = 0;
    var skipped = 0;
    Uint8List? after;
    while (true) {
      final page = migratePageSync(
        toVersion: toVersion,
        steps: steps,
        limit: pageSize,
        after: after,
      );
      scanned += page.scanned;
      migrated += page.migrated;
      skipped += page.skipped;
      onPage?.call(page);
      if (!page.hasMore) break;
      after = page.next;
    }
    return MigrationReport(
      scanned: scanned,
      migrated: migrated,
      skipped: skipped,
    );
  }
}
