@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish();

String? textOf(Bytes? bytes) =>
    bytes == null ? null : DocView.parse(bytes.asUint8List()).getString(1);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('velxo_ro_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('read-only', () {
    test('reads work and every write is rejected', () async {
      final path = '${root.path}${Platform.pathSeparator}db';
      final writable = VelxoDatabase.openSync(path);
      final collection = writable.collection('items');
      collection.putSync(k('a'), doc('alpha'));
      await writable.close(flush: true);

      final readonly = VelxoDatabase.openSync(path, readOnly: true);
      final reader = readonly.collection('items');
      expect(textOf(reader.get(k('a'))), 'alpha');
      expect(readonly.checkSync().ok, isTrue);

      expect(
        () => reader.putSync(k('b'), doc('beta')),
        throwsA(isA<VelxoReadOnlyException>()),
      );
      expect(
        () => reader.deleteSync(k('a')),
        throwsA(isA<VelxoReadOnlyException>()),
      );
      expect(
        readonly.flushSync,
        throwsA(isA<VelxoReadOnlyException>()),
      );
      expect(
        readonly.compactSync,
        throwsA(isA<VelxoReadOnlyException>()),
      );
      expect(
        () => reader.createIndex(2, VxsType.string),
        throwsA(isA<VelxoReadOnlyException>()),
      );
      expect(
        () => readonly.collection('missing'),
        throwsA(isA<VelxoNotFoundException>()),
      );

      await readonly.close(flush: true);
      final reopened = VelxoDatabase.openSync(path);
      expect(textOf(reopened.collection('items').get(k('a'))), 'alpha');
      await reopened.close();
    });

    test('opening a missing path read-only is a not-found error', () {
      final missing = '${root.path}${Platform.pathSeparator}missing';
      expect(
        () => VelxoDatabase.openSync(missing, readOnly: true),
        throwsA(isA<VelxoNotFoundException>()),
      );
    });
  });

  group('backup and restore', () {
    test('a backup reopens with the same data', () async {
      final path = '${root.path}${Platform.pathSeparator}db';
      final backupPath = '${root.path}${Platform.pathSeparator}backup';
      final db = VelxoDatabase.openSync(path);
      final collection = db.collection('items');
      collection.createIndex(2, VxsType.int64);
      collection.putSync(k('a'), doc('alpha'));
      collection.putSync(k('b'), doc('beta'));

      final target = LocalStorageDirectory(backupPath);
      late BackupReport report;
      try {
        report = db.backupSync(target);
      } finally {
        target.closeSync();
      }
      expect(report.files, greaterThan(0));
      expect(report.bytes, greaterThan(0));
      await db.close();

      final restored = VelxoDatabase.openSync(backupPath, readOnly: true);
      expect(textOf(restored.collection('items').get(k('b'))), 'beta');
      expect(restored.checkSync().ok, isTrue);
      await restored.close();
    });

    test('restoring into a new path yields a writable database', () async {
      final path = '${root.path}${Platform.pathSeparator}db';
      final backupPath = '${root.path}${Platform.pathSeparator}backup';
      final restorePath = '${root.path}${Platform.pathSeparator}restored';
      final db = VelxoDatabase.openSync(path);
      db.collection('items').putSync(k('a'), doc('alpha'));
      await db.close(flush: true);

      final backupDir = LocalStorageDirectory(backupPath);
      final sourceDb = VelxoDatabase.openSync(path);
      try {
        sourceDb.backupSync(backupDir);
      } finally {
        backupDir.closeSync();
        await sourceDb.close();
      }

      final sourceDir = LocalStorageDirectory(backupPath, readOnly: true);
      final target = LocalStorageDirectory(restorePath);
      try {
        copyDatabase(sourceDir, target);
      } finally {
        sourceDir.closeSync();
        target.closeSync();
      }

      final restored = VelxoDatabase.openSync(restorePath);
      expect(textOf(restored.collection('items').get(k('a'))), 'alpha');
      restored.collection('items').putSync(k('b'), doc('beta'));
      await restored.close();
    });

    test('a non-empty backup target is rejected', () async {
      final path = '${root.path}${Platform.pathSeparator}db';
      final db = VelxoDatabase.openSync(path);
      db.collection('items').putSync(k('a'), doc('alpha'));

      final target = LocalStorageDirectory(
        '${root.path}${Platform.pathSeparator}notempty',
      );
      target.openSync('stray').closeSync();
      try {
        expect(
          () => db.backupSync(target),
          throwsA(isA<StateError>()),
        );
      } finally {
        target.closeSync();
      }
      await db.close();
    });
  });
}
