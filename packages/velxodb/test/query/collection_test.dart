@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, text.length))
        .finish();

String textOf(Bytes bytes) => DocView.parse(bytes.asUint8List()).getString(1)!;

void main() {
  late Directory root;
  late VelxoDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_query_');
    db = VelxoDatabase.openSync(root.path);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('catalog', () {
    test('assigns stable ids and persists them', () async {
      final messages = db.collection('messages');
      final users = db.collection('users');
      expect(messages.id, isNot(users.id));
      expect(db.collectionNames, containsAll(<String>['messages', 'users']));
      await db.close();

      final reopened = VelxoDatabase.openSync(root.path);
      expect(reopened.collection('messages').id, messages.id);
      expect(reopened.collection('users').id, users.id);
      expect(reopened.collectionNames, hasLength(2));
      db = reopened;
    });

    test('round trips through bytes', () {
      final catalog = Catalog(<CollectionEntry>[
        const CollectionEntry(1, 'a'),
        const CollectionEntry(2, 'b'),
      ]);
      final decoded = Catalog.decode(catalog.encode());
      expect(decoded.entries.map((e) => e.name), <String>['a', 'b']);
      expect(decoded.idOf('b'), 2);
      expect(decoded.withCollection('c').idOf('c'), 3);
    });
  });

  group('collection', () {
    test('put, get and delete', () {
      final messages = db.collection('messages');
      messages.putSync(k('a'), doc('alpha'));
      expect(textOf(messages.get(k('a'))!), 'alpha');

      messages.putSync(k('a'), doc('alpha2'));
      expect(textOf(messages.get(k('a'))!), 'alpha2');

      messages.deleteSync(k('a'));
      expect(messages.get(k('a')), isNull);
      expect(messages.get(k('missing')), isNull);
    });

    test('collections are isolated', () {
      final messages = db.collection('messages');
      final users = db.collection('users');
      messages.putSync(k('same'), doc('message'));
      users.putSync(k('same'), doc('user'));
      expect(textOf(messages.get(k('same'))!), 'message');
      expect(textOf(users.get(k('same'))!), 'user');
    });

    test('prefix scan returns sorted, shadowed and tombstoned results', () {
      final messages = db.collection('messages');
      messages.putSync(k('a'), doc('a1'));
      messages.putSync(k('ab'), doc('ab1'));
      messages.putSync(k('abc'), doc('abc1'));
      messages.putSync(k('b'), doc('b1'));
      messages.putSync(k('z'), doc('z1'));

      // Shadow 'ab' with a newer value and delete 'abc'.
      messages.putSync(k('ab'), doc('ab2'));
      messages.deleteSync(k('abc'));

      final scanned = messages.scanPrefixSync(k('a'));
      expect(scanned.map((e) => String.fromCharCodes(e.key)).toList(), <String>[
        'a',
        'ab',
      ]);
      expect(textOf(scanned[1].value), 'ab2');

      // Everything.
      final all = messages.scanPrefixSync();
      expect(all.map((e) => String.fromCharCodes(e.key)).toList(), <String>[
        'a',
        'ab',
        'b',
        'z',
      ]);
    });

    test('prefix scan merges memtable and flushed segments', () async {
      final messages = db.collection('messages');
      messages.putSync(k('k1'), doc('v1'));
      messages.putSync(k('k2'), doc('v2'));
      db.flushSync();

      messages.putSync(k('k2'), doc('v2-new'));
      messages.putSync(k('k3'), doc('v3'));
      messages.deleteSync(k('k1'));

      final scanned = messages.scanPrefixSync(k('k'));
      expect(scanned.map((e) => String.fromCharCodes(e.key)).toList(), <String>[
        'k2',
        'k3',
      ]);
      expect(textOf(scanned[0].value), 'v2-new');

      // And after reopening, segments + catalog still line up.
      await db.close();
      db = VelxoDatabase.openSync(root.path);
      final afterReopen = db.collection('messages').scanPrefixSync(k('k'));
      expect(
        afterReopen.map((e) => String.fromCharCodes(e.key)).toList(),
        <String>['k2', 'k3'],
      );
    });

    test('prefix scan never crosses collection boundaries', () {
      final messages = db.collection('messages');
      final users = db.collection('users');
      messages.putSync(k('x'), doc('m'));
      users.putSync(k('x'), doc('u'));
      final scanned = messages.scanPrefixSync();
      expect(scanned, hasLength(1));
      expect(textOf(scanned.single.value), 'm');
    });

    test('empty prefix on an empty collection', () {
      expect(db.collection('empty').scanPrefixSync(), isEmpty);
    });
  });
}
