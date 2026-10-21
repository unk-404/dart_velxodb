@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List key(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)..putString(1, text)).finish();

Bytes indexedDoc(String text, String sender) => (DocBuilder(schemaId: 1)
      ..putString(1, text)
      ..putString(2, sender))
    .finish();

String? textOf(Bytes? value) =>
    value == null ? null : DocView.parse(value.asUint8List()).getString(1);

void main() {
  test('web database CRUD, scan and reopen over OPFS', () async {
    final root = 'velxodb-web-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final items = await db.collection('items');
    await items.put(key('a'), doc('alpha'));
    await items.put(key('b'), doc('beta'));
    await items.put(key('c'), doc('gamma'));

    expect(textOf(await items.get(key('b'))), 'beta');
    final all = await items.scan();
    expect(
      all.map((entry) => String.fromCharCodes(entry.key)).toList(),
      <String>['a', 'b', 'c'],
    );
    final page = await items.page(limit: 2);
    expect(page.entries, hasLength(2));
    expect(String.fromCharCodes(page.next!), 'b');
    final rest = await items.page(after: page.next, limit: 10);
    expect(rest.entries, hasLength(1));

    await items.delete(key('b'));
    expect(await items.get(key('b')), isNull);
    await db.flush();
    await db.close();

    final reopened = await VelxoWebDatabase.open(root: root);
    final itemsAgain = await reopened.collection('items');
    expect(textOf(await itemsAgain.get(key('a'))), 'alpha');
    expect(textOf(await itemsAgain.get(key('c'))), 'gamma');
    expect(await itemsAgain.get(key('b')), isNull);
    await reopened.close();
  });

  test('web secondary indexes support equality and range', () async {
    final root = 'velxodb-index-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final items = await db.collection('items');
    await items.createIndex(2, VxsType.string);
    await items.put(key('a'), indexedDoc('alpha', 'u1'));
    await items.put(key('b'), indexedDoc('beta', 'u1'));
    await items.put(key('c'), indexedDoc('gamma', 'u2'));
    await items.put(key('d'), indexedDoc('delta', 'u3'));

    final bySender = await items.lookupByIndex(2, 'u1');
    expect(
      bySender.map((entry) => String.fromCharCodes(entry.key)).toList(),
      <String>['a', 'b'],
    );
    final range = await items.lookupByIndexRange(
      2,
      from: 'u1',
      to: 'u3',
      includeTo: false,
    );
    expect(
      range.map((entry) => String.fromCharCodes(entry.key)).toSet(),
      <String>{'a', 'b', 'c'},
    );

    await items.put(key('e'), indexedDoc('epsilon', 'u2'));
    expect((await items.lookupByIndex(2, 'u2')).length, 2);
    await items.delete(key('c'));
    expect((await items.lookupByIndex(2, 'u2')).length, 1);
    await db.close();
  });

  test('web write transactions commit documents and indexes atomically', () async {
    final root = 'velxodb-tx-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final items = await db.collection('items');
    await items.createIndex(2, VxsType.string);

    await db.writeTxn((tx) async {
      await tx.put(items, key('a'), indexedDoc('alpha', 'u1'));
      await tx.put(items, key('b'), indexedDoc('beta', 'u1'));
      expect(textOf(await tx.get(items, key('a'))), 'alpha');
    });

    expect((await items.lookupByIndex(2, 'u1')).length, 2);
    await db.writeTxn((tx) async {
      await tx.delete(items, key('a'));
    });
    expect((await items.lookupByIndex(2, 'u1')).length, 1);
    await db.close();
  });

  test('web references validate and restrict deletes', () async {
    final root = 'velxodb-ref-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final users = await db.collection('users');
    final messages = await db.collection('messages');
    await messages.createReference(2, 'users');

    await expectLater(
      messages.put(key('m1'), indexedDoc('hello', 'u1')),
      throwsA(isA<StateError>()),
    );
    await users.put(key('u1'), doc('user'));
    await messages.put(key('m1'), indexedDoc('hello', 'u1'));
    expect(
      (await messages.lookupByIndex(2, 'u1')).length,
      1,
    );
    await expectLater(
      users.delete(key('u1')),
      throwsA(isA<StateError>()),
    );
    await db.close();
  });

  test('web references cascade deletes', () async {
    final root = 'velxodb-refc-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final users = await db.collection('users');
    final messages = await db.collection('messages');
    await messages.createReference(2, 'users', onDelete: OnDelete.cascade);

    await users.put(key('u1'), doc('user'));
    await messages.put(key('m1'), indexedDoc('hello', 'u1'));
    await users.delete(key('u1'));
    expect(await messages.get(key('m1')), isNull);
    await db.close();
  });

  test('web graph links, adjacency and walk', () async {
    final root = 'velxodb-graph-${DateTime.now().microsecondsSinceEpoch}';
    final db = await VelxoWebDatabase.open(root: root);
    final users = await db.collection('users');
    await users.put(key('u1'), doc('one'));
    await users.put(key('u2'), doc('two'));
    await users.put(key('u3'), doc('three'));

    final u1 = NodeRef(users.id, key('u1'));
    final u2 = NodeRef(users.id, key('u2'));
    final u3 = NodeRef(users.id, key('u3'));
    await db.graph.link('follows', u1, u2);
    await db.graph.link('follows', u2, u3);

    final out = await db.graph.outgoing('follows', u1);
    expect(out, hasLength(1));
    expect(out.first.to, u2);
    final incoming = await db.graph.incoming('follows', u3);
    expect(incoming.first.from, u2);

    final walk = await db.graph.walk(u1, maxDepth: 2);
    expect(walk.levels, hasLength(3));
    expect(walk.levels[2], <NodeRef>[u3]);

    await db.graph.unlink('follows', u1, u2);
    expect(await db.graph.outgoing('follows', u1), isEmpty);
    await db.close();
  });
}
