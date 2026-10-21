@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text, int number) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, number))
        .finish();

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_check_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('check()', () {
    test('a healthy database reports ok with stats', () {
      collection.createIndex(2, VxsType.int64);
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('alpha beta', 1));
      db.flushSync();

      final report = db.checkSync(deep: true);
      expect(report.ok, isTrue, reason: report.describe());
      expect(report.stats['segments'], 1);
      expect(report.stats['collections'], 1);
      expect(report.stats['indexes'], 1);
      expect(report.stats['textIndexes'], 1);
      expect(report.stats['deepIndexEntries'], 1);
      expect(report.stats['deepTextPostings'], greaterThan(0));
    });

    test('reports orphan segment files as warnings', () {
      collection.putSync(k('a'), doc('alpha', 1));
      db.flushSync();

      File('${root.path}${Platform.pathSeparator}SEG-000099.seg')
          .writeAsBytesSync(<int>[1, 2, 3]);

      final report = db.checkSync();
      expect(report.ok, isTrue);
      expect(
        report.issues.any((issue) => issue.code == 'orphan-segment'),
        isTrue,
      );
      expect(report.warningCount, greaterThan(0));
    });

    test('deep check finds dangling index postings', () {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('alpha', 1));
      // Delete the document behind the collection's back.
      db.engine.deleteSync(collection.composeKey(k('a')));

      final report = db.checkSync(deep: true);
      expect(report.ok, isFalse);
      expect(
        report.issues.any((issue) => issue.code == 'dangling-index'),
        isTrue,
      );
    });

    test('deep check finds stale index values', () {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('alpha', 1));
      // Rewrite the document with a different indexed value, bypassing upkeep.
      db.engine.putSync(collection.composeKey(k('a')), doc('alpha', 2));

      final report = db.checkSync(deep: true);
      expect(report.ok, isFalse);
      expect(report.issues.any((issue) => issue.code == 'stale-index'), isTrue);
    });

    test('deep check finds stale text postings', () {
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('alpha beta', 1));
      db.engine.putSync(collection.composeKey(k('a')), doc('gamma delta', 1));

      final report = db.checkSync(deep: true);
      expect(report.ok, isFalse);
      expect(
        report.issues.any((issue) => issue.code == 'stale-text-index'),
        isTrue,
      );
    });
  });
}
