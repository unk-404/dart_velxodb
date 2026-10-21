@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text, [int number = 0]) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, number))
        .finish();

String textOf(Bytes bytes) => DocView.parse(bytes.asUint8List()).getString(1)!;

List<String> keysOf(List<ScanEntry> entries) => <String>[
  for (final entry in entries) String.fromCharCodes(entry.key),
];

void main() {
  group('engine transactions', () {
    test('commit applies every write atomically', () {
      final engine = StorageEngine(directory: MemoryStorageDirectory())
        ..openSync();
      engine.transactionSync(() {
        engine.putSync(k('a'), doc('alpha'));
        engine.putSync(k('b'), doc('beta'));
      });
      expect(textOf(engine.get(k('a'))!), 'alpha');
      expect(textOf(engine.get(k('b'))!), 'beta');
    });

    test('rollback discards buffered writes', () {
      final engine = StorageEngine(directory: MemoryStorageDirectory())
        ..openSync();
      expect(
        () => engine.transactionSync(() {
          engine.putSync(k('a'), doc('alpha'));
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(engine.get(k('a')), isNull);
      expect(engine.inTransaction, isFalse);
    });

    test('point reads see uncommitted writes and tombstones', () {
      final engine = StorageEngine(directory: MemoryStorageDirectory())
        ..openSync();
      engine.putSync(k('old'), doc('before'));
      engine.transactionSync(() {
        expect(textOf(engine.get(k('old'))!), 'before');
        engine.putSync(k('new'), doc('inside'));
        expect(textOf(engine.get(k('new'))!), 'inside');
        engine.deleteSync(k('old'));
        expect(engine.get(k('old')), isNull);
      });
      expect(engine.get(k('old')), isNull);
      expect(textOf(engine.get(k('new'))!), 'inside');
    });

    test('coalesces repeated writes to one key', () {
      final engine = StorageEngine(directory: MemoryStorageDirectory())
        ..openSync();
      engine.transactionSync(() {
        engine.putSync(k('a'), doc('one'));
        engine.putSync(k('a'), doc('two'));
        engine.deleteSync(k('a'));
      });
      expect(engine.get(k('a')), isNull);
    });

    test('nested transactions are rejected', () {
      final engine = StorageEngine(directory: MemoryStorageDirectory())
        ..openSync();
      expect(
        () => engine.transactionSync(() {
          engine.transactionSync(() {});
        }),
        throwsA(isA<VelxoConflictException>()),
      );
      expect(engine.inTransaction, isFalse);
    });

    test('a torn commit frame loses the whole transaction', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.transactionSync(() {
        engine.putSync(k('a'), doc('alpha'));
        engine.putSync(k('b'), doc('beta'));
      });
      engine.syncNow();

      final complete = Uint8List.fromList(
        (directory.openSync(
          StorageEngine.walFileName,
        ) as MemoryStorageFile).bytes,
      );
      final torn = MemoryStorageDirectory();
      torn
          .openSync(StorageEngine.walFileName)
          .writeAllSync(
            Uint8List.sublistView(complete, 0, complete.length - 4),
          );

      final recovered = StorageEngine(directory: torn)..openSync();
      expect(recovered.get(k('a')), isNull);
      expect(recovered.get(k('b')), isNull);
    });
  });

  group('database transactions', () {
    late VelxoDatabase db;
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('velxo_tx_');
      db = VelxoDatabase.openSync(root.path);
    });

    tearDown(() async {
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('spans collections and keeps indexes consistent', () async {
      final users = db.collection('users');
      final messages = db.collection('messages');
      messages.createIndex(2, VxsType.int64);

      db.transactionSync(() {
        users.putSync(k('u1'), doc('user'));
        messages.putSync(k('m1'), doc('message', 7));
        expect(textOf(messages.get(k('m1'))!), 'message');
      });

      expect(textOf(users.get(k('u1'))!), 'user');
      expect(keysOf(messages.lookupByIndexSync(2, 7)), <String>['m1']);
    });

    test('rollback leaves no index entries behind', () async {
      final messages = db.collection('messages');
      messages.createIndex(2, VxsType.int64);
      expect(
        () => db.transactionSync(() {
          messages.putSync(k('m1'), doc('message', 7));
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(messages.get(k('m1')), isNull);
      expect(messages.lookupByIndexSync(2, 7), isEmpty);
    });

    test('graph edges participate in transactions', () async {
      final users = db.collection('users');
      final a = NodeRef.of(users, k('a'));
      final b = NodeRef.of(users, k('b'));
      db.transactionSync(() {
        db.graph.link('follows', a, b);
        expect(db.graph.has('follows', a, b), isTrue);
      });
      expect(db.graph.has('follows', a, b), isTrue);
      expect(db.graph.outgoing('follows', a), hasLength(1));
    });
  });
}
