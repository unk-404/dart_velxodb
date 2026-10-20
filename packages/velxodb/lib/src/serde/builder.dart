import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'vxs.dart';

/// Builds one VXS document.
///
/// Fields must be written in strictly ascending id order, which is what makes
/// the encoding canonical: one logical document has exactly one byte form.
///
/// The builder owns its byte range directly. No per-field views, no intermediate
/// encoders, no copies: a field is written where it will live on disk.
final class DocBuilder {
  /// Creates a builder. [capacity] is the initial buffer size, not a limit.
  DocBuilder({this.schemaId = 0, this.schemaVersion = 1, int capacity = 256})
    : _capacity = capacity < 64 ? 64 : capacity {
    _buf = Uint8List(_capacity);
    _data = ByteData.sublistView(_buf);
    _pos = vxsHeaderSize;
  }

  /// Schema id written into the header.
  int schemaId;

  /// Schema version written into the header.
  int schemaVersion;

  final int _capacity;
  late Uint8List _buf;
  late ByteData _data;
  int _pos = 0;
  int _lastFieldId = 0;
  bool _finished = false;

  /// Bytes written so far, including the reserved header.
  int get length => _pos;

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
    _data.setFloat64(_pos, value, Endian.little);
    _pos += 8;
  }

  /// Writes a float32 field.
  void putFloat32(int fieldId, double value) {
    _beginEntry(fieldId, VxsWire.fixed32);
    _ensure(4);
    _data.setFloat32(_pos, value, Endian.little);
    _pos += 4;
  }

  /// Writes a UTF-8 string field.
  ///
  /// Encodes straight into the output buffer in a single pass and assumes a
  /// one-byte length prefix (any string under 128 bytes, i.e. almost all of
  /// them). No intermediate buffer, no memmove. Wider strings fall back to the
  /// allocating encoder; that path is rare enough to keep simple and correct.
  void putString(int fieldId, String value) {
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    final units = value.length;
    if (units == 0) {
      _writeVarint(0);
      return;
    }
    final start = _pos;
    _ensure(1 + units * 3);
    final written = _encodeUtf8At(value, _buf, start + 1);
    if (written < 0x80) {
      _buf[start] = written;
      _pos = start + 1 + written;
      return;
    }
    // Rare: the string needs a two- or three-byte length prefix. Re-encode with
    // the allocating encoder instead of shifting the payload.
    final bytes = utf8.encode(value);
    _writeVarint(bytes.length);
    _ensure(bytes.length);
    _buf.setRange(_pos, _pos + bytes.length, bytes);
    _pos += bytes.length;
  }

  /// Writes an opaque bytes field.
  void putBytes(int fieldId, List<int> value) {
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(value.length);
    _ensure(value.length);
    _buf.setRange(_pos, _pos + value.length, value);
    _pos += value.length;
  }

  /// Writes a `List<String>` field.
  void putStringList(int fieldId, List<String> values) {
    final encoded = <Uint8List>[];
    var payload = VxsVarint.size(values.length);
    for (final value in values) {
      final bytes = utf8.encode(value);
      encoded.add(bytes);
      payload += VxsVarint.size(bytes.length) + bytes.length;
    }
    _beginEntry(fieldId, VxsWire.lengthDelimited);
    _writeVarint(payload);
    _writeVarint(values.length);
    for (final bytes in encoded) {
      _writeVarint(bytes.length);
      _ensure(bytes.length);
      _buf.setRange(_pos, _pos + bytes.length, bytes);
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
    _buf.setRange(_pos, _pos + doc.length, doc.asUint8List());
    _pos += doc.length;
  }

  /// Copies an encoded value verbatim, for forward-compatibility round trips.
  ///
  /// [start] must point at the first byte of the value (just past the key) and
  /// [end] just past it. Wire-type-specific framing is preserved as-is.
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
    _buf.setRange(_pos, _pos + length, source, start);
    _pos += length;
  }

  /// Patches the header and returns the finished document.
  ///
  /// The returned view shares the builder's buffer; [reset] allocates a fresh
  /// one, so the view stays valid.
  Bytes finish() {
    if (_finished) {
      throw StateError('finish() has already been called');
    }
    _finished = true;
    final bodyLength = _pos - vxsHeaderSize;
    if (bodyLength <= vxsMaxSmallBody) {
      _buf[0] = vxsMagic;
      _buf[1] = 0;
      _buf[2] = schemaId;
      _buf[3] = schemaVersion;
      VxsLe.w16(_buf, 4, bodyLength);
      return Bytes.view(_buf, 0, _pos);
    }
    // Rare: the body does not fit the 16-bit length. Rebuild once with the
    // wide header; the extra 2-byte shift only happens for >64KiB documents.
    final out = Uint8List(vxsHeaderSizeLarge + bodyLength);
    out[0] = vxsMagic;
    out[1] = vxsFlagLength32;
    out[2] = schemaId;
    out[3] = schemaVersion;
    VxsLe.w32(out, 4, bodyLength);
    out.setRange(vxsHeaderSizeLarge, out.length, _buf, vxsHeaderSize);
    return Bytes.fromUint8List(out);
  }

  /// Discards the contents while keeping the configured capacity.
  void reset({int? schemaId, int? schemaVersion}) {
    _buf = Uint8List(_capacity);
    _data = ByteData.sublistView(_buf);
    _pos = vxsHeaderSize;
    _lastFieldId = 0;
    _finished = false;
    if (schemaId != null) this.schemaId = schemaId;
    if (schemaVersion != null) this.schemaVersion = schemaVersion;
  }

  void _ensure(int additional) {
    final needed = _pos + additional;
    if (needed <= _buf.length) return;
    var capacity = _buf.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final next = Uint8List(capacity);
    next.setRange(0, _pos, _buf);
    _buf = next;
    _data = ByteData.sublistView(_buf);
  }

  void _beginEntry(int fieldId, int wireType) {
    if (_finished) {
      throw StateError('builder already finished; call reset()');
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
      _buf[_pos++] = ((delta + 1) << 2) | wireType;
    } else {
      _buf[_pos++] = wireType;
      _writeVarint(delta - vxsExtendedDeltaBase);
    }
    _lastFieldId = fieldId;
  }

  void _writeVarint(int value) {
    _ensure(10);
    var v = value;
    while (v >= 0x80) {
      _buf[_pos++] = (v % 0x80) | 0x80;
      v ~/= 0x80;
    }
    _buf[_pos++] = v;
  }

  /// Writes the UTF-8 form of [value] into [out] starting at [offset] and
  /// returns the number of bytes written.
  static int _encodeUtf8At(String value, Uint8List out, int offset) {
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
