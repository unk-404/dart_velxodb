import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

void main() {
  group('MemTable', () {
    test('stores, replaces and tombstones', () {
      final table = MemTable();
      table.put(k('a'), 0, 10, 5);
      expect(table.get(k('a')), (chunk: 0, offset: 10, length: 5));

      table.put(k('a'), 1, 20, 7);
      expect(table.get(k('a')), (chunk: 1, offset: 20, length: 7));

      table.putTombstone(k('b'));
      expect(table.get(k('b'))!.length, -1);
      expect(table.contains(k('b')), isTrue);

      expect(table.get(k('missing')), isNull);
      expect(table.length, 2);
    });

    test('survives rehashing with many keys', () {
      final table = MemTable(initialEntries: 4);
      const count = 5000;
      for (var i = 0; i < count; i++) {
        table.put(k('key-$i'), i, i * 2, 16);
      }
      expect(table.length, count);
      for (var i = 0; i < count; i++) {
        final ref = table.get(k('key-$i'));
        expect(ref, isNotNull, reason: 'key-$i');
        expect(ref!.chunk, i);
        expect(ref.offset, i * 2);
      }
      // Overwrite every key; no duplicates may appear.
      for (var i = 0; i < count; i++) {
        table.put(k('key-$i'), 0, i, 8);
      }
      expect(table.length, count);
      expect(table.get(k('key-42'))!.offset, 42);
    });

    test('iterates in insertion order with zero-copy keys', () {
      final table = MemTable()
        ..put(k('x'), 3, 1, 2)
        ..put(k('y'), 4, 5, 6);
      final seen = <String>[];
      table.forEach((key, chunk, offset, length) {
        seen.add('${String.fromCharCodes(key)}:$chunk:$offset:$length');
      });
      expect(seen, <String>['x:3:1:2', 'y:4:5:6']);
      expect(String.fromCharCodes(table.keyAt(1)), 'y');
      expect(table.refAt(0), (chunk: 3, offset: 1, length: 2));
    });

    test('clear keeps the table usable', () {
      final table = MemTable()
        ..put(k('a'), 0, 0, 1)
        ..clear();
      expect(table.length, 0);
      expect(table.get(k('a')), isNull);
      table.put(k('b'), 0, 0, 1);
      expect(table.get(k('b')), isNotNull);
    });
  });

  group('DocArena', () {
    test('rolls over chunks and keeps views stable', () {
      final arena = DocArena(chunkSize: 64);
      final first = arena.append(Uint8List(40)..fillRange(0, 40, 1));
      final second = arena.append(Uint8List(40)..fillRange(0, 40, 2));

      expect(first.chunk, 0);
      expect(second.chunk, 1, reason: 'second append must start a new chunk');
      expect(arena.chunkCount, 2);

      final firstView = arena.view(first.chunk, first.offset, first.length);
      expect(firstView.asUint8List().every((b) => b == 1), isTrue);
    });

    test('oversized documents get their own chunk', () {
      final arena = DocArena(chunkSize: 64);
      final ref = arena.append(Uint8List(200)..fillRange(0, 200, 7));
      expect(ref.offset, 0);
      expect(arena.view(ref.chunk, 0, 200).length, 200);
      // A following normal append must not corrupt the oversized chunk.
      final next = arena.append(Uint8List(10));
      expect(next.chunk, greaterThan(ref.chunk));
    });
  });
}
