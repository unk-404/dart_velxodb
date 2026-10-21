@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)..putString(1, text)).finish();

String? textOf(Bytes? bytes) =>
    bytes == null ? null : DocView.parse(bytes.asUint8List()).getString(1);

int walLength(MemoryStorageDirectory directory) =>
    directory.openSync(StorageEngine.walFileName).lengthSync;

void main() {
  group('background segment builder', () {
    test('builds the same entries as an inline builder', () {
      final payload = WalBatch.encode(<WalOp>[
        WalOp.put(k('a'), doc('alpha').asUint8List()),
        WalOp.put(k('b'), doc('beta').asUint8List()),
        WalOp.delete(k('c')),
      ]);
      final bytes = buildSegmentFromBatch(payload, 64 * 1024);
      final reader = SegmentReader(bytes);
      expect(textOf(reader.lookup(k('a'))?.document?.toBytes()), 'alpha');
      expect(textOf(reader.lookup(k('b'))?.document?.toBytes()), 'beta');
      expect(reader.lookup(k('c'))?.tombstone, isTrue);
    });

    test('the real isolate builder flushes and survives a reopen', () async {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(
        directory: directory,
        autoFlush: true,
        maxMemtableBytes: 8,
        backgroundSegmentBuilder: buildSegmentInBackground,
      )..openSync();

      engine.putSync(k('a'), doc('alpha'));
      engine.putSync(k('b'), doc('beta'));
      await engine.waitForMaintenance();

      expect(engine.segments, isNotEmpty);
      expect(textOf(engine.get(k('a'))), 'alpha');
      expect(textOf(engine.get(k('b'))), 'beta');
      engine.closeSync();

      final reopened = StorageEngine(directory: directory)..openSync();
      expect(textOf(reopened.get(k('a'))), 'alpha');
      expect(textOf(reopened.get(k('b'))), 'beta');
      reopened.closeSync();
    });

    test('writes that land during the build are not lost', () async {
      final directory = MemoryStorageDirectory();
      final completer = Completer<Uint8List>();
      late Uint8List snapshot;
      final engine = StorageEngine(
        directory: directory,
        autoFlush: true,
        maxMemtableBytes: 8,
        backgroundSegmentBuilder: (batch, _) {
          snapshot = batch;
          return completer.future;
        },
      )..openSync();

      engine.putSync(k('a'), doc('v1'));
      expect(engine.maintenanceScheduled, isTrue);

      // A newer write while the snapshot is being built.
      engine.putSync(k('a'), doc('v2'));
      completer.complete(buildSegmentFromBatch(snapshot, 64 * 1024));
      await engine.waitForMaintenance();

      expect(engine.segments, isNotEmpty);
      expect(walLength(directory), greaterThan(0));
      expect(textOf(engine.get(k('a'))), 'v2');
      engine.closeSync();

      final reopened = StorageEngine(directory: directory)..openSync();
      expect(textOf(reopened.get(k('a'))), 'v2');
      reopened.closeSync();
    });

    test('a synchronous flush discards the stale background result', () async {
      final directory = MemoryStorageDirectory();
      final completer = Completer<Uint8List>();
      late Uint8List snapshot;
      final engine = StorageEngine(
        directory: directory,
        autoFlush: true,
        maxMemtableBytes: 8,
        backgroundSegmentBuilder: (batch, _) {
          snapshot = batch;
          return completer.future;
        },
      )..openSync();

      engine.putSync(k('a'), doc('alpha'));
      engine.flushSync();
      final segmentsAfterFlush = engine.segments.length;

      completer.complete(buildSegmentFromBatch(snapshot, 64 * 1024));
      await engine.waitForMaintenance();

      expect(engine.segments.length, segmentsAfterFlush);
      expect(textOf(engine.get(k('a'))), 'alpha');
      engine.closeSync();
    });

    test('a quiet snapshot clears the memtable and the WAL', () async {
      final directory = MemoryStorageDirectory();
      final completer = Completer<Uint8List>();
      late Uint8List snapshot;
      final engine = StorageEngine(
        directory: directory,
        autoFlush: true,
        maxMemtableBytes: 8,
        backgroundSegmentBuilder: (batch, _) {
          snapshot = batch;
          return completer.future;
        },
      )..openSync();

      engine.putSync(k('a'), doc('alpha'));
      completer.complete(buildSegmentFromBatch(snapshot, 64 * 1024));
      await engine.waitForMaintenance();

      expect(engine.memtable.length, 0);
      expect(walLength(directory), 0);
      expect(engine.segments, hasLength(1));
      engine.closeSync();
    });

    test('the database forwards the background-flush option', () async {
      final root = await Directory.systemTemp.createTemp('velxo_bgflush_');
      final db = VelxoDatabase.openSync(
        root.path,
        maxMemtableBytes: 8,
        backgroundFlush: true,
      );
      final collection = db.collection('items');
      collection.putSync(k('a'), doc('alpha'));
      collection.putSync(k('b'), doc('beta'));
      await db.waitForMaintenance();

      expect(DocView.parse(collection.get(k('a'))!.asUint8List()).getString(1),
          'alpha');
      await db.close(flush: true);

      final reopened = VelxoDatabase.openSync(root.path);
      final reopenedCollection = reopened.collection('items');
      expect(
        DocView.parse(reopenedCollection.get(k('b'))!.asUint8List()).getString(1),
        'beta',
      );
      await reopened.close();
      root.deleteSync(recursive: true);
    });
  });
}
