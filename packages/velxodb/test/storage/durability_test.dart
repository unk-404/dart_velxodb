@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)..putString(1, text)).finish();

MemoryStorageFile walFileOf(MemoryStorageDirectory directory) =>
    directory.openSync(StorageEngine.walFileName) as MemoryStorageFile;

StorageEngine openEngine(
  MemoryStorageDirectory directory, {
  required Durability durability,
}) => StorageEngine(directory: directory, durability: durability)
  ..openSync();

void main() {
  group('durability', () {
    test('always fsyncs on every single write', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory, durability: Durability.always);
      final wal = walFileOf(directory);
      final before = wal.flushCount;
      engine.putSync(k('a'), doc('alpha'));
      expect(wal.flushCount, greaterThan(before));
    });

    test('batched does not fsync on writes; sync() does', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory, durability: Durability.batched);
      final wal = walFileOf(directory);
      final before = wal.flushCount;

      engine.putSync(k('a'), doc('alpha'));
      engine.putSync(k('b'), doc('beta'));
      expect(wal.flushCount, before);

      engine.syncNow();
      expect(wal.flushCount, greaterThan(before));
    });

    test('always fsyncs once per batch, not once per operation', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory, durability: Durability.always);
      final wal = walFileOf(directory);
      final before = wal.flushCount;

      engine.putManySync(<({Uint8List key, Bytes document})>[
        for (var i = 0; i < 50; i++) (key: k('k$i'), document: doc('v$i')),
      ]);
      expect(wal.flushCount, before + 1);
    });

    test('transaction commit is one fsync for the whole group', () {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory, durability: Durability.always);
      final wal = walFileOf(directory);
      final before = wal.flushCount;

      engine.transactionSync(() {
        for (var i = 0; i < 50; i++) {
          engine.putSync(k('k$i'), doc('v$i'));
        }
      });
      expect(wal.flushCount, before + 1);
    });

    test('none leaves fsync to the caller but close still flushes', () async {
      final directory = MemoryStorageDirectory();
      final engine = openEngine(directory, durability: Durability.none);
      final wal = walFileOf(directory);
      final before = wal.flushCount;
      engine.putSync(k('a'), doc('alpha'));
      expect(wal.flushCount, before);

      await engine.close();
      expect(wal.flushCount, greaterThan(before));
    });
  });

  group('auto compaction', () {
    test('compacts when the segment count crosses the threshold', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(
        directory: directory,
        maxMemtableBytes: 1 << 20,
        autoFlush: true,
        autoCompact: true,
        compactionThreshold: 2,
      )..openSync();

      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 40; i++) {
          engine.putSync(k('k$round-$i'), doc('payload-$round-$i'));
        }
        engine.flushSync();
        expect(engine.segments.length, lessThan(2));
      }
    });

    test('does not compact below the threshold', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('a'), doc('alpha'));
      engine.flushSync();
      engine.putSync(k('b'), doc('beta'));
      engine.flushSync();
      expect(engine.segments, hasLength(2));
    });
  });
}
