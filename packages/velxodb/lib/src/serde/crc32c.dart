import 'dart:typed_data';

/// CRC-32C (Castagnoli) used for document integrity and key hashing.
///
/// The implementation is table-driven and only uses 32-bit operations that are
/// exact on both the VM and dart2js: `>>>` (unsigned shift) and `^`, with a
/// single sign normalisation at the end. A multiply-based hash such as FNV
/// would need 64-bit intermediates and silently lose precision on the web.
abstract final class VxsCrc32c {
  /// Reflected Castagnoli polynomial.
  static const int polynomial = 0x82F63B78;

  /// Lookup table, built once per isolate.
  static final Uint32List table = _buildTable();

  /// Computes the CRC-32C of `[start, end)`.
  static int compute(Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    final lookup = table;
    var crc = 0xFFFFFFFF;
    for (var i = start; i < stop; i++) {
      crc = lookup[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    crc ^= 0xFFFFFFFF;
    // dart2js keeps the sign bit, the VM does not; normalise to 0..2^32-1.
    return crc < 0 ? crc + 0x100000000 : crc;
  }

  /// Continues a CRC that was started by [compute] or a previous [update].
  ///
  /// [crc] must be the *finalised* value; [update] re-inverts it internally so
  /// streaming over several buffers produces the same result as one pass.
  static int update(int crc, Uint8List data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    final lookup = table;
    var state = (crc ^ 0xFFFFFFFF);
    if (state < 0) state += 0x100000000;
    for (var i = start; i < stop; i++) {
      state = lookup[(state ^ data[i]) & 0xFF] ^ (state >>> 8);
    }
    final out = state ^ 0xFFFFFFFF;
    return out < 0 ? out + 0x100000000 : out;
  }

  static Uint32List _buildTable() {
    final result = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >>> 1) ^ polynomial : crc >>> 1;
      }
      result[i] = crc;
    }
    return result;
  }
}
