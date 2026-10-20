import 'dart:typed_data';

/// Thrown when a byte range is not a valid [VXS] document.
///
/// A dedicated type matters: the parser is called on untrusted bytes, so
/// "this is corrupt" must be distinguishable from a programming error.
final class VxsFormatException implements Exception {
  /// Creates the exception.
  const VxsFormatException(this.message, {this.offset});

  /// Human readable reason.
  final String message;

  /// Byte offset where the problem was detected, when known.
  final int? offset;

  @override
  String toString() => offset == null
      ? 'VxsFormatException: $message'
      : 'VxsFormatException: $message (at byte $offset)';
}

/// VXS wire types. The low two bits of every field key carry one of these.
abstract final class VxsWire {
  /// Unsigned LEB128 varint (signed values are zigzag-encoded).
  static const int varint = 0;

  /// Four raw little-endian bytes (float32).
  static const int fixed32 = 1;

  /// Eight raw little-endian bytes (float64).
  static const int fixed64 = 2;

  /// `varint(length)` followed by `length` payload bytes.
  static const int lengthDelimited = 3;
}

/// First byte of every document: ASCII 'V'.
const int vxsMagic = 0x56;

/// Body length is a `u32` instead of a `u16` (header grows from 6 to 8 bytes).
const int vxsFlagLength32 = 0x01;

/// A CRC32C trailer follows the body. Reserved; not emitted in v1.
const int vxsFlagCrc32c = 0x02;

/// Offset of the body when the small header is used.
const int vxsHeaderSize = 6;

/// Offset of the body when [vxsFlagLength32] is set.
const int vxsHeaderSizeLarge = 8;

/// Largest body that fits the small header.
const int vxsMaxSmallBody = 0xFFFF;

/// Largest field-id delta that fits in a single key byte.
const int vxsMaxInlineDelta = 62;

/// Delta encoded by the extended key form; the remainder is a varint.
const int vxsExtendedDeltaBase = 63;

/// Reserved in v1; must be zero on read.
const int vxsReservedFlags = ~0x03 & 0xFF;

/// Unaligned little-endian access.
///
/// Written with multiplication rather than `<<`/`|` on purpose: dart2js
/// truncates bitwise operators to 32 bits, and document fields routinely
/// exceed that (millisecond timestamps need 41 bits).
abstract final class VxsLe {
  /// Reads an unsigned 16-bit little-endian integer.
  static int u16(Uint8List b, int o) => b[o] + b[o + 1] * 0x100;

  /// Reads an unsigned 32-bit little-endian integer.
  static int u32(Uint8List b, int o) =>
      b[o] + b[o + 1] * 0x100 + b[o + 2] * 0x10000 + b[o + 3] * 0x1000000;

  /// Reads an unsigned 64-bit little-endian integer.
  ///
  /// On the web this is exact only up to 2^53, like every Dart `int` there.
  static int u64(Uint8List b, int o) =>
      u32(b, o) + u32(b, o + 4) * 0x100000000;

  /// Writes an unsigned 16-bit little-endian integer.
  static void w16(Uint8List b, int o, int v) {
    b[o] = v % 0x100;
    b[o + 1] = (v ~/ 0x100) % 0x100;
  }

  /// Writes an unsigned 32-bit little-endian integer.
  static void w32(Uint8List b, int o, int v) {
    b[o] = v % 0x100;
    b[o + 1] = (v ~/ 0x100) % 0x100;
    b[o + 2] = (v ~/ 0x10000) % 0x100;
    b[o + 3] = (v ~/ 0x1000000) % 0x100;
  }

  /// Writes an unsigned 64-bit little-endian integer.
  static void w64(Uint8List b, int o, int v) {
    w32(b, o, v % 0x100000000);
    w32(b, o + 4, v ~/ 0x100000000);
  }
}

/// Unsigned LEB128 varints plus the zigzag transform for signed values.
abstract final class VxsVarint {
  /// Number of bytes [value] occupies when written.
  static int size(int value) {
    var v = value;
    var n = 1;
    while (v >= 0x80) {
      v ~/= 0x80;
      n++;
    }
    return n;
  }

  /// Writes [value] at [offset] and returns the number of bytes written.
  static int write(Uint8List out, int offset, int value) {
    var v = value;
    var i = offset;
    while (v >= 0x80) {
      out[i++] = (v % 0x80) | 0x80;
      v ~/= 0x80;
    }
    out[i++] = v;
    return i - offset;
  }

  /// Reads a varint starting at [offset], not reading at or past [end].
  static ({int value, int next}) decode(
    Uint8List src,
    int offset,
    int end,
  ) {
    var result = 0;
    var multiplier = 1;
    var i = offset;
    for (var count = 0; count < 10; count++) {
      if (i >= end) {
        throw VxsFormatException('truncated varint', offset: offset);
      }
      final byte = src[i++];
      result += (byte & 0x7F) * multiplier;
      if (byte < 0x80) return (value: result, next: i);
      multiplier *= 0x80;
    }
    throw VxsFormatException('varint longer than 10 bytes', offset: offset);
  }

  /// Maps a signed integer onto an unsigned one, keeping small magnitudes small.
  static int zigzag(int value) => value < 0 ? -2 * value - 1 : 2 * value;

  /// Inverse of [zigzag].
  static int unzigzag(int value) {
    final half = value ~/ 2;
    return value % 2 == 0 ? half : -half - 1;
  }
}
