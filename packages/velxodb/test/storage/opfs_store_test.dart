@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List bytes(String value) => Uint8List.fromList(value.codeUnits);

Uint8List key(String value) => Uint8List.fromList(value.codeUnits);

String? textOf(Bytes? value) =>
    value == null ? null : DocView.parse(value.asUint8List()).getString(1);

void main() {
  test('OPFS store put/get/list/delete survives a reopen', () async {
    final root = 'velxodb-test-${DateTime.now().microsecondsSinceEpoch}';
    final store = await OpfsObjectStore.open(root: root);
    expect(await store.list(''), isEmpty);

    await store.put('seg/1', bytes('hello'));
    await store.put('wal/1', bytes('world'));
    expect(await store.get('seg/1'), bytes('hello'));
    expect(await store.get('wal/1'), bytes('world'));
    expect(await store.list('seg/'), <String>['seg/1']);

    await store.delete('seg/1');
    expect(await store.get('seg/1'), isNull);
    await store.put('seg/2', bytes('again'));
    await store.close();

    final reopened = await OpfsObjectStore.open(root: root);
    expect(await reopened.get('seg/2'), bytes('again'));
    expect(await reopened.list(''), <String>['seg/2', 'wal/1']);
    await reopened.close();
  });

  test('a large object round trips through chunked OPFS files', () async {
    final root = 'velxodb-large-${DateTime.now().microsecondsSinceEpoch}';
    final store = await OpfsObjectStore.open(root: root);
    final value = Uint8List(300 * 1024);
    for (var i = 0; i < value.length; i++) {
      value[i] = i & 0xFF;
    }
    await store.put('big', value);
    expect(await store.get('big'), value);
    await store.close();
  });

  test('ObjectStoreEngine writes and reopens over OPFS', () async {
    final root = 'velxodb-engine-${DateTime.now().microsecondsSinceEpoch}';
    final store = await OpfsObjectStore.open(root: root);
    final engine = ObjectStoreEngine(store: store);
    await engine.open();

    final document = (DocBuilder(schemaId: 1)..putString(1, 'hello')).finish();
    await engine.put(key('a'), document);
    await engine.flush();
    expect(textOf(await engine.get(key('a'))), 'hello');
    await engine.close();

    final reopened = ObjectStoreEngine(store: store);
    await reopened.open();
    expect(textOf(await reopened.get(key('a'))), 'hello');
    await reopened.close();
    await store.close();
  });
}
