import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/crc32c.dart';
import '../serde/string_view.dart';
import '../serde/view.dart';
import '../serde/vxs.dart';
import 'block.dart';
import 'bloom.dart';

/// First byte of a segment file.
const int segmentMagic = 0x53;

/// Segment format version.
const int segmentVersion = 1;

/// Header size of a segment.
const int segmentHeaderSize = 16;

/// Magic value stored in the segment footer.
const int segmentFooterMagic = 0x47455356;

/// Footer size of a segment.
const int segmentFooterSize = 32;

/// `docOffset` value marking a tombstone entry.
const int segmentTombstone = 0xFFFFFFFF;

/// Builds an immutable segment: blocks of documents plus a sorted primary index.
///
/// The segment is a pure byte format: [finish] returns a [Bytes] buffer that can
/// be written to a file or an object store. It knows nothing about I/O.
///
/// Layout:
///
/// ```text
/// [header 16B][blocks...][block table][index][bloom][footer 32B]
/// ```
///
/// Keys must be unique. They are copied on [add] because callers reuse their
/// key buffers.
final class SegmentBuilder {
  /// Creates a builder with a target document-block size.
  SegmentBuilder({this.blockTargetSize = 64 * 1024, this.bitsPerKey = 10});

  /// Target size of one document block.
  final int blockTargetSize;

  /// Bloom filter bits per key.
  final int bitsPerKey;

  final BytesMut _blocks = BytesMut(1 << 12);
  final List<int> _blockOffsets = <int>[];
  final List<Uint8List> _keys = <Uint8List>[];
  final List<int> _docOffsets = <int>[];

  BlockWriter? _block;
  int _blockBase = 0;
  int _docCount = 0;

  /// Number of documents added.
  int get docCount => _docCount;

  /// Bytes accumulated so far, excluding the index and bloom.
  int get payloadSize => _blocks.length;

  /// Adds one document under [key].
  void add(Uint8List key, Bytes document) {
    if (_block == null) {
      _block = BlockWriter(targetSize: blockTargetSize);
      _blockBase = _blocks.length;
    }
    final relative = _block!.append(document);
    _keys.add(Uint8List.fromList(key));
    _docOffsets.add(segmentHeaderSize + _blockBase + blockHeaderSize + relative);
    _docCount++;
    if (_block!.isFull) {
      _finishBlock();
    }
  }

  /// Records that [key] was deleted, without storing a document.
  void addTombstone(Uint8List key) {
    _keys.add(Uint8List.fromList(key));
    _docOffsets.add(segmentTombstone);
    _docCount++;
  }

  /// Builds the segment and returns its bytes.
  Bytes finish() {
    _finishBlock();

    final order = List<int>.generate(_keys.length, (i) => i)
      ..sort((a, b) => StringView.compareRanges(
        _keys[a], 0, _keys[a].length, _keys[b], 0, _keys[b].length,
      ));
    for (var i = 1; i < order.length; i++) {
      final previous = _keys[order[i - 1]];
      final current = _keys[order[i]];
      if (StringView.compareRanges(
            previous, 0, previous.length, current, 0, current.length,
          ) ==
          0) {
        throw ArgumentError('duplicate key in segment');
      }
    }

    final out = BytesMut(_blocks.length + _keys.length * 24 + 1024);
    out.reserve(segmentHeaderSize);
    out.advance(segmentHeaderSize);

    // Blocks.
    final blockBytes = _blocks.freeze().asUint8List();
    final blockRegionStart = out.length;
    out.reserve(blockBytes.length);
    out.putSliceUnchecked(blockBytes);

    // Block offset table.
    final tableOffset = out.length;
    out.reserve(_blockOffsets.length * 4);
    for (final offset in _blockOffsets) {
      out.putUint32Unchecked(blockRegionStart + offset, endian: Endian.little);
    }

    // Index.
    final indexOffset = out.length;
    out.reserve(4 + (order.length + 1) * 4);
    out.putUint32Unchecked(order.length, endian: Endian.little);
    final entryOffsets = <int>[];
    var entrySize = 0;
    for (final index in order) {
      entryOffsets.add(entrySize);
      entrySize += 2 + _keys[index].length + 4;
    }
    entryOffsets.add(entrySize);
    for (final relative in entryOffsets) {
      out.putUint32Unchecked(relative, endian: Endian.little);
    }
    for (final index in order) {
      final key = _keys[index];
      out.reserve(2 + key.length + 4);
      out.putUint16Unchecked(key.length, endian: Endian.little);
      out.putSliceUnchecked(key);
      out.putUint32Unchecked(_docOffsets[index], endian: Endian.little);
    }
    final indexLength = out.length - indexOffset;

    // Bloom.
    final bloomOffset = out.length;
    final bloom = BloomFilter.build(
      order.map((i) => _keys[i]),
      bitsPerKey: bitsPerKey,
    );
    final bloomBytes = bloom.toBytes();
    out.reserve(bloomBytes.length);
    out.putSliceUnchecked(bloomBytes);
    final bloomLength = out.length - bloomOffset;

    final footerStart = out.length;
    out.reserve(segmentFooterSize);
    out.putUint32Unchecked(segmentFooterMagic, endian: Endian.little);
    out.putUint32Unchecked(tableOffset, endian: Endian.little);
    out.putUint32Unchecked(indexOffset, endian: Endian.little);
    out.putUint32Unchecked(indexLength, endian: Endian.little);
    out.putUint32Unchecked(bloomOffset, endian: Endian.little);
    out.putUint32Unchecked(bloomLength, endian: Endian.little);
    out.putUint32Unchecked(
      VxsCrc32c.compute(out.asUint8List(), tableOffset, footerStart),
      endian: Endian.little,
    );
    out.putUint32Unchecked(0, endian: Endian.little);

    final data = out.asUint8List();
    data[0] = segmentMagic;
    data[1] = segmentVersion;
    data[2] = 0;
    data[3] = 0;
    VxsLe.w32(data, 4, _docCount);
    VxsLe.w32(data, 8, _blockOffsets.length);
    VxsLe.w32(data, 12, 0);
    return out.freeze();
  }

  void _finishBlock() {
    final block = _block;
    if (block == null || block.isEmpty) {
      _block = null;
      return;
    }
    _blockOffsets.add(_blocks.length);
    final bytes = block.finish();
    _blocks.reserve(bytes.length);
    _blocks.putSliceUnchecked(bytes.asUint8List());
    _block = null;
  }
}

/// Reads a segment.
///
/// ```dart
/// final reader = SegmentReader(bytes);
/// final doc = reader.find(encodeKey('a'));
/// ```
final class SegmentReader {
  SegmentReader._(
    this.buffer,
    this.start,
    this.end,
    this.docCount,
    this.blockCount,
    this.tableOffset,
    this.indexOffset,
    this.indexLength,
    this.bloomOffset,
    this.bloomLength,
    this._indexCount,
    this._entryOffsetsStart,
    this._entriesStart,
    this._bloom,
  );

  /// Parses a segment starting at [offset].
  factory SegmentReader(
    Uint8List buffer, {
    int offset = 0,
    int? length,
    bool verify = true,
  }) {
    final end = length == null ? buffer.length : offset + length;
    if (end - offset < segmentHeaderSize + segmentFooterSize) {
      throw VxsFormatException('segment too short', offset: offset);
    }
    if (buffer[offset] != segmentMagic) {
      throw VxsFormatException('bad segment magic', offset: offset);
    }
    if (buffer[offset + 1] != segmentVersion) {
      throw VxsFormatException('unsupported segment version', offset: offset);
    }
    final docCount = VxsLe.u32(buffer, offset + 4);
    final blockCount = VxsLe.u32(buffer, offset + 8);
    final footerStart = end - segmentFooterSize;
    if (VxsLe.u32(buffer, footerStart) != segmentFooterMagic) {
      throw VxsFormatException('bad segment footer magic', offset: footerStart);
    }
    final tableOffset = VxsLe.u32(buffer, footerStart + 4);
    final indexOffset = VxsLe.u32(buffer, footerStart + 8);
    final indexLength = VxsLe.u32(buffer, footerStart + 12);
    final bloomOffset = VxsLe.u32(buffer, footerStart + 16);
    final bloomLength = VxsLe.u32(buffer, footerStart + 20);
    final storedCrc = VxsLe.u32(buffer, footerStart + 24);
    if (indexOffset + indexLength > footerStart ||
        bloomOffset + bloomLength > footerStart ||
        tableOffset + blockCount * 4 > footerStart) {
      throw VxsFormatException('segment metadata out of bounds', offset: offset);
    }
    if (verify) {
      final actual = VxsCrc32c.compute(buffer, tableOffset, footerStart);
      if (actual != storedCrc) {
        throw VxsFormatException(
          'segment metadata checksum mismatch: stored '
          '0x${storedCrc.toRadixString(16)}, computed '
          '0x${actual.toRadixString(16)}',
          offset: footerStart,
        );
      }
    }
    if (indexLength < 4) {
      throw VxsFormatException('empty segment index', offset: indexOffset);
    }
    final indexCount = VxsLe.u32(buffer, indexOffset);
    if (4 + (indexCount + 1) * 4 > indexLength) {
      throw VxsFormatException('segment index is truncated', offset: indexOffset);
    }
    final entryOffsetsStart = indexOffset + 4;
    final entriesStart = entryOffsetsStart + (indexCount + 1) * 4;
    final bloom = BloomFilter.parse(buffer, bloomOffset).filter;
    return SegmentReader._(
      buffer,
      offset,
      end,
      docCount,
      blockCount,
      tableOffset,
      indexOffset,
      indexLength,
      bloomOffset,
      bloomLength,
      indexCount,
      entryOffsetsStart,
      entriesStart,
      bloom,
    );
  }

  /// Backing bytes.
  final Uint8List buffer;

  /// Offset of the segment header.
  final int start;

  /// Offset one past the segment.
  final int end;

  /// Number of documents.
  final int docCount;

  /// Number of blocks.
  final int blockCount;

  /// Offset of the block table.
  final int tableOffset;

  /// Offset of the index.
  final int indexOffset;

  /// Length of the index.
  final int indexLength;

  /// Offset of the bloom filter.
  final int bloomOffset;

  /// Length of the bloom filter.
  final int bloomLength;

  final int _indexCount;
  final int _entryOffsetsStart;
  final int _entriesStart;
  final BloomFilter _bloom;

  /// Segment size in bytes.
  int get byteLength => end - start;

  /// Whether [key] may be present according to the bloom filter.
  bool mightContain(Uint8List key) => _bloom.mightContain(key);

  /// Looks [key] up, returning `null` when absent.
  ///
  /// A hit distinguishes a live document from a tombstone.
  ({bool tombstone, DocView? document})? lookup(Uint8List key) {
    if (!_bloom.mightContain(key)) return null;
    var low = 0;
    var high = _indexCount - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final comparison = _compareEntry(middle, key);
      if (comparison < 0) {
        low = middle + 1;
      } else if (comparison > 0) {
        high = middle - 1;
      } else {
        final docOffset = VxsLe.u32(
          buffer,
          _entryStart(middle) + 2 + _keyLength(middle),
        );
        if (docOffset == segmentTombstone) {
          return (tombstone: true, document: null);
        }
        return (
          tombstone: false,
          document: DocView.parse(buffer, docOffset, end - docOffset),
        );
      }
    }
    return null;
  }

  /// Looks [key] up, returning `null` for both absence and tombstones.
  DocView? find(Uint8List key) => lookup(key)?.document;

  /// Visits every entry in key order, tombstones included.
  void forEachEntry(void Function(Uint8List key, DocView? document) visit) {
    for (var i = 0; i < _indexCount; i++) {
      _visitEntry(i, visit);
    }
  }

  /// Visits entries whose key starts with [prefix], in key order.
  void forEachEntryPrefix(
    Uint8List prefix,
    void Function(Uint8List key, DocView? document) visit,
  ) {
    if (prefix.isEmpty) {
      forEachEntry(visit);
      return;
    }
    // Lower bound: first entry whose key is >= prefix.
    var low = 0;
    var high = _indexCount - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final comparison = _compareEntry(middle, prefix);
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    for (var i = low; i < _indexCount; i++) {
      final entryStart = _entryStart(i);
      final keyLength = VxsLe.u16(buffer, entryStart);
      if (keyLength < prefix.length ||
          !_rangeStartsWith(entryStart + 2, keyLength, prefix)) {
        break;
      }
      _visitEntry(i, visit);
    }
  }

  void _visitEntry(int index, void Function(Uint8List key, DocView? document) visit) {
    final entryStart = _entryStart(index);
    final keyLength = VxsLe.u16(buffer, entryStart);
    final key = Uint8List.sublistView(
      buffer,
      entryStart + 2,
      entryStart + 2 + keyLength,
    );
    final docOffset = VxsLe.u32(buffer, entryStart + 2 + keyLength);
    visit(
      key,
      docOffset == segmentTombstone
          ? null
          : DocView.parse(buffer, docOffset, end - docOffset),
    );
  }

  bool _rangeStartsWith(int start, int length, Uint8List prefix) {
    if (length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (buffer[start + i] != prefix[i]) return false;
    }
    return true;
  }

  /// Creates a forward cursor over a key range.
  ///
  /// [lower] and [upper] are full keys (collection prefix included). The cursor
  /// seeks with a binary search instead of walking the segment from the start.
  SegmentEntryCursor entryCursor({
    Uint8List? lower,
    bool includeLower = true,
    Uint8List? upper,
    bool includeUpper = false,
  }) {
    var index = 0;
    if (lower != null) {
      var low = 0;
      var high = _indexCount - 1;
      while (low <= high) {
        final middle = (low + high) >> 1;
        final comparison = _compareEntry(middle, lower);
        if (comparison < 0) {
          low = middle + 1;
        } else {
          high = middle - 1;
        }
      }
      index = low;
      if (!includeLower && index < _indexCount) {
        final entryStart = _entryStart(index);
        final keyLength = VxsLe.u16(buffer, entryStart);
        if (keyLength == lower.length &&
            _rangeStartsWith(entryStart + 2, keyLength, lower)) {
          index++;
        }
      }
    }
    return SegmentEntryCursor._(this, index, upper, includeUpper);
  }

  /// Visits every document in block order.
  void forEach(void Function(DocView document) visit) {
    for (var i = 0; i < blockCount; i++) {
      final blockStart = start + VxsLe.u32(buffer, tableOffset + i * 4);
      final blockEnd = i + 1 < blockCount
          ? start + VxsLe.u32(buffer, tableOffset + (i + 1) * 4)
          : _firstMetadataOffset();
      final reader = BlockReader(
        buffer,
        offset: blockStart,
        length: blockEnd - blockStart,
      );
      reader.forEach(visit);
    }
  }

  int _firstMetadataOffset() => tableOffset;

  int _entryStart(int index) =>
      _entriesStart + VxsLe.u32(buffer, _entryOffsetsStart + index * 4);

  int _keyLength(int index) => VxsLe.u16(buffer, _entryStart(index));

  int _compareEntry(int index, Uint8List key) {
    final entryStart = _entryStart(index);
    final keyLength = VxsLe.u16(buffer, entryStart);
    return StringView.compareRanges(
      buffer,
      entryStart + 2,
      entryStart + 2 + keyLength,
      key,
      0,
      key.length,
    );
  }
}

/// Forward cursor over a segment's index entries, ascending by key.
final class SegmentEntryCursor {
  SegmentEntryCursor._(
    this._reader,
    this._index,
    this._upper,
    this._includeUpper,
  );

  final SegmentReader _reader;
  int _index;
  final Uint8List? _upper;
  final bool _includeUpper;

  Uint8List _key = Uint8List(0);
  DocView? _document;

  /// Current key (a view into the segment).
  Uint8List get key => _key;

  /// Current document; `null` when the entry is a tombstone.
  DocView? get document => _document;

  /// Advances to the next in-range entry.
  bool moveNext() {
    while (_index < _reader._indexCount) {
      final entryStart = _reader._entryStart(_index);
      final keyLength = VxsLe.u16(_reader.buffer, entryStart);
      final key = Uint8List.sublistView(
        _reader.buffer,
        entryStart + 2,
        entryStart + 2 + keyLength,
      );
      if (_upper != null) {
        final comparison = StringView.compareRanges(
          key,
          0,
          key.length,
          _upper,
          0,
          _upper.length,
        );
        if (comparison > 0 || (comparison == 0 && !_includeUpper)) {
          _index = _reader._indexCount;
          return false;
        }
      }
      final docOffset = VxsLe.u32(_reader.buffer, entryStart + 2 + keyLength);
      _key = key;
      _document = docOffset == segmentTombstone
          ? null
          : DocView.parse(
              _reader.buffer,
              docOffset,
              _reader.end - docOffset,
            );
      _index++;
      return true;
    }
    return false;
  }
}
