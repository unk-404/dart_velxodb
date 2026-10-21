@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List keyOf(String value) => Uint8List.fromList(value.codeUnits);

Bytes document({int? id, int? group, String? ref}) {
  final builder = DocBuilder(schemaId: 1);
  if (id != null) builder.putString(1, 'id-$id');
  if (group != null) builder.putInt(2, group);
  if (ref != null) builder.putString(3, ref);
  return builder.finish();
}

void main() {
  late Directory root;
  late VelxoDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_guard_');
    db = VelxoDatabase.openSync(root.path);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('non-ASCII collection and relation names survive a reopen', () async {
    final messages = db.collection('消息');
    messages.putSync(keyOf('m1'), document(id: 1));
    final relation = db.relationId('关注');
    expect(relation, greaterThan(0));

    await db.close();
    db = VelxoDatabase.openSync(root.path);

    expect(db.collectionNames, contains('消息'));
    final reopened = db.collection('消息');
    expect(reopened.id, messages.id);
    expect(reopened.get(keyOf('m1')), isNotNull);
    expect(db.relationNames(), contains('关注'));
    expect(db.collectionOrNull('不存在'), isNull);
  });

  test(
    'an interrupted index backfill is finished on the next writable open',
    () async {
      final messages = db.collection('messages');
      messages.putSync(keyOf('a'), document(group: 5));
      messages.putSync(keyOf('b'), document(group: 5));
      messages.putSync(keyOf('c'), document(group: 9));

      // Simulate a crash right after the catalog recorded the index and before
      // (or during) the backfill: the index is stored as not ready.
      db.registerIndex(messages.id, 2, VxsType.int64, ready: false);
      await db.close();

      db = VelxoDatabase.openSync(root.path);
      final reopened = db.collection('messages');
      expect(reopened.indexes[2]?.ready, isTrue);
      expect(
        reopened
            .lookupByIndexSync(2, 5)
            .map((e) => String.fromCharCodes(e.key)),
        <String>['a', 'b'],
      );
    },
  );

  test('an index plan still honours the query key range', () {
    final messages = db.collection('messages');
    messages.createIndex(2, VxsType.int64);
    for (var i = 0; i < 10; i++) {
      messages.putSync(keyOf('k$i'), document(group: i.isEven ? 0 : 1));
    }

    final hits = messages.findSync(
      Query(where: Predicate.eq(2, 0), start: keyOf('k4'), end: keyOf('k7')),
    );
    expect(hits.map((entry) => String.fromCharCodes(entry.key)), <String>[
      'k4',
      'k6',
    ]);

    final limited = messages.findSync(
      Query(where: Predicate.eq(2, 1), limit: 2),
    );
    expect(limited, hasLength(2));
  });

  test(
    'a referrer written in the same transaction blocks a restrict delete',
    () {
      final users = db.collection('users');
      final messages = db.collection('messages');
      users.putSync(keyOf('u1'), document(id: 1));
      messages.createReference(3, 'users');

      expect(
        () => db.transactionSync(() {
          messages.putSync(keyOf('m1'), document(id: 2, ref: 'u1'));
          users.deleteSync(keyOf('u1'));
        }),
        throwsA(isA<VelxoConstraintException>()),
      );
      expect(users.get(keyOf('u1')), isNotNull);
      expect(messages.get(keyOf('m1')), isNull);
      expect(messages.lookupByIndexSync(3, 'u1'), isEmpty);
    },
  );

  test('an int index sees a document written in the same transaction', () {
    final items = db.collection('items');
    items.createIndex(2, VxsType.int64);
    db.transactionSync(() {
      items.putSync(keyOf('a'), document(group: 5));
      expect(items.lookupByIndexSync(2, 5), hasLength(1));
      expect(items.lookupByIndexRangeSync(2, from: 4, to: 6), hasLength(1));
    });
  });

  test('a full-text index sees a document written in the same transaction', () {
    final items = db.collection('text');
    items.createTextIndex(1);
    final body = (DocBuilder(
      schemaId: 1,
    )..putString(1, 'hello world')).finish();
    db.transactionSync(() {
      items.putSync(keyOf('a'), body);
      expect(items.searchTextSync(1, 'hello'), hasLength(1));
    });
  });

  test('a field whose type disagrees with its index is a typed error', () {
    final items = db.collection('items');
    items.createIndex(2, VxsType.int64);
    expect(
      () => items.putSync(
        keyOf('bad'),
        (DocBuilder(schemaId: 1)..putString(2, 'not an int')).finish(),
      ),
      throwsA(isA<VelxoConstraintException>()),
    );
    expect(items.get(keyOf('bad')), isNull);
  });

  test('a migration longer than the target version is allowed', () {
    final items = db.collection('items');
    items.putSync(keyOf('a'), document(id: 1));
    final report = items.migrateSync(
      toVersion: 2,
      steps: <MigrationStep>[
        MigrationStep(from: 1, to: 2, apply: copyFields),
        MigrationStep(from: 2, to: 3, apply: copyFields),
      ],
    );
    expect(report.migrated, 1);
  });

  test('validateReferences audits a bulk load without enforcing writes', () {
    final users = db.collection('users');
    final messages = db.collection('messages');
    messages.createReference(3, 'users');
    messages.putSync(keyOf('m1'), document(id: 1, ref: 'ghost'));
    final issues = messages.validateReferences();
    expect(issues, hasLength(1));
    expect(issues.single.value, 'ghost');
    expect(issues.single.targetCollectionId, users.id);

    users.putSync(keyOf('ghost'), document(id: 2));
    expect(messages.validateReferences(), isEmpty);
  });

  test('the format stamp is written atomically and leaves no temp file', () {
    expect(File('${root.path}/FORMAT').existsSync(), isTrue);
    expect(File('${root.path}/FORMAT.tmp').existsSync(), isFalse);
  });
}
