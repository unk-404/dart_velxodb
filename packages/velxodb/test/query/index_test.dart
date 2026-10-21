@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text, int number) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, number))
        .finish();

List<String> keysOf(List<ScanEntry> entries) => <String>[
  for (final entry in entries) String.fromCharCodes(entry.key),
];

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_index_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('items');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('secondary index', () {
    test('finds documents by integer value', () {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('a', 7));
      collection.putSync(k('b'), doc('b', 8));
      collection.putSync(k('c'), doc('c', 7));

      expect(keysOf(collection.lookupByIndexSync(2, 7)), <String>['a', 'c']);
      expect(keysOf(collection.lookupByIndexSync(2, 8)), <String>['b']);
      expect(collection.lookupByIndexSync(2, 9), isEmpty);
    });

    test('updates and removes index entries', () {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('a', 7));
      expect(keysOf(collection.lookupByIndexSync(2, 7)), <String>['a']);

      collection.putSync(k('a'), doc('a', 9));
      expect(collection.lookupByIndexSync(2, 7), isEmpty);
      expect(keysOf(collection.lookupByIndexSync(2, 9)), <String>['a']);

      collection.deleteSync(k('a'));
      expect(collection.lookupByIndexSync(2, 9), isEmpty);
    });

    test('indexes strings, including empty and embedded nulls', () {
      collection.createIndex(1, VxsType.string);
      collection.putSync(k('a'), doc('a', 1));
      collection.putSync(k('b'), doc('ab', 2));
      collection.putSync(k('c'), doc('', 3));
      collection.putSync(k('d'), doc('a\u0000b', 4));

      expect(keysOf(collection.lookupByIndexSync(1, 'a')), <String>['a']);
      expect(keysOf(collection.lookupByIndexSync(1, 'ab')), <String>['b']);
      expect(keysOf(collection.lookupByIndexSync(1, '')), <String>['c']);
      expect(keysOf(collection.lookupByIndexSync(1, 'a\u0000b')), <String>[
        'd',
      ]);
    });

    test('backfills existing documents when created later', () {
      collection.putSync(k('a'), doc('a', 7));
      collection.putSync(k('b'), doc('b', 8));
      collection.createIndex(2, VxsType.int64);
      expect(keysOf(collection.lookupByIndexSync(2, 7)), <String>['a']);
      expect(keysOf(collection.lookupByIndexSync(2, 8)), <String>['b']);
    });

    test('survives flush and reopen', () async {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('a', 7));
      collection.putSync(k('b'), doc('b', 7));
      db.flushSync();
      collection.putSync(k('c'), doc('c', 7));

      expect(keysOf(collection.lookupByIndexSync(2, 7)), <String>[
        'a',
        'b',
        'c',
      ]);

      await db.close();
      db = VelxoDatabase.openSync(root.path);
      collection = db.collection('items');
      expect(collection.indexes[2]?.type, VxsType.int64);
      expect(keysOf(collection.lookupByIndexSync(2, 7)), <String>[
        'a',
        'b',
        'c',
      ]);
    });

    test('does not leak index entries into the collection scan', () {
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('a', 7));
      collection.putSync(k('b'), doc('b', 7));
      final scanned = collection.scanSync();
      expect(keysOf(scanned), <String>['a', 'b']);
      expect(
        scanned.map((e) => DocView.parse(e.value.asUint8List()).getInt(2)),
        <int>[7, 7],
      );
    });

    test('re-registering an index is idempotent and rejects type changes', () {
      final first = collection.createIndex(2, VxsType.int64);
      final second = collection.createIndex(2, VxsType.int64);
      expect(second.indexId, first.indexId);
      expect(
        () => collection.createIndex(2, VxsType.string),
        throwsArgumentError,
      );
    });

    test('values with different signs encode in order', () {
      collection.createIndex(2, VxsType.int64);
      final values = <int>[-1000, -5, -1, 0, 1, 5, 1000];
      for (var i = 0; i < values.length; i++) {
        collection.putSync(k('k$i'), doc('v$i', values[i]));
      }
      for (final value in values) {
        expect(
          collection.lookupByIndexSync(2, value),
          hasLength(1),
          reason: 'value $value',
        );
      }
    });
  });
}
