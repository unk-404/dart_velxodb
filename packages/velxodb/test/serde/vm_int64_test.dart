@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

/// Checks that only make sense on the VM, where `int` is a full 64-bit value.
void main() {
  test('u64 helpers cover the full 64-bit range', () {
    final buffer = Uint8List(8);
    const value = 0x0123456789ABCDEF;
    VxsLe.w64(buffer, 0, value);
    expect(VxsLe.u64(buffer, 0), value);
  });

  test('varints cover the full 64-bit range', () {
    final buffer = Uint8List(16);
    for (final value in <int>[
      9007199254740991, // 2^53-1
      1 << 60,
      0x7FFFFFFFFFFFFFFF,
    ]) {
      final length = VxsVarint.write(buffer, 0, value);
      final decoded = VxsVarint.decode(buffer, 0, length);
      expect(decoded.value, value);
      expect(decoded.next, length);
    }
  });

  test('zigzag covers large magnitudes', () {
    // 2^61 is the largest power of two whose zigzag form still fits int64.
    for (final value in <int>[-(1 << 61), 1 << 61]) {
      expect(VxsVarint.unzigzag(VxsVarint.zigzag(value)), value);
    }
  });
}
