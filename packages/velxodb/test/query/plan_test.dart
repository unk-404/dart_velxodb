@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text, int number) => (DocBuilder(schemaId: 1)
      ..putString(1, text)
      ..putInt(2, number))
    .finish();

List<String> keysOf(List<ScanEntry> entries) =>
    <String>[for (final entry in entries) String.fromCharCodes(entry.key)];

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_plan_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
    for (var i = 0; i < 6; i++) {
      collection.putSync(k('k$i'), doc('v$i', i));
    }
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('planner', () {
    test('scans without an index', () {
      expect(collection.explainSync(Query(where: Predicate.eq(2, 3))), 'scan');
      expect(
        keysOf(collection.findSync(Query(where: Predicate.eq(2, 3)))),
        <String>['k3'],
      );
    });

    test('uses an equality index when available', () {
      collection.createIndex(2, VxsType.int64);
      expect(
        collection.explainSync(Query(where: Predicate.eq(2, 3))),
        'index:eq field=2',
      );
      expect(
        keysOf(collection.findSync(Query(where: Predicate.eq(2, 3)))),
        <String>['k3'],
      );
    });

    test('uses a range index', () {
      collection.createIndex(2, VxsType.int64);
      final query = Query(
        where: Predicate.between(2, from: 1, to: 4),
      );
      expect(collection.explainSync(query), 'index:range field=2');
      expect(keysOf(collection.findSync(query)), <String>['k1', 'k2', 'k3']);
    });

    test('keeps the residual predicate on an index plan', () {
      collection.createIndex(2, VxsType.int64);
      final query = Query(
        where: Predicate.and(<Predicate>[
          Predicate.eq(2, 3),
          Predicate.eq(1, 'nope'),
        ]),
      );
      expect(collection.explainSync(query), 'index:eq field=2');
      expect(collection.findSync(query), isEmpty);
    });

    test('or and not fall back to a scan', () {
      collection.createIndex(2, VxsType.int64);
      expect(
        collection.explainSync(
          Query(
            where: Predicate.or(<Predicate>[
              Predicate.eq(2, 1),
              Predicate.eq(2, 2),
            ]),
          ),
        ),
        'scan',
      );
      expect(
        collection.explainSync(
          Query(where: Predicate.not(Predicate.eq(2, 1))),
        ),
        'scan',
      );
    });

    test('limit is applied after filtering', () {
      collection.createIndex(2, VxsType.int64);
      final query = Query(
        where: Predicate.and(<Predicate>[
          Predicate.gte(2, 2),
          Predicate.lt(1, 'v4'),
        ]),
        limit: 2,
      );
      expect(collection.findSync(query), hasLength(2));
    });

    test('queries survive a flush', () async {
      collection.createIndex(2, VxsType.int64);
      db.flushSync();
      expect(
        keysOf(collection.findSync(Query(where: Predicate.eq(2, 4)))),
        <String>['k4'],
      );
    });
  });
}
