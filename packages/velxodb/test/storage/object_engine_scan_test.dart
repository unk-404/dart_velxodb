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
  test('async scan merges memtable and segments in key order', () async {
    final engine = ObjectStoreEngine(store: SimulatedObjectStore());
    await engine.open();
    for (final value in <String>['a', 'b', 'c', 'd', 'e']) {
      await engine.put(k(value), doc('v$value'));
    }
    await engine.flush();
    await engine.put(k('b'), doc('vB'));
    await engine.put(k('f'), doc('vF'));
    await engine.delete(k('c'));

    final all = await engine.scanRange();
    expect(
      all.map((entry) => String.fromCharCodes(entry.key)).toList(),
      <String>['a', 'b', 'd', 'e', 'f'],
    );
    expect(textOf(all[1].document), 'vB');

    final middle = await engine.scanRange(start: k('b'), end: k('e'));
    expect(
      middle.map((entry) => String.fromCharCodes(entry.key)).toList(),
      <String>['b', 'd'],
    );

    final limited = await engine.scanRange(limit: 2);
    expect(limited, hasLength(2));
    await engine.close();
  });

  test('async scan survives a reopen', () async {
    final store = SimulatedObjectStore();
    var engine = ObjectStoreEngine(store: store);
    await engine.open();
    await engine.put(k('a'), doc('alpha'));
    await engine.put(k('b'), doc('beta'));
    await engine.flush();
    await engine.close();

    engine = ObjectStoreEngine(store: store);
    await engine.open();
    final entries = await engine.scanRange();
    expect(entries, hasLength(2));
    expect(textOf(entries[0].document), 'alpha');
    await engine.close();
  });
}
