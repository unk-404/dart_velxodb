import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/vxs.dart';

/// Bloom filter used to skip segments that cannot contain a key.
///
/// Ten bits per key with seven probes gives roughly a 1% false-positive rate.
/// The serialized form is `[u32 bitCount][u8 hashCount][bits]`, little-endian.
///
/// Probes use double hashing over CRC-32C: `h1 + i * h2`. Both are 32-bit, and
/// the intermediate `i * h2` stays below 2^35, so this is exact on dart2js.
final class BloomFilter {
  /// Builds a filter over [keys].
  factory BloomFilter.build(
    Iterable<Uint8List> keys, {
    int bitsPerKey = 10,
    int minBits = 64,
    int hashCount = 7,
  }) {
    var count = 0;
    for (final _ in keys) {
      count++;
    }
    var bits = count * bitsPerKey;
    if (bits < minBits) bits = minBits;
    // Keep the bit count a multiple of 8 so the byte length is exact.
    bits = (bits + 7) & ~7;
    final filter = BloomFilter._(Uint8List(bits ~/ 8), hashCount);
    for (final key in keys) {
      filter.add(key);
    }
    return filter;
  }

  /// Wraps existing bits.
  BloomFilter._(this.bits, this.hashCount)
    : bitCount = bits.length * 8;

  /// Backing bits.
  final Uint8List bits;

  /// Number of probes per key.
  final int hashCount;

  /// Total number of bits.
  final int bitCount;

  /// Serialized size in bytes.
  int get byteLength => 4 + 1 + bits.length;

  /// Adds [key] to the filter.
  void add(Uint8List key) {
    final h1 = VxsCrc32c.compute(key);
    final h2 = ((h1 >>> 16) ^ (h1 & 0xFFFF)) | 1;
    for (var i = 0; i < hashCount; i++) {
      final bit = (h1 + i * h2) % bitCount;
      bits[bit >> 3] |= 1 << (bit & 7);
    }
  }

  /// Whether [key] may be present. False positives are possible; false
  /// negatives are not.
  bool mightContain(Uint8List key) {
    final h1 = VxsCrc32c.compute(key);
    final h2 = ((h1 >>> 16) ^ (h1 & 0xFFFF)) | 1;
    for (var i = 0; i < hashCount; i++) {
      final bit = (h1 + i * h2) % bitCount;
      if (bits[bit >> 3] & (1 << (bit & 7)) == 0) return false;
    }
    return true;
  }

  /// Serializes the filter to a new buffer.
  Uint8List toBytes() {
    final out = Uint8List(byteLength);
    VxsLe.w32(out, 0, bitCount);
    out[4] = hashCount;
    out.setRange(5, out.length, bits);
    return out;
  }

  /// Parses a filter starting at [offset]; [next] reports the end offset.
  static ({BloomFilter filter, int next}) parse(
    Uint8List source, [
    int offset = 0,
  ]) {
    if (offset + 5 > source.length) {
      throw VxsFormatException('bloom filter header truncated', offset: offset);
    }
    final bitCount = VxsLe.u32(source, offset);
    final hashCount = source[offset + 4];
    final byteLength = (bitCount + 7) >> 3;
    final start = offset + 5;
    final end = start + byteLength;
    if (bitCount == 0 || end > source.length) {
      throw VxsFormatException('bloom filter is truncated', offset: offset);
    }
    if (hashCount == 0 || hashCount > 32) {
      throw VxsFormatException(
        'invalid bloom probe count $hashCount',
        offset: offset + 4,
      );
    }
    return (
      filter: BloomFilter._(
        Uint8List.sublistView(source, start, end),
        hashCount,
      ),
      next: end,
    );
  }
}
