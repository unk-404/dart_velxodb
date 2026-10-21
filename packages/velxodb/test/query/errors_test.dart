@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

void main() {
  group('typed errors', () {
    test('a second open is a lock error', () {
      final root = Directory.systemTemp.createTempSync('velxo_err_');
      final first = VelxoDatabase.openSync(root.path);
      expect(
        () => VelxoDatabase.openSync(root.path),
        throwsA(isA<VelxoLockedException>()),
      );
      first.close();
      root.deleteSync(recursive: true);
    });

    test('using a closed engine is a closed error', () async {
      final root = Directory.systemTemp.createTempSync('velxo_err_');
      final db = VelxoDatabase.openSync(root.path);
      await db.close();
      expect(
        () => db.collection('x').get(k('a')),
        throwsA(isA<VelxoClosedException>()),
      );
      root.deleteSync(recursive: true);
    });

    test('nested transactions are a conflict error', () {
      final root = Directory.systemTemp.createTempSync('velxo_err_');
      final db = VelxoDatabase.openSync(root.path);
      expect(
        () => db.transactionSync(() {
          db.transactionSync(() {});
        }),
        throwsA(isA<VelxoConflictException>()),
      );
      db.close();
      root.deleteSync(recursive: true);
    });

    test('missing indexes are a not-found error', () {
      final root = Directory.systemTemp.createTempSync('velxo_err_');
      final db = VelxoDatabase.openSync(root.path);
      final collection = db.collection('items');
      expect(
        () => collection.lookupByIndexSync(2, 1),
        throwsA(isA<VelxoNotFoundException>()),
      );
      expect(
        () => collection.searchTextSync(1, 'x'),
        throwsA(isA<VelxoNotFoundException>()),
      );
      db.close();
      root.deleteSync(recursive: true);
    });

    test('a corrupt catalog refuses to open', () async {
      final root = Directory.systemTemp.createTempSync('velxo_err_');
      final db = VelxoDatabase.openSync(root.path);
      db.collection('items');
      await db.close();

      File('${root.path}${Platform.pathSeparator}CATALOG')
          .writeAsBytesSync(<int>[0x43, 5, 0, 0, 9, 9, 9]);

      expect(
        () => VelxoDatabase.openSync(root.path),
        throwsA(isA<VelxoCorruptException>()),
      );
      root.deleteSync(recursive: true);
    });
  });

  group('corrupt manifest', () {
    test('both slots unreadable is corruption, not an empty database', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(
        k('a'),
        (DocBuilder(schemaId: 1)..putString(1, 'alpha')).finish(),
      );
      engine.flushSync();
      engine.close();

      for (final slot in <String>['MANIFEST-0', 'MANIFEST-1']) {
        if (directory.existsSync(slot)) {
          directory.openSync(slot).writeAllSync(Uint8List(8));
        }
      }

      expect(
        () => StorageEngine(directory: directory).openSync(),
        throwsA(isA<VelxoCorruptException>()),
      );
    });
  });
}
