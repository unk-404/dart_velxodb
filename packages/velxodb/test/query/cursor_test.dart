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

String textOf(Bytes bytes) =>
    DocView.parse(bytes.asUint8List()).getString(1)!;

List<String> keysOf(List<ScanEntry> entries) =>
    <String>[for (final entry in entries) String.fromCharCodes(entry.key)];

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_cursor_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
    collection.putSync(k('a'), doc('a', 1));
    collection.putSync(k('b'), doc('b', 2));
    collection.putSync(k('c'), doc('c', 3));
    collection.putSync(k('d'), doc('d', 4));
    collection.putSync(k('e'), doc('e', 5));
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('cursor', () {
    test('streams everything in key order', () {
      final cursor = collection.cursor();
      final seen = <String>[];
      while (cursor.moveNext()) {
        seen.add(String.fromCharCodes(cursor.current.key));
      }
      expect(seen, <String>['a', 'b', 'c', 'd', 'e']);
    });

    test('honours start and end bounds', () {
      expect(
        keysOf(collection.scanSync(start: k('b'), end: k('d'))),
        <String>['b', 'c'],
      );
      expect(
        keysOf(
          collection.scanSync(
            start: k('b'),
            end: k('d'),
            includeStart: false,
          ),
        ),
        <String>['c'],
      );
      expect(
        keysOf(collection.scanSync(start: k('b'), end: k('d'), includeEnd: true)),
        <String>['b', 'c', 'd'],
      );
      expect(keysOf(collection.scanSync(start: k('c'))), <String>['c', 'd', 'e']);
      expect(keysOf(collection.scanSync(end: k('c'))), <String>['a', 'b']);
    });

    test('combines prefix and range', () {
      collection.putSync(k('ca'), doc('ca', 6));
      expect(
        keysOf(collection.scanSync(prefix: k('c'))),
        <String>['c', 'ca'],
      );
      expect(
        keysOf(collection.scanSync(prefix: k('c'), start: k('ca'))),
        <String>['ca'],
      );
    });

    test('filters on decoded documents', () {
      final even = collection.scanSync(
        where: (document) => document.getInt(2)! % 2 == 0,
      );
      expect(keysOf(even), <String>['b', 'd']);
    });

    test('applies a limit', () {
      expect(
        keysOf(collection.scanSync(limit: 2)),
        <String>['a', 'b'],
      );
    });

    test('merges memtable and segment with tombstones', () async {
      db.flushSync();
      collection.putSync(k('b'), doc('b2', 20));
      collection.deleteSync(k('d'));
      collection.putSync(k('bb'), doc('bb', 7));

      final entries = collection.scanSync();
      expect(keysOf(entries), <String>['a', 'b', 'bb', 'c', 'e']);
      expect(textOf(entries[1].value), 'b2');

      // Reopen: same view from the segments.
      await db.close();
      db = VelxoDatabase.openSync(root.path);
      collection = db.collection('items');
      expect(keysOf(collection.scanSync()), <String>['a', 'b', 'bb', 'c', 'e']);
    });

    test('does not see other collections', () {
      final other = db.collection('other');
      other.putSync(k('a'), doc('other-a', 9));
      final entries = collection.scanSync();
      expect(textOf(entries.first.value), 'a');
      expect(entries, hasLength(5));
    });

    test('empty collection yields no entries', () {
      final empty = db.collection('empty');
      expect(empty.scanSync(), isEmpty);
      expect(empty.cursor().moveNext(), isFalse);
    });
  });
}
