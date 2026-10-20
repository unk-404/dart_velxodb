import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

void main() {
  group('forward compatibility', () {
    test('unknown fields survive a read-modify-write byte for byte', () {
      // A "newer writer" produced this document: it has field 99 that the
      // "current reader" does not know about.
      final source =
          (DocBuilder(schemaId: 1, schemaVersion: 2)
                ..putString(1, 'conv-42')
                ..putInt(2, 7)
                ..putString(99, 'field from the future')
                ..putIntList(100, <int>[1, 2, 3]))
              .finish();

      final view = DocView.parse(source.asUint8List());
      final rebuilt = DocBuilder(
        schemaId: view.schemaId,
        schemaVersion: view.schemaVersion,
      );

      final cursor = view.cursor();
      while (cursor.next()) {
        switch (cursor.fieldId) {
          case 1:
            rebuilt.putString(1, view.getString(1)!);
          case 2:
            rebuilt.putInt(2, view.getInt(2)!);
          default:
            rebuilt.putRawEntry(
              cursor.fieldId,
              cursor.wireType,
              view.buffer,
              cursor.valueRawOffset,
              cursor.valueRawEnd,
            );
        }
      }

      expect(
        rebuilt.finish().asUint8List(),
        orderedEquals(source.asUint8List()),
      );
    });

    test('schema version is visible to the reader', () {
      final bytes = (DocBuilder(schemaVersion: 7)..putInt(1, 1)).finish();
      expect(DocView.parse(bytes.asUint8List()).schemaVersion, 7);
    });

    test('missing newer fields simply read as null', () {
      final older = (DocBuilder(schemaVersion: 1)..putInt(1, 1)).finish();
      final view = DocView.parse(older.asUint8List());
      expect(view.getInt(2), isNull);
      expect(view.getInt(1), 1);
    });
  });

  group('fuzz', () {
    test('random bytes either parse or raise VxsFormatException', () {
      final random = Random(0xC0FFEE);
      for (var i = 0; i < 20000; i++) {
        final length = random.nextInt(64);
        final bytes = Uint8List(length);
        for (var j = 0; j < length; j++) {
          bytes[j] = random.nextInt(256);
        }
        if (length > 0 && random.nextBool()) {
          bytes[0] = vxsMagic;
        }
        try {
          final view = DocView.parse(bytes);
          view.forEachField((cursor) {});
        } on VxsFormatException {
          // Expected for malformed input.
        } on UnsupportedError {
          // Reserved header flags.
        }
      }
    });

    test('single-byte mutations never escape as RangeError', () {
      final random = Random(7);
      final source = (DocBuilder(schemaId: 1, schemaVersion: 1)
            ..putString(1, 'hello')
            ..putInt(2, 1234)
            ..putFloat64(3, 3.5)
            ..putString(4, '中文字段'))
          .finish()
          .asUint8List();

      for (var i = 0; i < 5000; i++) {
        final mutated = Uint8List.fromList(source);
        mutated[random.nextInt(mutated.length)] = random.nextInt(256);
        try {
          final view = DocView.parse(mutated);
          view.forEachField((cursor) => cursor.intValue);
        } on VxsFormatException {
          // Expected.
        } on UnsupportedError {
          // Expected.
        }
      }
    });
  });
}
