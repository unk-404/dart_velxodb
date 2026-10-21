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
}
