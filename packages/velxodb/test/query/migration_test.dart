@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes v1Doc(String text) =>
    (DocBuilder(schemaId: 1, schemaVersion: 1)
          ..putString(1, text)
          ..putInt(9, 99))
        .finish();

/// v1 -> v2: keep every field, insert field 7 between 6 and 8.
MigrationStep addField7(int value) => MigrationStep(
  from: 1,
  to: 2,
  apply: (old, out) {
    copyFields(old, out, toId: 7);
    out.putInt(7, value);
    copyFields(old, out, fromId: 8);
  },
);

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_migrate_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('migration', () {
    test('rewrites documents and bumps the version', () {
      for (var i = 0; i < 3; i++) {
        collection.putSync(k('k$i'), v1Doc('v$i'));
      }
      final report = collection.migrateSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(42)],
      );
      expect(report.scanned, 3);
      expect(report.migrated, 3);
      expect(report.skipped, 0);

      for (var i = 0; i < 3; i++) {
        final view = DocView.parse(collection.get(k('k$i'))!.asUint8List());
        expect(view.schemaVersion, 2);
        expect(view.getString(1), 'v$i');
        expect(view.getInt(7), 42);
        // Unknown/higher field carried through the copy.
        expect(view.getInt(9), 99);
      }
    });

    test('is idempotent', () {
      collection.putSync(k('a'), v1Doc('a'));
      collection.migrateSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(1)],
      );
      final second = collection.migrateSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(1)],
      );
      expect(second.migrated, 0);
      expect(second.skipped, 1);
      expect(DocView.parse(collection.get(k('a'))!.asUint8List()).getInt(7), 1);
    });

    test('pages with a resume token', () {
      for (var i = 0; i < 5; i++) {
        collection.putSync(k('k$i'), v1Doc('v$i'));
      }
      final first = collection.migratePageSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(7)],
        limit: 2,
      );
      expect(first.scanned, 2);
      expect(first.hasMore, isTrue);
      expect(first.next, isNotNull);

      final second = collection.migratePageSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(7)],
        limit: 10,
        after: first.next,
      );
      expect(second.migrated, 3);
      expect(second.hasMore, isFalse);
    });

    test('skips documents already at the target version', () {
      final current = (DocBuilder(
        schemaId: 1,
        schemaVersion: 2,
      )..putString(1, 'new')).finish();
      collection.putSync(k('new'), current);
      collection.putSync(k('old'), v1Doc('old'));

      final report = collection.migrateSync(
        toVersion: 2,
        steps: <MigrationStep>[addField7(5)],
      );
      expect(report.migrated, 1);
      expect(report.skipped, 1);
      expect(
        DocView.parse(collection.get(k('new'))!.asUint8List()).getInt(7),
        isNull,
      );
    });

    test('rejects a missing step', () {
      collection.putSync(k('a'), v1Doc('a'));
      expect(
        () => collection.migrateSync(
          toVersion: 3,
          steps: <MigrationStep>[addField7(1)],
        ),
        throwsStateError,
      );
    });

    test('rejects a backwards step', () {
      expect(
        () => collection.migrateSync(
          toVersion: 2,
          steps: <MigrationStep>[
            MigrationStep(from: 2, to: 1, apply: (old, out) {}),
          ],
        ),
        throwsArgumentError,
      );
    });
  });
}
