import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

void main() {
  group('varint', () {
    const values = <int>[
      0,
      1,
      127,
      128,
      255,
      300,
      16383,
      16384,
      1048576, // 2^20
      2147483648, // 2^31
      9007199254740991, // 2^53-1, the largest exact double integer
    ];

    test('size matches the encoded length', () {
      final buffer = Uint8List(16);
      for (final value in values) {
        expect(
          VxsVarint.write(buffer, 0, value),
          VxsVarint.size(value),
          reason: 'value $value',
        );
      }
    });

    test('round trips', () {
      final buffer = Uint8List(16);
      for (final value in values) {
        final length = VxsVarint.write(buffer, 0, value);
        final decoded = VxsVarint.decode(buffer, 0, length);
        expect(decoded.value, value, reason: 'value $value');
        expect(decoded.next, length, reason: 'value $value');
      }
    });

    test('rejects truncated input', () {
      final buffer = Uint8List.fromList(<int>[0x80, 0x80]);
      expect(
        () => VxsVarint.decode(buffer, 0, buffer.length),
        throwsA(isA<VxsFormatException>()),
      );
    });
  });

  group('zigzag', () {
    const values = <int>[
      0,
      1,
      -1,
      2,
      -2,
      63,
      -64,
      1 << 20,
      -(1 << 20),
      1 << 40,
      -(1 << 40),
    ];

    test('round trips', () {
      for (final value in values) {
        expect(
          VxsVarint.unzigzag(VxsVarint.zigzag(value)),
          value,
          reason: 'value $value',
        );
      }
    });

    test('keeps small magnitudes small', () {
      expect(VxsVarint.zigzag(-1), 1);
      expect(VxsVarint.zigzag(1), 2);
      expect(VxsVarint.zigzag(-64), 127);
    });
  });

  group('little endian helpers', () {
    test('round trips 16/32/64 bits', () {
      final buffer = Uint8List(8);
      VxsLe.w16(buffer, 0, 0xBEEF);
      expect(buffer[0], 0xEF);
      expect(buffer[1], 0xBE);
      expect(VxsLe.u16(buffer, 0), 0xBEEF);

      VxsLe.w32(buffer, 0, 0xDEADBEEF);
      expect(VxsLe.u32(buffer, 0), 0xDEADBEEF);

      // 2^53-1 compiles on dart2js too; full 64-bit range is VM-only and lives
      // in vm_int64_test.dart.
      const maxExact = 0x001FFFFFFFFFFFFF;
      VxsLe.w64(buffer, 0, maxExact);
      expect(VxsLe.u64(buffer, 0), maxExact);
    });
  });
}
