import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)
      ..putString(1, text)
      ..putInt(2, text.length))
    .finish();

void main() {
  group('StorageEngine', () {
    test('put, get, overwrite and delete', () async {
      final file = MemoryStorageFile();
      final engine = StorageEngine(walFile: file);
      await engine.open();

      await engine.put(k('a'), doc('first'));
      expect(DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1), 'first');

      await engine.put(k('a'), doc('second'));
      expect(DocView.parse(engine.get(k('a'))!.asUint8List()).getString(1), 'second');

      await engine.delete(k('a'));
      expect(engine.get(k('a')), isNull);
      expect(engine.get(k('never')), isNull);

      await engine.close();
    });

    test('recovers from the log on reopen', () async {
      final file = MemoryStorageFile();
      final first = StorageEngine(walFile: file);
      await first.open();
      await first.put(k('a'), doc('alpha'));
      await first.put(k('b'), doc('beta'));
      await first.put(k('c'), doc('gamma'));
      await first.delete(k('b'));
      await first.sync();
      final persisted = Uint8List.fromList(file.bytes);
      await first.close();

      // Reopening means a fresh handle over the same bytes.
      final reopened = MemoryStorageFile();
      await reopened.append(persisted);
      final second = StorageEngine(walFile: reopened);
      await second.open();
      expect(DocView.parse(second.get(k('a'))!.asUint8List()).getString(1), 'alpha');
      expect(second.get(k('b')), isNull);
      expect(DocView.parse(second.get(k('c'))!.asUint8List()).getString(1), 'gamma');
    });

    test('recovers a consistent prefix from a torn log', () async {
      final source = MemoryStorageFile();
      final first = StorageEngine(walFile: source);
      await first.open();
      for (var i = 0; i < 4; i++) {
        await first.put(k('k$i'), doc('v$i'));
      }
      await first.sync();
      final complete = Uint8List.fromList(source.bytes);

      for (final cut in <int>[complete.length - 1, complete.length - 7, 5]) {
        final file = MemoryStorageFile();
        await file.append(Uint8List.sublistView(complete, 0, cut));
        final engine = StorageEngine(walFile: file);
        await engine.open();
        // Whatever survived must be a prefix of the original writes.
        for (var i = 0; i < 4; i++) {
          final value = engine.get(k('k$i'));
          if (value != null) {
            expect(
              DocView.parse(value.asUint8List()).getString(1),
              'v$i',
            );
          }
        }
        // A cut that leaves at least one whole frame must recover the first write.
        if (cut >= 64) {
          expect(engine.get(k('k0')), isNotNull, reason: 'cut=$cut');
        }
      }
    });

    test('returns views that stay valid as more data arrives', () async {
      final engine = StorageEngine(
        walFile: MemoryStorageFile(),
        arenaChunkSize: 1024,
      );
      await engine.open();
      await engine.put(k('a'), doc('early'));
      final early = engine.get(k('a'))!;

      // Enough writes to roll the arena over several chunks.
      for (var i = 0; i < 50; i++) {
        await engine.put(k('bulk-$i'), doc('payload-$i'));
      }
      expect(DocView.parse(early.asUint8List()).getString(1), 'early');
    });

    test('handles documents larger than the arena chunk', () async {
      final engine = StorageEngine(
        walFile: MemoryStorageFile(),
        arenaChunkSize: 1024,
      );
      await engine.open();
      final big = 'z' * 20000;
      await engine.put(k('big'), doc(big));
      expect(DocView.parse(engine.get(k('big'))!.asUint8List()).getString(1), big);
    });

    test('tracks memory and a flush threshold', () async {
      final engine = StorageEngine(
        walFile: MemoryStorageFile(),
        maxMemtableBytes: 128,
      );
      await engine.open();
      expect(engine.shouldFlush, isFalse);
      for (var i = 0; i < 20; i++) {
        await engine.put(k('k$i'), doc('value-$i'));
      }
      expect(engine.memoryBytes, greaterThan(0));
      expect(engine.shouldFlush, isTrue);
    });

    test('sync flushes and close rejects further writes', () async {
      final file = MemoryStorageFile();
      final engine = StorageEngine(walFile: file);
      await engine.open();
      await engine.put(k('a'), doc('x'));
      await engine.sync();
      expect(file.flushCount, greaterThan(0));

      await engine.close();
      expect(() => engine.put(k('b'), doc('y')), throwsStateError);
      expect(() => engine.get(k('a')), returnsNormally);
    });
  });
}
