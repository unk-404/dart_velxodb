@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish();

String? textOf(Bytes? bytes) =>
    bytes == null ? null : DocView.parse(bytes.asUint8List()).getString(1);

void main() {
  test('an object-store batch commits as one WAL object', () async {
    final store = SimulatedObjectStore();
    final engine = ObjectStoreEngine(store: store);
    await engine.open();
    await engine.put(k('a'), doc('alpha'));
    await engine.put(k('b'), doc('beta'));

    final walBefore = (await store.list('db/wal/')).length;
    await engine.applyBatch(<WalOp>[
      WalOp.put(k('c'), doc('gamma').asUint8List()),
      WalOp.delete(k('a')),
    ]);
    expect((await store.list('db/wal/')).length, walBefore + 1);
    expect(await engine.get(k('a')), isNull);
    expect(textOf(await engine.get(k('c'))), 'gamma');
    await engine.close();

    final reopened = ObjectStoreEngine(store: store);
    await reopened.open();
    expect(await reopened.get(k('a')), isNull);
    expect(textOf(await reopened.get(k('b'))), 'beta');
    expect(textOf(await reopened.get(k('c'))), 'gamma');
    await reopened.close();
  });
}
