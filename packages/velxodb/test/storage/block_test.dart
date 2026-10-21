import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Bytes message(int id, String text, {int schemaVersion = 1}) =>
    (DocBuilder(schemaId: 1, schemaVersion: schemaVersion)
          ..putString(1, 'id-$id')
          ..putString(2, text))
        .finish();

void main() {
  group('BlockWriter/BlockReader', () {
    test('round trips documents and relative offsets', () {
      final writer = BlockWriter(targetSize: 256);
      final offsets = <int>[];
      for (var i = 0; i < 3; i++) {
        offsets.add(writer.append(message(i, 'hello $i')));
      }
      final block = writer.finish();

      final reader = BlockReader(block.asUint8List());
      expect(reader.docCount, 3);
      expect(reader.hasChecksum, isTrue);

      final seen = <String>[];
      reader.forEach((document) => seen.add(document.getString(1)!));
      expect(seen, <String>['id-0', 'id-1', 'id-2']);

      for (var i = 0; i < 3; i++) {
        final view = reader.docAt(offsets[i]);
        expect(view.getString(1), 'id-$i');
        expect(view.getString(2), 'hello $i');
      }
    });

    test('works without a checksum', () {
      final writer = BlockWriter(checksum: false);
      writer.append(message(1, 'x'));
      final block = writer.finish();
      final reader = BlockReader(block.asUint8List());
      expect(reader.hasChecksum, isFalse);
      expect(reader.docCount, 1);
      expect(reader.payloadLength, block.length - blockHeaderSize);
    });

    test('detects payload corruption', () {
      final writer = BlockWriter()..append(message(1, 'hello world'));
      final block = Uint8List.fromList(writer.finish().asUint8List());
      block[blockHeaderSize + 12] ^= 0xFF; // inside the first document
      expect(
        () => BlockReader(block),
        throwsA(
          isA<VxsFormatException>().having(
            (e) => e.message,
            'message',
            contains('block checksum'),
          ),
        ),
      );
      // Opting out of verification still parses the block.
      expect(BlockReader(block, verifyChecksum: false).docCount, 1);
    });

    test('rejects bad headers', () {
      final good = (BlockWriter()..append(message(1, 'x')))
          .finish()
          .asUint8List();
      for (final mutate in <void Function(Uint8List)>[
        (b) => b[0] = 0,
        (b) => b[1] = 9,
        (b) => b[2] = 0x80,
        (b) => b[3] = 1,
      ]) {
        final bytes = Uint8List.fromList(good);
        mutate(bytes);
        expect(() => BlockReader(bytes), throwsA(isA<VxsFormatException>()));
      }
      expect(
        () => BlockReader(good, offset: 0, length: 2),
        throwsA(isA<VxsFormatException>()),
      );
    });

    test('empty block', () {
      final block = BlockWriter().finish();
      final reader = BlockReader(block.asUint8List());
      expect(reader.docCount, 0);
      expect(reader.payloadLength, 0);
    });

    test('docAt rejects offsets outside the payload', () {
      final block = (BlockWriter()..append(message(1, 'x'))).finish();
      final reader = BlockReader(block.asUint8List());
      expect(() => reader.docAt(-1), throwsRangeError);
      expect(() => reader.docAt(reader.payloadLength), throwsRangeError);
    });

    test('rejects writes after finish', () {
      final writer = BlockWriter()..append(message(1, 'x'));
      writer.finish();
      expect(() => writer.append(message(2, 'y')), throwsStateError);
      expect(writer.finish, throwsStateError);
    });

    test('grows past the target size for a large document', () {
      final large = 'z' * 70000;
      final writer = BlockWriter(targetSize: 1024)..append(message(1, large));
      final block = writer.finish();
      expect(block.length, greaterThan(70000));
      final reader = BlockReader(block.asUint8List());
      expect(reader.docAt(0).getString(2), large);
    });

    test('reset starts a new block and keeps the old view valid', () {
      final writer = BlockWriter()..append(message(1, 'first'));
      final first = writer.finish();
      writer.reset();
      writer.append(message(2, 'second'));
      final second = writer.finish();
      expect(BlockReader(first.asUint8List()).docAt(0).getString(1), 'id-1');
      expect(BlockReader(second.asUint8List()).docAt(0).getString(1), 'id-2');
    });
  });
}
