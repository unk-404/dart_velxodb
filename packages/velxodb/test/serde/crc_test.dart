import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

void main() {
  group('CRC-32C', () {
    test('matches the standard check vector', () {
      // "123456789" -> 0xE3069283 (RFC 3720 appendix B.4).
      final bytes = Uint8List.fromList(ascii.encode('123456789'));
      expect(VxsCrc32c.compute(bytes), 0xE3069283);
    });

    test('update() continues a running checksum', () {
      final whole = Uint8List.fromList(utf8.encode('velxodb 中文 checksum'));
      final first = Uint8List.sublistView(whole, 0, 10);
      final second = Uint8List.sublistView(whole, 10);

      final oneShot = VxsCrc32c.compute(whole);
      final partial = VxsCrc32c.compute(first);
      expect(VxsCrc32c.update(partial, second), oneShot);
    });

    test('empty input', () {
      expect(VxsCrc32c.compute(Uint8List(0)), 0);
    });
  });

  group('document checksum', () {
    test('round trips with a verified trailer', () {
      final bytes = (DocBuilder(schemaId: 1)
            ..putString(1, 'hello')
            ..putInt(2, 42))
          .finish(checksum: true);
      final view = DocView.parseVerified(bytes.asUint8List());
      expect(view.hasChecksum, isTrue);
      expect(view.getString(1), 'hello');
      expect(view.getInt(2), 42);
      expect(view.byteLength, bytes.length);
      expect(view.byteEnd, bytes.length);
    });

    test('detects a corrupted body', () {
      final bytes = (DocBuilder()..putString(1, 'hello')).finish(
        checksum: true,
      );
      final corrupted = Uint8List.fromList(bytes.asUint8List());
      corrupted[corrupted.length - 5] ^= 0xFF; // flip a body byte
      expect(
        () => DocView.parseVerified(corrupted),
        throwsA(
          isA<VxsFormatException>().having(
            (e) => e.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );
      // Skipping verification still parses; the bytes just decode to garbage.
      expect(DocView.parse(corrupted).getBytes(1), isNotNull);
    });

    test('a missing trailer is rejected', () {
      final bytes = (DocBuilder()..putInt(1, 1)).finish(checksum: true);
      expect(
        () => DocView.parse(bytes.asUint8List(), 0, bytes.length - 2),
        throwsA(isA<VxsFormatException>()),
      );
    });

    test('sink offsets account for the trailer', () {
      final sink = DocSink(capacity: 128, collectOffsets: true);
      for (var i = 0; i < 5; i++) {
        sink
          ..beginDoc()
          ..putInt(1, i)
          ..endDoc(checksum: i.isEven);
      }
      for (var i = 0; i < 5; i++) {
        final view = DocView.parseVerified(sink.buffer, sink.offsets[i]);
        expect(view.getInt(1), i);
        expect(view.hasChecksum, i.isEven);
      }
    });
  });
}
