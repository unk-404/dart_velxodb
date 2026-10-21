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

List<int> valuesOf(List<ScanEntry> entries) => <int>[
  for (final entry in entries)
    DocView.parse(entry.value.asUint8List()).getInt(2)!,
];

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_page_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('index range', () {
    test('respects open and closed integer bounds', () {
      collection.createIndex(2, VxsType.int64);
      for (var i = -5; i <= 5; i++) {
        collection.putSync(k('k${i + 100}'), doc('v$i', i));
      }
      // Default is [from, to).
      expect(
        valuesOf(collection.lookupByIndexRangeSync(2, from: -2, to: 2)),
        <int>[-2, -1, 0, 1],
      );
      expect(
        valuesOf(
          collection.lookupByIndexRangeSync(2, from: -2, to: 2, includeTo: true),
        ),
        <int>[-2, -1, 0, 1, 2],
      );
      expect(
        valuesOf(
          collection.lookupByIndexRangeSync(2, from: -2, includeFrom: false),
        ),
        <int>[-1, 0, 1, 2, 3, 4, 5],
      );
      expect(
        valuesOf(collection.lookupByIndexRangeSync(2, to: 0)),
        <int>[-5, -4, -3, -2, -1],
      );
    });

    test('ranges over strings, including prefixes and empty strings', () {
      collection.createIndex(1, VxsType.string);
      collection.putSync(k('a'), doc('a', 1));
      collection.putSync(k('ab'), doc('ab', 2));
      collection.putSync(k('b'), doc('b', 3));
      collection.putSync(k('ba'), doc('ba', 4));
      collection.putSync(k('c'), doc('c', 5));

      expect(
        valuesOf(
          collection.lookupByIndexRangeSync(1, from: 'a', to: 'c'),
        ),
        <int>[1, 2, 3, 4],
      );
      expect(
        valuesOf(
          collection.lookupByIndexRangeSync(1, from: 'ab', to: 'b', includeTo: true),
        ),
        <int>[2, 3],
      );
      expect(
        valuesOf(collection.lookupByIndexRangeSync(1, from: 'b')),
        <int>[3, 4, 5],
      );
    });

    test('limit stops early', () {
      collection.createIndex(2, VxsType.int64);
      for (var i = 0; i < 10; i++) {
        collection.putSync(k('k$i'), doc('v$i', i));
      }
      final page = collection.lookupByIndexRangeSync(2, from: 2, limit: 3);
      expect(valuesOf(page), <int>[2, 3, 4]);
    });
  });

  group('pagination', () {
    test('walks every key exactly once', () {
      for (var i = 0; i < 5; i++) {
        collection.putSync(k('k$i'), doc('v$i', i));
      }
      final first = collection.pageSync(limit: 2);
      expect(keysOf(first.entries), <String>['k0', 'k1']);
      final second = collection.pageSync(limit: 2, after: first.next);
      expect(keysOf(second.entries), <String>['k2', 'k3']);
      final third = collection.pageSync(limit: 2, after: second.next);
      expect(keysOf(third.entries), <String>['k4']);
      expect(third.next, isNull);
    });

    test('combines prefix, filter and token', () async {
      collection.putSync(k('a1'), doc('a1', 1));
      collection.putSync(k('a2'), doc('a2', 2));
      collection.putSync(k('a3'), doc('a3', 3));
      collection.putSync(k('b1'), doc('b1', 4));
      db.flushSync();

      final page = collection.pageSync(
        prefix: k('a'),
        limit: 5,
        where: (document) => document.getInt(2)! > 1,
      );
      expect(keysOf(page.entries), <String>['a2', 'a3']);
      expect(page.next, isNull);
    });

    test('next token gives an empty page at the end', () {
      collection.putSync(k('k0'), doc('v0', 0));
      final first = collection.pageSync(limit: 1);
      expect(first.next, isNotNull);
      final second = collection.pageSync(limit: 1, after: first.next);
      expect(second.entries, isEmpty);
      expect(second.next, isNull);
    });
  });
}
