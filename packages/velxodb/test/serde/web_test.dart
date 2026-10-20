@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

/// Runtime checks that only make sense in a JavaScript/Wasm engine: integer
/// semantics (Dart `int` is a JS number there), handwritten UTF-8, and the
/// multiply-based little-endian helpers.
void main() {
  test('little-endian helpers stay exact above 2^31', () {
    final buffer = Uint8List(8);
    VxsLe.w32(buffer, 0, 0xDEADBEEF);
    expect(VxsLe.u32(buffer, 0), 0xDEADBEEF);
    // 2^53-1 is the largest integer JavaScript represents exactly; anything
    // wider must travel as bytes (see the format notes).
    const maxExact = 0x001FFFFFFFFFFFFF;
    VxsLe.w64(buffer, 0, maxExact);
    expect(VxsLe.u64(buffer, 0), maxExact);
  });

  test('varints round trip up to 2^53-1', () {
    final buffer = Uint8List(16);
    // Decimal literals on purpose: on the web `1 << 53` does not mean 2^53.
    const values = <int>[
      0,
      127,
      128,
      300,
      1048576, // 2^20
      2147483648, // 2^31
      9007199254740991, // 2^53-1
    ];
    for (final value in values) {
      final length = VxsVarint.write(buffer, 0, value);
      expect(VxsVarint.decode(buffer, 0, length).value, value);
    }
    const zigzagValues = <int>[0, 1, -1, 1099511627776, -1099511627776];
    for (final value in zigzagValues) {
      expect(VxsVarint.unzigzag(VxsVarint.zigzag(value)), value);
    }
  });

  test('UTF-8 round trips in JavaScript', () {
    for (final value in <String>[
      '',
      'ascii',
      '中文消息',
      'emoji 😀 与代理对 𝄞',
      'a' * 300,
    ]) {
      final bytes = (DocBuilder()..putString(1, value)).finish();
      final view = DocView.parse(bytes.asUint8List());
      expect(view.getString(1), value);
    }
  });

  test('CRC-32C matches the standard vector', () {
    final bytes = Uint8List.fromList(ascii.encode('123456789'));
    expect(VxsCrc32c.compute(bytes), 0xE3069283);
  });

  test('document checksum verifies and detects corruption', () {
    final bytes = (DocBuilder()
          ..putString(1, '在吗')
          ..putInt(2, 1750000000000))
        .finish(checksum: true);
    final view = DocView.parseVerified(bytes.asUint8List());
    expect(view.getString(1), '在吗');
    expect(view.getInt(2), 1750000000000);
  });

  test('StringView compares without decoding', () {
    StringView view(String s) => StringView.of(
      Uint8List.fromList(utf8.encode(s)),
    );
    expect(view('abc').compareTo(view('abd')), lessThan(0));
    expect(view('中文').equalsString('中文'), isTrue);
    expect(view('中文').equalsString('中'), isFalse);
    expect(view('conversation-1').startsWithAscii('conv'), isTrue);
    expect(view('abc').hashCode, view('abc').hashCode);
  });

  test('DocSink packs documents in a browser buffer', () {
    final sink = DocSink(capacity: 64, collectOffsets: true);
    for (var i = 0; i < 20; i++) {
      sink
        ..beginDoc()
        ..putInt(1, i)
        ..putString(2, 'doc-$i')
        ..endDoc();
    }
    expect(sink.docCount, 20);
    for (var i = 0; i < 20; i++) {
      final view = DocView.parse(sink.buffer, sink.offsets[i]);
      expect(view.getInt(1), i);
      expect(view.getString(2), 'doc-$i');
    }
  });
}
