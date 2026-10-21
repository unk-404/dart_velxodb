import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/crc32c.dart';
import '../serde/view.dart';
import '../serde/vxs.dart';

/// First byte of a block.
const int blockMagic = 0x42;

/// Block format version understood by this implementation.
const int blockVersion = 1;

/// The block carries a CRC-32C trailer.
const int blockFlagCrc32c = 0x01;

/// Header size of a block.
const int blockHeaderSize = 4;

/// Packs VXS documents into self-delimiting blocks.
///
/// A block has no document directory on purpose: documents are self-delimiting,
/// and the segment index gives the absolute offset of every document. A
/// directory would cost four bytes per document (3% of a 130-byte message).
final class BlockWriter {
  /// Creates a writer that targets [targetSize] bytes per block.
  BlockWriter({int targetSize = 64 * 1024, this.checksum = true})
    : _targetSize = targetSize,
      _buffer = Uint8List(targetSize < 256 ? 256 : targetSize);

  /// Whether a CRC-32C trailer is written.
  final bool checksum;

  final int _targetSize;
  Uint8List _buffer;
  int _pos = blockHeaderSize;
  int _count = 0;
  bool _finished = false;

  /// Number of documents appended.
  int get docCount => _count;

  /// Bytes that will be produced, including header and trailer.
  int get length => _pos + (checksum ? 4 : 0);

  /// Whether the target size has been reached; callers typically flush now.
  bool get isFull => length >= _targetSize;

  /// Whether nothing has been appended.
  bool get isEmpty => _count == 0;

  /// Appends one encoded document and returns its offset inside the payload.
  int append(Bytes doc) {
    if (_finished) throw StateError('block already finished');
    final size = doc.length;
    _ensure(_pos + size);
    _buffer.setRange(_pos, _pos + size, doc.asUint8List());
    final relative = _pos - blockHeaderSize;
    _pos += size;
    _count++;
    return relative;
  }

  /// Writes the header and optional checksum, returning the finished block.
  ///
  /// The returned view shares the writer's buffer; [reset] allocates a new one.
  Bytes finish() {
    if (_finished) throw StateError('finish() has already been called');
    _finished = true;
    _buffer[0] = blockMagic;
    _buffer[1] = blockVersion;
    _buffer[2] = checksum ? blockFlagCrc32c : 0;
    _buffer[3] = 0;
    if (checksum) {
      _ensure(_pos + 4);
      final crc = VxsCrc32c.compute(_buffer, blockHeaderSize, _pos);
      VxsLe.w32(_buffer, _pos, crc);
      _pos += 4;
    }
    return Bytes.view(_buffer, 0, _pos);
  }

  /// Discards the contents; the previous block view stays valid.
  void reset() {
    _buffer = Uint8List(_targetSize < 256 ? 256 : _targetSize);
    _pos = blockHeaderSize;
    _count = 0;
    _finished = false;
  }

  void _ensure(int needed) {
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, _pos, _buffer);
  }
}

/// Reads and validates a block of VXS documents.
final class BlockReader {
  BlockReader._(
    this.buffer,
    this.headerOffset,
    this.payloadStart,
    this.payloadEnd,
    this.flags,
  );

  /// Parses a block starting at [offset]; [length] defaults to the rest of
  /// [buffer].
  factory BlockReader(
    Uint8List buffer, {
    int offset = 0,
    int? length,
    bool verifyChecksum = true,
  }) {
    final end = length == null ? buffer.length : offset + length;
    if (end > buffer.length || end - offset < blockHeaderSize) {
      throw VxsFormatException('block shorter than its header', offset: offset);
    }
    if (buffer[offset] != blockMagic) {
      throw VxsFormatException(
        'bad block magic 0x${buffer[offset].toRadixString(16)}',
        offset: offset,
      );
    }
    if (buffer[offset + 1] != blockVersion) {
      throw VxsFormatException(
        'unsupported block version ${buffer[offset + 1]}',
        offset: offset,
      );
    }
    final flags = buffer[offset + 2];
    if (flags & ~blockFlagCrc32c != 0 || buffer[offset + 3] != 0) {
      throw VxsFormatException(
        'reserved block header bits set',
        offset: offset,
      );
    }
    final hasCrc = flags & blockFlagCrc32c != 0;
    final payloadStart = offset + blockHeaderSize;
    final payloadEnd = end - (hasCrc ? 4 : 0);
    if (payloadEnd < payloadStart) {
      throw VxsFormatException('block has no payload', offset: offset);
    }
    if (hasCrc && verifyChecksum) {
      final stored = VxsLe.u32(buffer, payloadEnd);
      final actual = VxsCrc32c.compute(buffer, payloadStart, payloadEnd);
      if (stored != actual) {
        throw VxsFormatException(
          'block checksum mismatch: stored 0x${stored.toRadixString(16)}, '
          'computed 0x${actual.toRadixString(16)}',
          offset: payloadEnd,
        );
      }
    }
    return BlockReader._(buffer, offset, payloadStart, payloadEnd, flags);
  }

  /// Backing bytes.
  final Uint8List buffer;

  /// Offset of the block header inside [buffer].
  final int headerOffset;

  /// Offset of the first document.
  final int payloadStart;

  /// Offset one past the last document.
  final int payloadEnd;

  /// Header flags.
  final int flags;

  /// Payload size in bytes.
  int get payloadLength => payloadEnd - payloadStart;

  /// Whether the block carries a checksum.
  bool get hasChecksum => flags & blockFlagCrc32c != 0;

  /// Number of documents, obtained by scanning.
  int get docCount {
    var count = 0;
    forEach((_) => count++);
    return count;
  }

  /// Visits every document in order.
  void forEach(void Function(DocView document) visit) {
    var pos = payloadStart;
    while (pos < payloadEnd) {
      final view = DocView.parse(buffer, pos, payloadEnd - pos);
      visit(view);
      pos = view.byteEnd;
    }
  }

  /// Parses the document that starts [relativeOffset] bytes into the payload.
  DocView docAt(int relativeOffset) {
    final absolute = payloadStart + relativeOffset;
    if (absolute < payloadStart || absolute >= payloadEnd) {
      throw RangeError.range(relativeOffset, 0, payloadLength - 1);
    }
    return DocView.parse(buffer, absolute, payloadEnd - absolute);
  }
}
