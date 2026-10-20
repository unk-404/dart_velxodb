import 'dart:convert';
import 'dart:typed_data';

import 'crc32c.dart';

/// A zero-copy view over UTF-8 bytes.
///
/// Index keys, bloom probes and range comparisons all need to compare and hash
/// text without materialising a `String`. Comparisons use the UTF-8 byte order,
/// which is identical to code-point order, so sorting a `StringView` and sorting
/// the decoded strings agree.
final class StringView implements Comparable<StringView> {
  /// Creates a view over `bytes[start, end)`.
  const StringView(this.bytes, this.start, this.end);

  /// Creates a view over the whole buffer.
  factory StringView.of(Uint8List bytes) => StringView(bytes, 0, bytes.length);

  /// Backing bytes; must not be mutated while the view is used as a key.
  final Uint8List bytes;

  /// First byte of the view.
  final int start;

  /// Offset one past the last byte of the view.
  final int end;

  /// Length in bytes (not code units).
  int get byteLength => end - start;

  /// Whether the view is empty.
  bool get isEmpty => end == start;

  /// Whether the view is non-empty.
  bool get isNotEmpty => end != start;

  /// Compares two UTF-8 byte ranges lexicographically.
  static int compareRanges(
    Uint8List a,
    int aStart,
    int aEnd,
    Uint8List b,
    int bStart,
    int bEnd,
  ) {
    final aLength = aEnd - aStart;
    final bLength = bEnd - bStart;
    var i = 0;
    while (i < aLength && i < bLength) {
      final diff = a[aStart + i] - b[bStart + i];
      if (diff != 0) return diff;
      i++;
    }
    return aLength - bLength;
  }

  /// Lexicographic comparison with another view.
  @override
  int compareTo(StringView other) =>
      compareRanges(bytes, start, end, other.bytes, other.start, other.end);

  /// Byte equality with another range.
  bool equalsRange(Uint8List other, int otherStart, int otherEnd) {
    final length = end - start;
    if (length != otherEnd - otherStart) return false;
    for (var i = 0; i < length; i++) {
      if (bytes[start + i] != other[otherStart + i]) return false;
    }
    return true;
  }

  /// Whether this view starts with [prefix].
  bool startsWith(StringView prefix) {
    final prefixLength = prefix.byteLength;
    if (prefixLength > byteLength) return false;
    for (var i = 0; i < prefixLength; i++) {
      if (bytes[start + i] != prefix.bytes[prefix.start + i]) return false;
    }
    return true;
  }

  /// Whether this view starts with the UTF-8 encoding of [prefix].
  ///
  /// Only valid for ASCII prefixes; non-ASCII comparisons go through
  /// [equalsString] or a [StringView] of encoded bytes.
  bool startsWithAscii(String prefix) {
    if (prefix.length > byteLength) return false;
    for (var i = 0; i < prefix.length; i++) {
      final unit = prefix.codeUnitAt(i);
      if (unit > 0x7F || bytes[start + i] != unit) return false;
    }
    return true;
  }

  /// Compares against a decoded string without allocating one.
  ///
  /// Returns a negative number, zero or a positive number following the same
  /// ordering as [compareTo].
  int compareToString(String other) {
    var i = start;
    var j = 0;
    while (i < end && j < other.length) {
      final unit = other.codeUnitAt(j);
      final (rune, bytesUsed) = _runeAt(bytes, i, end);
      if (rune < 0) return 1; // malformed bytes sort after valid text
      final otherRune = unit >= 0xD800 && unit <= 0xDBFF
          ? 0x10000 +
                ((unit - 0xD800) << 10) +
                (other.codeUnitAt(j + 1) - 0xDC00)
          : unit;
      final diff = rune - otherRune;
      if (diff != 0) return diff;
      i += bytesUsed;
      j += otherRune > 0xFFFF ? 2 : 1;
    }
    return (end - i) - (other.length - j);
  }

  /// Whether the decoded text equals [other], without allocating.
  bool equalsString(String other) {
    var i = start;
    var j = 0;
    while (i < end && j < other.length) {
      final unit = other.codeUnitAt(j);
      if (unit < 0x80) {
        if (bytes[i] != unit) return false;
        i++;
        j++;
        continue;
      }
      final (rune, bytesUsed) = _runeAt(bytes, i, end);
      if (rune < 0) return false;
      final otherRune = unit >= 0xD800 && unit <= 0xDBFF
          ? 0x10000 +
                ((unit - 0xD800) << 10) +
                (other.codeUnitAt(j + 1) - 0xDC00)
          : unit;
      if (rune != otherRune) return false;
      i += bytesUsed;
      j += otherRune > 0xFFFF ? 2 : 1;
    }
    return i == end && j == other.length;
  }

  /// Hash of the raw bytes. Used for index buckets and hash tables.
  @override
  int get hashCode => VxsCrc32c.compute(bytes, start, end);

  @override
  bool operator ==(Object other) =>
      other is StringView && equalsRange(other.bytes, other.start, other.end);

  /// Decodes to a `String`. Allocates; prefer the view when you can.
  @override
  String toString() => utf8.decode(Uint8List.sublistView(bytes, start, end));

  /// Decodes a UTF-8 scalar at [i]; returns `(-1, 0)` when malformed.
  static (int, int) _runeAt(Uint8List b, int i, int end) {
    final b0 = b[i];
    if (b0 < 0x80) return (b0, 1);
    if (b0 < 0xC2) return (-1, 0);
    if (b0 < 0xE0) {
      if (i + 1 >= end) return (-1, 0);
      final b1 = b[i + 1];
      if (b1 & 0xC0 != 0x80) return (-1, 0);
      return (((b0 & 0x1F) << 6) | (b1 & 0x3F), 2);
    }
    if (b0 < 0xF0) {
      if (i + 2 >= end) return (-1, 0);
      final b1 = b[i + 1];
      final b2 = b[i + 2];
      if (b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80) return (-1, 0);
      return (((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F), 3);
    }
    if (b0 < 0xF5) {
      if (i + 3 >= end) return (-1, 0);
      final b1 = b[i + 1];
      final b2 = b[i + 2];
      final b3 = b[i + 3];
      if (b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80 || b3 & 0xC0 != 0x80) {
        return (-1, 0);
      }
      return (
        ((b0 & 0x07) << 18) |
            ((b1 & 0x3F) << 12) |
            ((b2 & 0x3F) << 6) |
            (b3 & 0x3F),
        4,
      );
    }
    return (-1, 0);
  }
}
