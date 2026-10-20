import 'dart:typed_data';

/// CRC-32C (Castagnoli) used for document, block and frame integrity.
///
/// Slicing-by-8: eight lookup tables consume eight bytes per iteration, which
/// is roughly three times faster than the classic byte-at-a-time loop. That
/// matters because block checksums are computed over every payload.
///
/// Every operation is 32-bit and exact on both the VM and dart2js: `>>>`,
/// `^` and table lookups, with one sign normalisation at the end. A
/// multiply-based hash such as FNV would need 64-bit intermediates and silently
/// lose precision on the web.
abstract final class VxsCrc32c {
  /// Reflected Castagnoli polynomial.
  static const int polynomial = 0x82F63B78;

  static final List<Uint32List> _tables = _buildTables();

  /// Computes the CRC-32C of `[start, end)`.
  static int compute(Uint8List data, [int start = 0, int? end]) =>
      _finalize(_update(0xFFFFFFFF, data, start, end ?? data.length));

  /// Continues a CRC that was started by [compute] or a previous [update].
  ///
  /// [crc] must be the *finalised* value; [update] re-inverts it internally so
  /// streaming over several buffers produces the same result as one pass.
  static int update(int crc, Uint8List data, [int start = 0, int? end]) {
    final state = crc ^ 0xFFFFFFFF;
    return _finalize(
      _update(state < 0 ? state + 0x100000000 : state, data, start, end ?? data.length),
    );
  }

  static int _finalize(int state) {
    final value = state ^ 0xFFFFFFFF;
    return value < 0 ? value + 0x100000000 : value;
  }

  static int _update(int crc, Uint8List data, int start, int stop) {
    final tables = _tables;
    final t0 = tables[0];
    final t1 = tables[1];
    final t2 = tables[2];
    final t3 = tables[3];
    final t4 = tables[4];
    final t5 = tables[5];
    final t6 = tables[6];
    final t7 = tables[7];
    final t8 = tables[8];
    final t9 = tables[9];
    final t10 = tables[10];
    final t11 = tables[11];
    final t12 = tables[12];
    final t13 = tables[13];
    final t14 = tables[14];
    final t15 = tables[15];

    var i = start;
    final bulkEnd = stop - ((stop - start) & 15);
    while (i < bulkEnd) {
      final word = data[i] |
          (data[i + 1] << 8) |
          (data[i + 2] << 16) |
          (data[i + 3] << 24);
      crc ^= word;
      crc = t15[crc & 0xFF] ^
          t14[(crc >>> 8) & 0xFF] ^
          t13[(crc >>> 16) & 0xFF] ^
          t12[(crc >>> 24) & 0xFF] ^
          t11[data[i + 4]] ^
          t10[data[i + 5]] ^
          t9[data[i + 6]] ^
          t8[data[i + 7]] ^
          t7[data[i + 8]] ^
          t6[data[i + 9]] ^
          t5[data[i + 10]] ^
          t4[data[i + 11]] ^
          t3[data[i + 12]] ^
          t2[data[i + 13]] ^
          t1[data[i + 14]] ^
          t0[data[i + 15]];
      i += 16;
    }
    while (i < stop) {
      crc = t0[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
      i++;
    }
    return crc;
  }

  static List<Uint32List> _buildTables() {
    final base = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >>> 1) ^ polynomial : crc >>> 1;
      }
      base[i] = crc;
    }
    final tables = <Uint32List>[base];
    for (var k = 1; k < 16; k++) {
      final previous = tables[k - 1];
      final next = Uint32List(256);
      for (var i = 0; i < 256; i++) {
        final value = previous[i];
        next[i] = (value >>> 8) ^ base[value & 0xFF];
      }
      tables.add(next);
    }
    return tables;
  }
}
