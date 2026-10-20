import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'vxs.dart';

/// A bump-allocated buffer that holds many consecutive VXS documents.
///
/// This is the batch writing path: one large buffer, no per-document allocation,
/// no zeroing between documents. Callers get back the offset of each document
/// and can hand the whole buffer to a block writer or an I/O sink.
///
/// A document written through a sink must fit the 16-bit body length; larger
/// blobs should use [DocBuilder]. The sink is not thread safe and [reset]
/// invalidates every view previously handed out.
final class DocSink {
  /// Creates a sink with an initial [capacity] in bytes.
  DocSink({int capacity = 64 * 1024, this.collectOffsets = false})
    : _data = Uint8List(capacity < 64 ? 64 : capacity);

  /// Whether [offsets] records the start offset of every finished document.
  final bool collectOffsets;

  /// Start offsets of finished documents, in order. Empty unless
  /// [collectOffsets] is true.
  final List<int> offsets = <int>[];

  Uint8List _data;
  int _pos = 0;
  int _docStart = -1;
  int _lastFieldId = 0;
  bool _open = false;
  int _schemaId = 0;
  int _schemaVersion = 1;
  ByteData? _floatData;

  /// The backing buffer. Grows by copying; re-read it after every write.
  Uint8List get buffer => _data;

  /// Bytes written so far.
  int get length => _pos;

  /// Number of documents finished since the last [reset].
  int get docCount => offsets.length;

  /// Whether a document is currently being written.
  bool get isOpen => _open;

  /// Starts a document and returns its start offset.
  int beginDoc({int schemaId = 0, int schemaVersion = 1}) {
    if (_open) {
      throw StateError('a document is already open');
    }
    _ensure(vxsHeaderSize);
    _docStart = _pos;
    _pos += vxsHeaderSize;
    _schemaId = schemaId;
    _schemaVersion = schemaVersion;
    _lastFieldId = 0;
    _open = true;
    return _docStart;
  }

  /// Patches the header of the open document and returns its start offset.
  int endDoc() {
    if (!_open) {
      throw StateError('no document is open');
    }
    final bodyStart = _docStart + vxsHeaderSize;
    final bodyLength = _pos - bodyStart;
    if (bodyLength <= vxsMaxSmallBody) {
      _data[_docStart] = vxsMagic;
      _data[_docStart + 1] = 0;
      _data[_docStart + 2] = _schemaId;
      _data[_docStart + 3] = _schemaVersion;
      VxsLe.w16(_data, _docStart + 4, bodyLength);
    } else {
      _growHeaderTo32(bodyStart, bodyLength);
    }
    final start = _docStart;
    _open = false;
    _docStart = -1;
    if (collectOffsets) offsets.add(start);
    return start;
  }

  /// Discards the contents and reuses the buffer from the start.
  ///
  /// Any [Bytes] view handed out earlier points into this buffer; use it only
  /// after the buffer has been written out.
  void reset() {
    _pos = 0;
    _docStart = -1;
    _lastFieldId = 0;
    _open = false;
    offsets.clear();
  }

  /// Writes a boolean field.
  void putBool(int fieldId, bool value) {
    _beginEntry(fieldId, VxsWire.varint);
    _writeVarint(value ? 1 : 0);
  }

  /// Writes a signed integer field using zigzag varints.
  void putInt(int fieldId, int value) {
    _beginEntry(fieldId, VxsWire.varint);
    _writeVarint(VxsVarint.zigzag(value));
  }

  /// Writes an unsigned varint field without zigzag.
  void putUnsigned(int fieldId, int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must not be negative');
    }
    _beginEntry(fieldId, VxsWire.varint);
    _writeVarint(value);
  }

  /// Writes a float64 field.
  void putFloat64(int fieldId, double value) {
    _beginEntry(fieldId, VxsWire.fixed64);
    _ensure(8);
    _floats().setFloat64(_pos, value, Endian.little);
    _pos += 8;
  }

  /// Writes a float32 field.
  void putFloat32(int fieldId, double value) {
    _beginEntry(fieldId, VxsWire.fixed32);
    _ensure(4);
    _floats().setFloat32(_pos, value, Endian.little);
    _pos += 4;
  }

  /// Writes a UTF-8 string field.
  ///
  /// Encodes straight into the output buffer in a single pass and assumes a
  /// one-byte length prefix (any string under 128 bytes, i.e. almost all of
  /// them). Wider strings fall back to the allocating encoder.
  void putString(int fieldId, String value) {
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    final units = value.length;
    if (units == 0) {
      _writeVarint(0);
      return;
    }
    final start = _pos;
    _ensure(1 + units * 3);
    final written = encodeUtf8(value, _data, start + 1);
    if (written < 0x80) {
      _data[start] = written;
      _pos = start + 1 + written;
      return;
    }
    final bytes = _utf8Fallback(value);
    _writeVarint(bytes.length);
    _ensure(bytes.length);
    _data.setRange(_pos, _pos + bytes.length, bytes);
    _pos += bytes.length;
  }

  /// Writes an opaque bytes field.
  void putBytes(int fieldId, List<int> value) {
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(value.length);
    _ensure(value.length);
    _data.setRange(_pos, _pos + value.length, value);
    _pos += value.length;
  }

  /// Writes a `List<String>` field.
  void putStringList(int fieldId, List<String> values) {
    final encoded = <List<int>>[];
    var payload = VxsVarint.size(values.length);
    for (final value in values) {
      final bytes = _utf8Fallback(value);
      encoded.add(bytes);
      payload += VxsVarint.size(bytes.length) + bytes.length;
    }
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(payload);
    _writeVarint(values.length);
    for (final bytes in encoded) {
      _writeVarint(bytes.length);
      _ensure(bytes.length);
      _data.setRange(_pos, _pos + bytes.length, bytes);
      _pos += bytes.length;
    }
  }

  /// Writes a `List<int>` field.
  void putIntList(int fieldId, List<int> values) {
    var payload = VxsVarint.size(values.length);
    for (final value in values) {
      payload += VxsVarint.size(VxsVarint.zigzag(value));
    }
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(payload);
    _writeVarint(values.length);
    for (final value in values) {
      _writeVarint(VxsVarint.zigzag(value));
    }
  }

  /// Writes an already encoded document (including its header) as a nested doc.
  void putDoc(int fieldId, Bytes doc) {
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(doc.length);
    _ensure(doc.length);
    _data.setRange(_pos, _pos + doc.length, doc.asUint8List());
    _pos += doc.length;
  }

  /// Copies an encoded value verbatim, for forward-compatibility round trips.
  void putRawEntry(
    int fieldId,
    int wireType,
    Uint8List source,
    int start,
    int end,
  ) {
    _beginEntry(fieldId, wireType);
    final length = end - start;
    _ensure(length);
    _data.setRange(_pos, _pos + length, source, start);
    _pos += length;
  }

  void _beginEntry(int fieldId, int wireType) {
    if (!_open) {
      throw StateError('call beginDoc() before writing fields');
    }
    if (fieldId <= _lastFieldId) {
      throw ArgumentError.value(
        fieldId,
        'fieldId',
        'must be greater than the previous field id ($_lastFieldId)',
      );
    }
    if (fieldId > 0xFFFF) {
      throw ArgumentError.value(fieldId, 'fieldId', 'must be <= 65535');
    }
    final delta = fieldId - _lastFieldId;
    _ensure(12);
    if (delta <= vxsMaxInlineDelta) {
      _data[_pos++] = ((delta + 1) << 2) | wireType;
    } else {
      _data[_pos++] = wireType;
      _writeVarint(delta - vxsExtendedDeltaBase);
    }
    _lastFieldId = fieldId;
  }

  void _writeVarint(int value) {
    _ensure(10);
    var v = value;
    while (v >= 0x80) {
      _data[_pos++] = (v % 0x80) | 0x80;
      v ~/= 0x80;
    }
    _data[_pos++] = v;
  }

  ByteData _floats() => _floatData ??= ByteData.sublistView(_data);

  void _ensure(int additional) {
    final needed = _pos + additional;
    if (needed <= _data.length) return;
    var capacity = _data.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final next = Uint8List(capacity);
    next.setRange(0, _pos, _data);
    _data = next;
    _floatData = null;
  }

  /// Rewrites a document's header from 6 to 8 bytes. Rare (>64 KiB documents);
  /// the backwards loop is safe on overlapping ranges.
  void _growHeaderTo32(int bodyStart, int bodyLength) {
    _ensure(2);
    final end = _pos;
    for (var i = end - 1; i >= bodyStart; i--) {
      _data[i + 2] = _data[i];
    }
    _pos = end + 2;
    _data[_docStart] = vxsMagic;
    _data[_docStart + 1] = vxsFlagLength32;
    _data[_docStart + 2] = _schemaId;
    _data[_docStart + 3] = _schemaVersion;
    VxsLe.w32(_data, _docStart + 4, bodyLength);
  }

  static List<int> _utf8Fallback(String value) => _encode(value);

  static List<int> _encode(String value) {
    final out = <int>[];
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 0x80) {
        out.add(unit);
      } else if (unit < 0x800) {
        out.add(0xC0 | (unit >> 6));
        out.add(0x80 | (unit & 0x3F));
      } else if (unit >= 0xD800 && unit <= 0xDBFF) {
        final low = value.codeUnitAt(++i);
        final rune = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        out.add(0xF0 | (rune >> 18));
        out.add(0x80 | ((rune >> 12) & 0x3F));
        out.add(0x80 | ((rune >> 6) & 0x3F));
        out.add(0x80 | (rune & 0x3F));
      } else {
        out.add(0xE0 | (unit >> 12));
        out.add(0x80 | ((unit >> 6) & 0x3F));
        out.add(0x80 | (unit & 0x3F));
      }
    }
    return out;
  }

  /// Writes the UTF-8 form of [value] into [out] starting at [offset] and
  /// returns the number of bytes written.
  static int encodeUtf8(String value, Uint8List out, int offset) {
    var o = offset;
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 0x80) {
        out[o++] = unit;
      } else if (unit < 0x800) {
        out[o++] = 0xC0 | (unit >> 6);
        out[o++] = 0x80 | (unit & 0x3F);
      } else if (unit >= 0xD800 && unit <= 0xDBFF) {
        final low = value.codeUnitAt(++i);
        final rune = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        out[o++] = 0xF0 | (rune >> 18);
        out[o++] = 0x80 | ((rune >> 12) & 0x3F);
        out[o++] = 0x80 | ((rune >> 6) & 0x3F);
        out[o++] = 0x80 | (rune & 0x3F);
      } else {
        out[o++] = 0xE0 | (unit >> 12);
        out[o++] = 0x80 | ((unit >> 6) & 0x3F);
        out[o++] = 0x80 | (unit & 0x3F);
      }
    }
    return o - offset;
  }
}
