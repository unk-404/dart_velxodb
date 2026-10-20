import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

void main() {
  DocBuilder sample({int schemaId = 1, int schemaVersion = 1}) =>
      DocBuilder(schemaId: schemaId, schemaVersion: schemaVersion)
        ..putString(1, 'conv-42')
        ..putInt(2, 7)
        ..putInt(3, 1750000000000)
        ..putString(4, '在吗？今天下午三点开会')
        ..putFloat64(5, 31.2304);

  group('document', () {
    test('round trips every field', () {
      final bytes = sample().finish();
      final view = DocView.parse(bytes.asUint8List());

      expect(view.schemaId, 1);
      expect(view.schemaVersion, 1);
      expect(view.fieldCount, 5);
      expect(view.getString(1), 'conv-42');
      expect(view.getInt(2), 7);
      expect(view.getInt(3), 1750000000000);
      expect(view.getString(4), '在吗？今天下午三点开会');
      expect(view.getFloat64(5), 31.2304);
      expect(view.byteLength, bytes.length);
    });

    test('stays compact', () {
      // Regression guard: the format must not silently grow. A 5-field chat
      // message with a 10-character CJK body should fit in well under 80 bytes.
      expect(sample().finish().length, lessThan(80));
    });

    test('is canonical', () {
      final a = sample().finish().asUint8List();
      final b = sample().finish().asUint8List();
      expect(a, orderedEquals(b));
    });

    test('absent fields read as null', () {
      final view = DocView.parse(sample().finish().asUint8List());
      expect(view.getInt(42), isNull);
      expect(view.getString(42), isNull);
      expect(view.getBytes(42), isNull);
      expect(view.has(42), isFalse);
      expect(view.has(2), isTrue);
    });

    test('empty document', () {
      final view = DocView.parse(DocBuilder().finish().asUint8List());
      expect(view.fieldCount, 0);
      expect(view.byteLength, vxsHeaderSize);
    });

    test('sparse field ids use the extended key form', () {
      final bytes = (DocBuilder()
            ..putInt(1, 1)
            ..putString(1000, 'far')
            ..putInt(60000, -3))
          .finish();
      final view = DocView.parse(bytes.asUint8List());
      expect(view.getInt(1), 1);
      expect(view.getString(1000), 'far');
      expect(view.getInt(60000), -3);
    });

    test('bodies over 64 KiB switch to the wide header', () {
      final big = 'x' * 70000;
      final bytes = (DocBuilder()..putString(1, big)).finish();
      final view = DocView.parse(bytes.asUint8List());
      expect(view.flags & vxsFlagLength32, isNot(0));
      expect(view.getString(1), big);
    });

    test('rejects fields written out of order', () {
      final builder = DocBuilder()..putInt(5, 1);
      expect(() => builder.putInt(3, 2), throwsArgumentError);
      expect(() => builder.putInt(5, 2), throwsArgumentError);
    });

    test('rejects writes after finish', () {
      final builder = DocBuilder()..putInt(1, 1);
      builder.finish();
      expect(() => builder.putInt(2, 2), throwsStateError);
      expect(builder.finish, throwsStateError);
    });

    test('reset keeps the builder usable', () {
      final builder = DocBuilder()..putInt(1, 1);
      final first = builder.finish();
      builder.reset(schemaVersion: 2);
      builder.putString(1, 'again');
      final second = builder.finish();
      expect(DocView.parse(first.asUint8List()).getInt(1), 1);
      expect(DocView.parse(second.asUint8List()).getString(1), 'again');
      expect(DocView.parse(second.asUint8List()).schemaVersion, 2);
    });
  });

  group('wire types', () {
    test('bools, floats and lists', () {
      final bytes = (DocBuilder()
            ..putBool(1, true)
            ..putBool(2, false)
            ..putFloat32(3, 1.5)
            ..putStringList(4, <String>['a', '中文'])
            ..putIntList(5, <int>[1, -2, 300]))
          .finish();
      final view = DocView.parse(bytes.asUint8List());
      expect(view.getBool(1), isTrue);
      expect(view.getBool(2), isFalse);
      expect(view.getFloat32(3), 1.5);
      expect(view.getBytes(4)!.length, greaterThan(0));
      expect(view.getBytes(5)!.length, greaterThan(0));
    });

    test('report the actual wire type on mismatch', () {
      final view = DocView.parse(
        (DocBuilder()..putString(1, 'text')).finish().asUint8List(),
      );
      expect(
        () => view.getInt(1),
        throwsA(
          isA<VxsFormatException>().having(
            (e) => e.message,
            'message',
            contains('wire type'),
          ),
        ),
      );
    });

    test('nested documents are carried verbatim', () {
      final inner = (DocBuilder(schemaId: 2)..putString(1, 'inner')).finish();
      final outer = (DocBuilder(schemaId: 1)..putDoc(1, inner)).finish();
      final view = DocView.parse(outer.asUint8List());
      final nested = DocView.parse(view.getBytes(1)!.asUint8List());
      expect(nested.schemaId, 2);
      expect(nested.getString(1), 'inner');
    });
  });

  group('utf-8', () {
    test('covers the one-byte and multi-byte length prefix paths', () {
      final values = <String>[
        '',
        'a',
        'a' * 127,
        'a' * 128,
        '中' * 42, // 126 bytes: still the one-byte prefix
        '中' * 43, // 129 bytes: fallback path
        'emoji 😀 与代理对 𝄞',
        'a' * 70000,
      ];
      for (final value in values) {
        final bytes = (DocBuilder()..putString(1, value)).finish();
        final view = DocView.parse(bytes.asUint8List());
        expect(view.getString(1), value, reason: 'length ${value.length}');
      }
    });

    test('reports the exact UTF-8 byte length', () {
      final bytes = (DocBuilder()..putString(1, '中文ab')).finish();
      // 6 bytes of CJK + 2 ASCII, one-byte length prefix, one key, 6-byte header.
      expect(bytes.length, vxsHeaderSize + 1 + 1 + 8);
    });
  });

  group('parser', () {
    test('rejects a bad magic byte', () {
      final bytes = sample().finish().asUint8List();
      bytes[0] = 0x00;
      expect(() => DocView.parse(bytes), throwsA(isA<VxsFormatException>()));
    });

    test('rejects a truncated body', () {
      final bytes = sample().finish().asUint8List();
      expect(
        () => DocView.parse(bytes, 0, bytes.length - 4),
        throwsA(isA<VxsFormatException>()),
      );
    });

    test('rejects input shorter than the header', () {
      expect(
        () => DocView.parse(sample().finish().asUint8List(), 0, 3),
        throwsA(isA<VxsFormatException>()),
      );
    });

    test('rejects reserved flag bits', () {
      final bytes = sample().finish().asUint8List();
      bytes[1] = 0x80;
      expect(() => DocView.parse(bytes), throwsA(isA<VxsFormatException>()));
    });
  });
}
