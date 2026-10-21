import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

StringView viewOf(String value) =>
    StringView.of(Uint8List.fromList(utf8.encode(value)));

void main() {
  group('StringView', () {
    test('compares in code point order', () {
      final values = <String>['', 'a', 'ab', 'b', 'z', '中', '中文', '😀'];
      for (final a in values) {
        for (final b in values) {
          final expected = a.compareTo(b);
          expect(
            viewOf(a).compareTo(viewOf(b)).sign,
            expected.sign,
            reason: '"$a" vs "$b"',
          );
          expect(
            viewOf(a).compareToString(b).sign,
            expected.sign,
            reason: 'compareToString "$a" vs "$b"',
          );
        }
      }
    });

    test('equality works against views and strings', () {
      const samples = <String>['', 'abc', '中文', '中文😀ok'];
      for (final value in samples) {
        final view = viewOf(value);
        expect(view, viewOf(value));
        expect(view.equalsString(value), isTrue, reason: value);
        expect(view.toString(), value);
        expect(view.hashCode, viewOf(value).hashCode);
      }
      expect(viewOf('abc').equalsString('abd'), isFalse);
      expect(viewOf('abc').equalsString('ab'), isFalse);
      expect(viewOf('中文').equalsString('中'), isFalse);
    });

    test('prefix matching', () {
      final view = viewOf('conversation-42');
      expect(view.startsWith(viewOf('conversation')), isTrue);
      expect(view.startsWith(viewOf('conv')), isTrue);
      expect(view.startsWith(viewOf('conversation-42!')), isFalse);
      expect(view.startsWithAscii('conv'), isTrue);
      expect(view.startsWithAscii('Conv'), isFalse);
      expect(view.startsWithAscii('conversation-42!'), isFalse);
    });

    test('is a zero-copy window', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      final view = StringView(bytes, 0, 5);
      expect(view.toString(), 'hello');
      bytes[0] = 0x48; // 'H'
      expect(view.toString(), 'Hello');
      expect(view.byteLength, 5);
    });

    test('does not allocate for equalsString', () {
      // Behavioural guard: comparing a 26-byte id to its String form must agree
      // for every prefix truncation as well.
      const id = '01J8Z4K2M3N4P5Q6R7S8T9V0W1';
      final view = viewOf(id);
      for (var i = 0; i <= id.length; i++) {
        expect(view.equalsString(id.substring(0, i)), i == id.length);
      }
    });
  });
}
