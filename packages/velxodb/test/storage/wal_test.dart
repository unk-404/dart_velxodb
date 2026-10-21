import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List key(String value) => Uint8List.fromList(value.codeUnits);

void main() {
  group('WalBatch', () {
    test('round trips puts and deletes', () {
      final ops = <WalOp>[
        WalOp.put(key('a'), Uint8List.fromList(<int>[1, 2, 3])),
        WalOp.delete(key('b')),
        WalOp.put(key('c'), Uint8List(0)),
      ];
      final payload = WalBatch.encode(ops);

      final seen = <String>[];
      WalBatch.decode(payload, (kind, k, v) {
        seen.add('${kind.name}:${String.fromCharCodes(k)}:${v?.length ?? -1}');
      });
      expect(seen, <String>['put:a:3', 'delete:b:-1', 'put:c:0']);
    });

    test('handles an empty batch', () {
      final payload = WalBatch.encode(<WalOp>[]);
      var count = 0;
      WalBatch.decode(payload, (_, _, _) => count++);
      expect(count, 0);
    });

    test('grows for large keys and values', () {
      final bigKey = Uint8List(300)..fillRange(0, 300, 7);
      final bigValue = Uint8List(4096)..fillRange(0, 4096, 9);
      final payload = WalBatch.encode(<WalOp>[
        WalOp.put(bigKey, bigValue),
        WalOp.delete(bigKey),
      ]);

      final lengths = <int>[];
      WalBatch.decode(payload, (kind, k, v) {
        expect(k.length, 300);
        lengths.add(v?.length ?? -1);
      });
      expect(lengths, <int>[4096, -1]);
    });

    test('rejects malformed payloads', () {
      expect(
        () => WalBatch.decode(Uint8List(0), (_, _, _) {}),
        throwsA(isA<VxsFormatException>()),
      );
      final payload = WalBatch.encode(<WalOp>[
        WalOp.put(key('abc'), Uint8List.fromList(<int>[1])),
      ]);
      // Truncate the value.
      expect(
        () => WalBatch.decode(
          Uint8List.sublistView(payload, 0, payload.length - 1),
          (_, _, _) {},
        ),
        throwsA(isA<VxsFormatException>()),
      );
      // Unknown op code.
      final unknown = Uint8List.fromList(<int>[1, 9, 1, 65, 0]);
      expect(
        () => WalBatch.decode(unknown, (_, _, _) {}),
        throwsA(isA<VxsFormatException>()),
      );
    });
  });

  group('Wal', () {
    test('appends and replays in order', () async {
      final file = MemoryStorageFile();
      final wal = Wal(file);
      for (var i = 0; i < 5; i++) {
        await wal.appendBatch(<WalOp>[WalOp.put(key('k$i'), key('v$i'))]);
      }
      expect(await file.length, greaterThan(0));

      final replayed = <String>[];
      final valid = await Wal(file).replay((payload) {
        WalBatch.decode(payload, (kind, k, v) {
          replayed.add(
            '${String.fromCharCodes(k)}=${String.fromCharCodes(v!)}',
          );
        });
      });
      expect(replayed, <String>['k0=v0', 'k1=v1', 'k2=v2', 'k3=v3', 'k4=v4']);
      expect(valid, await file.length);
    });

    test('drops a torn tail and truncates the file', () async {
      final source = MemoryStorageFile();
      final wal = Wal(source);
      await wal.appendBatch(<WalOp>[WalOp.put(key('a'), key('1'))]);
      await wal.appendBatch(<WalOp>[WalOp.put(key('b'), key('2'))]);
      final complete = Uint8List.fromList(source.bytes);

      // Cut in the middle of the second frame.
      final cut = complete.length - 3;
      final file = MemoryStorageFile();
      await file.append(Uint8List.sublistView(complete, 0, cut));

      final applied = <String>[];
      final valid = await Wal(file).replay((payload) {
        WalBatch.decode(
          payload,
          (_, k, _) => applied.add(String.fromCharCodes(k)),
        );
      });
      expect(applied, <String>['a']);
      expect(valid, lessThan(cut));
      expect(await file.length, valid);

      // The log is usable again after truncation.
      await Wal(file).appendBatch(<WalOp>[WalOp.put(key('c'), key('3'))]);
      final again = <String>[];
      await Wal(file).replay((payload) {
        WalBatch.decode(
          payload,
          (_, k, _) => again.add(String.fromCharCodes(k)),
        );
      });
      expect(again, <String>['a', 'c']);
    });

    test('stops at a corrupted checksum', () async {
      final payloads = <Uint8List>[
        for (var i = 0; i < 3; i++)
          WalBatch.encode(<WalOp>[WalOp.put(key('k$i'), key('v'))]),
      ];
      final frames = payloads.map(WalFrame.encode).toList();
      final firstFrameLength = frames.first.length;
      final bytes = Uint8List.fromList(<int>[
        for (final frame in frames) ...frame,
      ]);
      // Flip one payload byte of the second frame; its checksum no longer holds.
      bytes[firstFrameLength + walHeaderSize + 1] ^= 0xFF;

      final file = MemoryStorageFile();
      await file.append(bytes);
      final applied = <String>[];
      final valid = await Wal(file).replay((payload) {
        WalBatch.decode(
          payload,
          (_, k, _) => applied.add(String.fromCharCodes(k)),
        );
      });
      expect(applied, <String>['k0']);
      expect(valid, firstFrameLength);
      expect(await file.length, firstFrameLength);
    });

    test('every prefix of the log replays a consistent prefix', () async {
      final ops = <WalOp>[
        for (var i = 0; i < 4; i++) WalOp.put(key('k$i'), key('v$i')),
      ];
      final source = MemoryStorageFile();
      final wal = Wal(source);
      for (final op in ops) {
        await wal.appendBatch(<WalOp>[op]);
      }
      final complete = Uint8List.fromList(source.bytes);

      for (var cut = 0; cut <= complete.length; cut++) {
        final file = MemoryStorageFile();
        await file.append(Uint8List.sublistView(complete, 0, cut));
        final applied = <String>[];
        final valid = await Wal(file).replay((payload) {
          WalBatch.decode(
            payload,
            (_, k, _) => applied.add(String.fromCharCodes(k)),
          );
        });

        expect(await file.length, valid, reason: 'cut=$cut');
        expect(
          applied.length,
          lessThanOrEqualTo(ops.length),
          reason: 'cut=$cut',
        );
        for (var i = 0; i < applied.length; i++) {
          expect(
            applied[i],
            String.fromCharCodes(ops[i].key),
            reason: 'cut=$cut, index $i',
          );
        }
        // A cut inside the last frame must lose exactly that frame.
        if (cut == complete.length) {
          expect(applied, hasLength(ops.length), reason: 'full log');
        }
      }
    });

    test('sync flushes the file', () async {
      final file = MemoryStorageFile();
      await Wal(file).sync();
      expect(file.flushCount, 1);
    });
  });
}
