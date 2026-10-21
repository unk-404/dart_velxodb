import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, text.length))
        .finish();

StorageEngine openEngine(MemoryStorageDirectory directory) {
  final engine = StorageEngine(directory: directory);
  engine.openSync();
  return engine;
}

MemoryStorageFile walFileOf(MemoryStorageDirectory directory) =>
    directory.openSync(StorageEngine.walFileName) as MemoryStorageFile;

void main() {
  group('StorageEngine', () {
    test('put, get, overwrite and delete', () {
      final engine = openEngine(MemoryStorageDirectory());
      engine.putSync(k('a'), doc('first'));
      expect(
        DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1),
        'first',
      );

      engine.putSync(k('a'), doc('second'));
      expect(
        DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1),
        'second',
      );

      engine.deleteSync(k('a'));
      expect(engine.get(k('a')), isNull);
      expect(engine.get(k('never')), isNull);
    });

    test('flush moves data into a segment and clears the WAL', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('a'), doc('alpha'));
      engine.putSync(k('b'), doc('beta'));

      final info = engine.flushSync();
      expect(info, isNotNull);
      expect(engine.segments, hasLength(1));
      expect(engine.memtable.length, 0);
      expect(walFileOf(directory).lengthSync, 0);

      expect(
        DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1),
        'alpha',
      );
      expect(
        DocView.parse(engine.get(k('b'))!.asUint8List()).getString(1),
        'beta',
      );
    });

    test('reopens with segments and replays only the WAL tail', () {
      final directory = MemoryStorageDirectory();
      final first = openEngine(directory);
      first.putSync(k('flushed'), doc('segment'));
      first.flushSync();
      first.putSync(k('pending'), doc('wal'));
      first.syncNow();

      final second = openEngine(directory);
      expect(second.segments, hasLength(1));
      expect(
        DocView.parse(second.get(k('flushed'))!.asUint8List()).getString(1),
        'segment',
      );
      expect(
        DocView.parse(second.get(k('pending'))!.asUint8List()).getString(1),
        'wal',
      );
    });

    test('newer segments shadow older ones', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('k'), doc('v1'));
      engine.flushSync();
      engine.putSync(k('k'), doc('v2'));
      engine.flushSync();
      expect(engine.segments, hasLength(2));
      expect(
        DocView.parse(engine.get(k('k'))!.asUint8List()).getString(1),
        'v2',
      );

      final reopened = openEngine(directory);
      expect(
        DocView.parse(reopened.get(k('k'))!.asUint8List()).getString(1),
        'v2',
      );
    });

    test('tombstones survive a flush and a reopen', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('gone'), doc('x'));
      engine.flushSync();
      engine.deleteSync(k('gone'));
      engine.flushSync();

      expect(engine.get(k('gone')), isNull);
      final reopened = openEngine(directory);
      expect(reopened.get(k('gone')), isNull);
      expect(reopened.segments, hasLength(2));
    });

    test('recovers a consistent prefix from a torn WAL', () {
      final source = MemoryStorageDirectory();
      final engine = openEngine(source);
      for (var i = 0; i < 4; i++) {
        engine.putSync(k('k$i'), doc('v$i'));
      }
      engine.syncNow();
      final complete = Uint8List.fromList(
        source.openSync(StorageEngine.walFileName).readAllSync(),
      );

      for (final cut in <int>[
        complete.length - 1,
        complete.length - 7,
        5,
        64,
      ]) {
        final directory = MemoryStorageDirectory();
        directory
            .openSync(StorageEngine.walFileName)
            .writeAllSync(Uint8List.sublistView(complete, 0, cut));
        final recovered = openEngine(directory);
        for (var i = 0; i < 4; i++) {
          final value = recovered.get(k('k$i'));
          if (value != null) {
            expect(DocView.parse(value.asUint8List()).getString(1), 'v$i');
          }
        }
      }
    });

    test('falls back to the older manifest slot when the newest is torn', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('first'), doc('one'));
      engine.flushSync();
      engine.putSync(k('second'), doc('two'));
      engine.flushSync();
      expect(engine.generation, 2);

      // Generation 2 lives in slot 0; corrupt it.
      final slot = directory.openSync('MANIFEST-0') as MemoryStorageFile;
      final corrupted = Uint8List.fromList(slot.bytes);
      corrupted[corrupted.length - 1] ^= 0xFF;
      slot.writeAllSync(corrupted);

      final recovered = openEngine(directory);
      expect(recovered.generation, 1);
      expect(recovered.segments, hasLength(1));
      // The newer data is still in the WAL only if it was not flushed; here the
      // second flush happened, so its segment is unreferenced.
      expect(recovered.get(k('first')), isNotNull);
    });

    test('returns views that stay valid as more data arrives', () {
      final engine = openEngine(MemoryStorageDirectory());
      engine.putSync(k('a'), doc('early'));
      final early = engine.get(k('a'))!;
      for (var i = 0; i < 50; i++) {
        engine.putSync(k('bulk-$i'), doc('payload-$i'));
      }
      expect(DocView.parse(early.asUint8List()).getString(1), 'early');
    });

    test('handles documents larger than the arena chunk', () {
      final engine = StorageEngine(
        directory: MemoryStorageDirectory(),
        arenaChunkSize: 1024,
      )..openSync();
      final big = 'z' * 20000;
      engine.putSync(k('big'), doc(big));
      expect(
        DocView.parse(engine.get(k('big'))!.asUint8List()).getString(1),
        big,
      );
    });

    test('tracks the flush threshold', () {
      final engine = StorageEngine(
        directory: MemoryStorageDirectory(),
        maxMemtableBytes: 128,
      )..openSync();
      expect(engine.shouldFlush, isFalse);
      for (var i = 0; i < 20; i++) {
        engine.putSync(k('k$i'), doc('value-$i'));
      }
      expect(engine.shouldFlush, isTrue);
      expect(engine.maybeFlushSync(), isTrue);
      expect(engine.shouldFlush, isFalse);
      expect(engine.segments, hasLength(1));
    });

    test('compaction merges segments and drops shadowed tombstones', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('keep'), doc('v1'));
      engine.putSync(k('drop'), doc('gone'));
      engine.flushSync();
      engine.putSync(k('keep'), doc('v2'));
      engine.deleteSync(k('drop'));
      engine.flushSync();
      expect(engine.segments, hasLength(2));

      expect(engine.compactSync(), isTrue);
      expect(engine.segments, hasLength(1));
      expect(
        DocView.parse(engine.get(k('keep'))!.asUint8List()).getString(1),
        'v2',
      );
      expect(engine.get(k('drop')), isNull);

      final reopened = openEngine(directory);
      expect(reopened.segments, hasLength(1));
      expect(
        DocView.parse(reopened.get(k('keep'))!.asUint8List()).getString(1),
        'v2',
      );
      expect(reopened.get(k('drop')), isNull);
    });

    test('compaction is a no-op with fewer than two segments', () {
      final engine = openEngine(MemoryStorageDirectory());
      engine.putSync(k('a'), doc('x'));
      engine.flushSync();
      expect(engine.compactSync(), isFalse);
      expect(engine.segments, hasLength(1));
    });

    test('batch writes are atomic: a torn frame loses the whole batch', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.applyBatchSync(<WalOp>[
        WalOp.put(k('a'), doc('alpha').asUint8List()),
        WalOp.put(k('b'), doc('beta').asUint8List()),
      ]);
      engine.syncNow();
      expect(engine.get(k('a')), isNotNull);
      expect(engine.get(k('b')), isNotNull);

      final complete = Uint8List.fromList(walFileOf(directory).bytes);
      // Cut inside the frame: replay must drop it as a whole.
      final torn = MemoryStorageDirectory();
      torn
          .openSync(StorageEngine.walFileName)
          .writeAllSync(
            Uint8List.sublistView(complete, 0, complete.length - 4),
          );

      final recovered = openEngine(torn);
      expect(recovered.get(k('a')), isNull);
      expect(recovered.get(k('b')), isNull);
    });

    test('batch deletes are atomic too', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('a'), doc('alpha'));
      engine.putSync(k('b'), doc('beta'));
      engine.applyBatchSync(<WalOp>[
        WalOp.delete(k('a')),
        WalOp.delete(k('b')),
      ]);
      engine.syncNow();

      final reopened = openEngine(directory);
      expect(reopened.get(k('a')), isNull);
      expect(reopened.get(k('b')), isNull);
    });

    test('sync flushes and close rejects further writes', () async {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory);
      engine.putSync(k('a'), doc('x'));
      engine.syncNow();
      expect(walFileOf(directory).flushCount, greaterThan(0));

      await engine.close();
      expect(
        () => engine.putSync(k('b'), doc('y')),
        throwsA(isA<VelxoClosedException>()),
      );
      expect(() => engine.get(k('a')), throwsA(isA<VelxoClosedException>()));
    });
  });
}
