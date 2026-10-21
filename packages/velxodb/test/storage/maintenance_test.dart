@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish();

class ManualScheduler implements MaintenanceScheduler {
  final List<void Function()> queue = <void Function()>[];

  @override
  void schedule(void Function() task) => queue.add(task);

  void run() {
    while (queue.isNotEmpty) {
      queue.removeAt(0)();
    }
  }
}

void main() {
  group('maintenance scheduling', () {
    test('without a scheduler the flush stays inline', () {
      final engine = StorageEngine(
        directory: MemoryStorageDirectory(),
        autoFlush: true,
        maxMemtableBytes: 16,
      )..openSync();

      engine.putSync(k('a'), doc('one'));
      engine.putSync(k('b'), doc('two'));
      engine.putSync(k('c'), doc('three'));

      expect(engine.maintenanceScheduled, isFalse);
      expect(engine.segments, isNotEmpty);
      engine.closeSync();
    });

    test(
      'a deferred flush leaves the write path before building a segment',
      () {
        final scheduler = ManualScheduler();
        final directory = MemoryStorageDirectory();
        final engine = StorageEngine(
          directory: directory,
          autoFlush: true,
          maxMemtableBytes: 16,
          maintenanceScheduler: scheduler,
        )..openSync();

        engine.putSync(k('a'), doc('one'));
        engine.putSync(k('b'), doc('two'));
        engine.putSync(k('c'), doc('three'));

        expect(engine.maintenanceScheduled, isTrue);
        expect(engine.segments, isEmpty);
        // Reads are served by the memtable while maintenance is pending.
        expect(
          DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1),
          'one',
        );

        scheduler.run();
        expect(engine.maintenanceScheduled, isFalse);
        expect(engine.segments, isNotEmpty);
        expect(
          DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1),
          'one',
        );

        engine.closeSync();

        final reopened = StorageEngine(directory: directory)..openSync();
        expect(
          DocView.parse(reopened.get(k('b'))!.asUint8List()).getString(1),
          'two',
        );
        reopened.closeSync();
      },
    );

    test('closing with a pending flush is safe and WAL recovers the data', () {
      final scheduler = ManualScheduler();
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(
        directory: directory,
        autoFlush: true,
        maxMemtableBytes: 16,
        maintenanceScheduler: scheduler,
      )..openSync();

      engine.putSync(k('a'), doc('one'));
      engine.putSync(k('b'), doc('two'));
      engine.putSync(k('c'), doc('three'));
      expect(engine.maintenanceScheduled, isTrue);
      engine.closeSync();

      // The pending task must be a no-op on a closed engine.
      expect(scheduler.run, returnsNormally);

      final reopened = StorageEngine(directory: directory)..openSync();
      expect(
        DocView.parse(reopened.get(k('a'))!.asUint8List()).getString(1),
        'one',
      );
      reopened.closeSync();
    });

    test('the database forwards the deferred-maintenance option', () async {
      final root = await Directory.systemTemp.createTemp('velxo_maint_');
      final db = VelxoDatabase.openSync(
        root.path,
        maxMemtableBytes: 16,
        deferredMaintenance: true,
      );
      final collection = db.collection('items');
      for (var i = 0; i < 20; i++) {
        collection.putSync(k('k$i'), doc('value-$i'));
      }
      expect(collection.get(k('k0')), isNotNull);

      await Future<void>.delayed(Duration.zero);
      await db.close(flush: true);

      final reopened = VelxoDatabase.openSync(root.path);
      expect(reopened.collection('items').get(k('k19')), isNotNull);
      await reopened.close();
      root.deleteSync(recursive: true);
    });
  });
}
