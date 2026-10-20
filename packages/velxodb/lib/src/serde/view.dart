import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'crc32c.dart';
import 'schema.dart';
import 'string_view.dart';
import 'vxs.dart';

/// A read-only, zero-copy view over one encoded VXS document.
///
/// Creating a view validates the header only: no field is decoded, nothing is
/// allocated beyond the view itself. Values are read on demand.
///
/// ```dart
/// final view = DocView.parse(bytes);
/// final text = view.getString(5); // only now is utf8 decoded
/// ```
final class DocView {
  DocView._(
    this.buffer,
    this.byteOffset,
    this.bodyStart,
    this.bodyEnd,
    this.byteEnd,
    this.flags,
    this.schemaId,
    this.schemaVersion,
    this.checksum,
  );

  /// Parses and validates the document starting at [offset].
  ///
  /// [length] is the total document size including any checksum trailer; when
  /// omitted the document is parsed out of [buffer] starting at [offset].
  /// Checksums are read but not verified; call [verifyChecksum] or use
  /// [parseVerified] to pay for the extra pass.
  static DocView parse(Uint8List buffer, [int offset = 0, int? length]) {
    final end = length == null ? buffer.length : offset + length;
    if (end > buffer.length || offset < 0 || end < offset) {
      throw VxsFormatException('document range out of bounds', offset: offset);
    }
    if (end - offset < 4) {
      throw VxsFormatException(
        'document shorter than the 4-byte preamble',
        offset: offset,
      );
    }
    if (buffer[offset] != vxsMagic) {
      throw VxsFormatException(
        'bad magic 0x${buffer[offset].toRadixString(16)}',
        offset: offset,
      );
    }
    final flags = buffer[offset + 1];
    if (flags & vxsReservedFlags != 0) {
      throw VxsFormatException(
        'reserved flag bits set (0x${flags.toRadixString(16)})',
        offset: offset,
      );
    }
    final schemaId = buffer[offset + 2];
    final schemaVersion = buffer[offset + 3];
    final large = flags & vxsFlagLength32 != 0;
    final headerSize = large ? vxsHeaderSizeLarge : vxsHeaderSize;
    if (end - offset < headerSize) {
      throw VxsFormatException(
        'document shorter than the $headerSize-byte header',
        offset: offset,
      );
    }
    final bodyLength =
        large ? VxsLe.u32(buffer, offset + 4) : VxsLe.u16(buffer, offset + 4);
    final bodyStart = offset + headerSize;
    final bodyEnd = bodyStart + bodyLength;
    if (bodyEnd > end) {
      throw VxsFormatException(
        'body length $bodyLength exceeds the available ${end - bodyStart} bytes',
        offset: offset,
      );
    }
    if (flags & vxsFlagCrc32c != 0) {
      if (bodyEnd + 4 > end) {
        throw VxsFormatException('missing checksum trailer', offset: bodyEnd);
      }
      final stored = VxsLe.u32(buffer, bodyEnd);
      return DocView._(
        buffer,
        offset,
        bodyStart,
        bodyEnd,
        bodyEnd + 4,
        flags,
        schemaId,
        schemaVersion,
        stored,
      );
    }
    return DocView._(
      buffer,
      offset,
      bodyStart,
      bodyEnd,
      bodyEnd,
      flags,
      schemaId,
      schemaVersion,
      null,
    );
  }

  /// Parses a document and verifies its checksum when one is present.
  static DocView parseVerified(Uint8List buffer, [int offset = 0, int? length]) {
    final view = parse(buffer, offset, length);
    view.verifyChecksum();
    return view;
  }

  /// Backing bytes; do not modify while views are alive.
  final Uint8List buffer;

  /// Offset of the magic byte inside [buffer].
  final int byteOffset;

  /// Offset of the first field entry.
  final int bodyStart;

  /// Offset one past the last field entry.
  final int bodyEnd;

  /// Header flags byte.
  final int flags;

  /// Schema id recorded when the document was written.
  final int schemaId;

  /// Schema version recorded when the document was written.
  final int schemaVersion;

  /// Offset one past this document inside [buffer].
  final int byteEnd;

  /// Stored CRC-32C of the body, or `null` when the document has none.
  final int? checksum;

  /// Whether the document carries a checksum trailer.
  bool get hasChecksum => checksum != null;

  /// Recomputes CRC-32C and throws when it does not match the stored value.
  ///
  /// A no-op for documents without a checksum.
  void verifyChecksum() {
    final stored = checksum;
    if (stored == null) return;
    final actual = VxsCrc32c.compute(buffer, bodyStart, bodyEnd);
    if (actual != stored) {
      throw VxsFormatException(
        'checksum mismatch: stored 0x${stored.toRadixString(16)}, '
        'computed 0x${actual.toRadixString(16)}',
        offset: bodyEnd,
      );
    }
  }

  /// Total encoded size in bytes, including any checksum trailer.
  int get byteLength => byteEnd - byteOffset;

  /// Number of field entries, obtained by scanning.
  int get fieldCount {
    final cursor = this.cursor();
    var count = 0;
    while (cursor.next()) {
      count++;
    }
    return count;
  }

  late final ByteData _data = ByteData.sublistView(buffer);

  /// Creates a cursor positioned before the first field.
  DocCursor cursor() => DocCursor._(buffer, bodyStart, bodyEnd);

  /// Visits every field once, without allocating per field.
  void forEachField(void Function(DocCursor cursor) visit) {
    final cursor = DocCursor._(buffer, bodyStart, bodyEnd);
    while (cursor.next()) {
      visit(cursor);
    }
  }

  /// Whether [fieldId] is present in the encoded bytes.
  bool has(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId == fieldId) return true;
    }
    return false;
  }

  /// Reads a zigzag varint field, or `null` when absent.
  int? getInt(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.varint);
      return VxsVarint.unzigzag(cursor.intValue);
    }
    return null;
  }

  /// Reads a boolean field, or `null` when absent.
  bool? getBool(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.varint);
      return cursor.intValue != 0;
    }
    return null;
  }

  /// Reads a float64 field, or `null` when absent.
  double? getFloat64(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.fixed64);
      return _data.getFloat64(cursor.valueOffset, Endian.little);
    }
    return null;
  }

  /// Reads a float32 field, or `null` when absent.
  double? getFloat32(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.fixed32);
      return _data.getFloat32(cursor.valueOffset, Endian.little);
    }
    return null;
  }

  /// Reads a string field, or `null` when absent. Decodes UTF-8 on every call.
  String? getString(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.lengthDelimited);
      return utf8.decode(_slice(cursor.valueOffset, cursor.valueLength));
    }
    return null;
  }

  /// Returns a zero-copy slice of a bytes/string field.
  ///
  /// Strings are returned as their raw UTF-8 bytes; use [getString] to decode.
  Bytes? getBytes(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.lengthDelimited);
      return Bytes.view(buffer, cursor.valueOffset, cursor.valueLength);
    }
    return null;
  }

  /// Returns a zero-copy UTF-8 view of a string field.
  ///
  /// Use this instead of [getString] whenever the value only needs to be
  /// compared, hashed or prefix-matched: no `String` is allocated.
  StringView? getStringView(int fieldId) {
    final cursor = this.cursor();
    while (cursor.next()) {
      if (cursor.fieldId != fieldId) continue;
      _requireWire(cursor, fieldId, VxsWire.lengthDelimited);
      return StringView(
        buffer,
        cursor.valueOffset,
        cursor.valueOffset + cursor.valueLength,
      );
    }
    return null;
  }

  /// Reads several fields in a single scan, in [fieldIds] order.
  ///
  /// Strings come back as [StringView] (zero-copy), bytes and lists as [Bytes],
  /// numbers as `int`/`double`/`bool`. Missing fields are `null`. This avoids
  /// the O(fields x requested) cost of calling the individual getters.
  List<Object?> project(VxsSchema schema, List<int> fieldIds) {
    final out = List<Object?>.filled(fieldIds.length, null);
    if (fieldIds.isEmpty) return out;
    final cursor = this.cursor();
    while (cursor.next()) {
      final index = fieldIds.indexOf(cursor.fieldId);
      if (index < 0) continue;
      final field = schema.fieldById(cursor.fieldId);
      if (field == null || field.type.wireType != cursor.wireType) continue;
      out[index] = _valueOf(field.type, cursor);
    }
    return out;
  }

  /// Checks the document against [schema].
  ///
  /// Returns every problem found instead of throwing, so a migration or an
  /// import tool can report all of them at once. Nothing is allocated for a
  /// clean document beyond the (empty) issue list.
  List<VxsValidationIssue> validate(
    VxsSchema schema, {
    bool allowUnknown = true,
    int maxDepth = 8,
  }) {
    final issues = <VxsValidationIssue>[];
    _validateInto(schema, issues, allowUnknown: allowUnknown, depth: maxDepth);
    return issues;
  }

  /// Throws [VxsFormatException] on the first validation issue.
  void validateOrThrow(
    VxsSchema schema, {
    bool allowUnknown = true,
    int maxDepth = 8,
  }) {
    final issues = validate(
      schema,
      allowUnknown: allowUnknown,
      maxDepth: maxDepth,
    );
    if (issues.isNotEmpty) {
      throw VxsFormatException(issues.first.toString(), offset: issues.first.offset);
    }
  }

  void _validateInto(
    VxsSchema schema,
    List<VxsValidationIssue> issues, {
    required bool allowUnknown,
    required int depth,
  }) {
    final cursor = this.cursor();
    while (cursor.next()) {
      final field = schema.fieldById(cursor.fieldId);
      if (field == null) {
        if (!allowUnknown) {
          issues.add(
            VxsValidationIssue(
              cursor.fieldId,
              'unknown field',
              cursor.entryOffset,
            ),
          );
        }
        continue;
      }
      if (cursor.wireType != field.type.wireType) {
        issues.add(
          VxsValidationIssue(
            cursor.fieldId,
            'wire type ${cursor.wireType} does not match ${field.type.name}',
            cursor.entryOffset,
          ),
        );
        continue;
      }
      switch (field.type) {
        case VxsType.intList:
          _validateList(cursor, isString: false, issues: issues);
        case VxsType.stringList:
          _validateList(cursor, isString: true, issues: issues);
        case VxsType.doc:
          if (depth <= 0) {
            issues.add(
              VxsValidationIssue(
                cursor.fieldId,
                'nested documents exceed the depth limit',
                cursor.entryOffset,
              ),
            );
          } else {
            try {
              final nested = DocView.parse(
                buffer,
                cursor.valueOffset,
                cursor.valueLength,
              );
              if (nested.byteEnd != cursor.valueOffset + cursor.valueLength) {
                issues.add(
                  VxsValidationIssue(
                    cursor.fieldId,
                    'nested document has trailing bytes',
                    cursor.valueOffset,
                  ),
                );
              }
              nested._validateInto(
                schema,
                issues,
                allowUnknown: allowUnknown,
                depth: depth - 1,
              );
            } on VxsFormatException catch (error) {
              issues.add(
                VxsValidationIssue(
                  cursor.fieldId,
                  'nested document: ${error.message}',
                  cursor.valueOffset,
                ),
              );
            }
          }
        default:
          break;
      }
    }
  }

  void _validateList(
    DocCursor cursor, {
    required bool isString,
    required List<VxsValidationIssue> issues,
  }) {
    final end = cursor.valueOffset + cursor.valueLength;
    var pos = cursor.valueOffset;
    try {
      final count = VxsVarint.decode(buffer, pos, end);
      pos = count.next;
      for (var i = 0; i < count.value; i++) {
        if (isString) {
          final length = VxsVarint.decode(buffer, pos, end);
          pos = length.next + length.value;
          if (pos > end) {
            issues.add(
              VxsValidationIssue(
                cursor.fieldId,
                'list element $i overruns the field',
                cursor.valueOffset,
              ),
            );
            return;
          }
        } else {
          pos = VxsVarint.decode(buffer, pos, end).next;
        }
      }
      if (pos != end) {
        issues.add(
          VxsValidationIssue(
            cursor.fieldId,
            'list has ${end - pos} trailing bytes',
            pos,
          ),
        );
      }
    } on VxsFormatException catch (error) {
      issues.add(
        VxsValidationIssue(cursor.fieldId, 'list: ${error.message}', pos),
      );
    }
  }

  Object? _valueOf(VxsType type, DocCursor cursor) => switch (type) {
    VxsType.boolean => cursor.intValue != 0,
    VxsType.int32 || VxsType.int64 => VxsVarint.unzigzag(cursor.intValue),
    VxsType.float32 => _data.getFloat32(cursor.valueOffset, Endian.little),
    VxsType.float64 => _data.getFloat64(cursor.valueOffset, Endian.little),
    VxsType.string => StringView(
      buffer,
      cursor.valueOffset,
      cursor.valueOffset + cursor.valueLength,
    ),
    VxsType.bytes ||
    VxsType.stringList ||
    VxsType.intList ||
    VxsType.doc => Bytes.view(
      buffer,
      cursor.valueOffset,
      cursor.valueLength,
    ),
  };

  Uint8List _slice(int start, int length) =>
      Uint8List.sublistView(buffer, start, start + length);

  void _requireWire(DocCursor cursor, int fieldId, int expected) {
    if (cursor.wireType != expected) {
      throw VxsFormatException(
        'field $fieldId has wire type ${cursor.wireType}, expected $expected',
        offset: cursor.valueOffset,
      );
    }
  }

  @override
  String toString() =>
      'DocView(schema: $schemaId v$schemaVersion, $fieldCount fields, '
      '$byteLength bytes)';
}

/// Forward cursor over the fields of a [DocView].
///
/// A cursor never allocates and never decodes a value it is not asked for.
/// For a length-prefixed field the payload length is known immediately, so the
/// payload can be sliced without parsing it.
final class DocCursor {
  DocCursor._(this._bytes, this._pos, this._end);

  final Uint8List _bytes;
  int _pos;
  final int _end;

  int _fieldId = 0;
  int _wire = 0;
  int _valueStart = 0;
  int _valueLength = 0;
  int _intValue = 0;
  int _entryStart = 0;
  int _valueRawStart = 0;

  /// Field id of the current entry.
  int get fieldId => _fieldId;

  /// Wire type of the current entry.
  int get wireType => _wire;

  /// Offset of the encoded value (after the key and length prefix).
  int get valueOffset => _valueStart;

  /// Length of the encoded value.
  int get valueLength => _valueLength;

  /// Decoded varint value when [wireType] is [VxsWire.varint].
  int get intValue => _intValue;

  /// Offset of the key byte of the current entry.
  int get entryOffset => _entryStart;

  /// Offset just past the key byte.
  int get valueRawOffset => _valueRawStart;

  /// Offset just past the encoded value (start of the next entry).
  int get valueRawEnd => _pos;

  /// Advances to the next field. Returns `false` at the end of the document.
  bool next() {
    if (_pos >= _end) return false;
    _entryStart = _pos;
    final key = _bytes[_pos++];
    _wire = key & 0x03;
    final code = key >> 2;
    final delta = code == 0 ? vxsExtendedDeltaBase + _readVarint() : code - 1;
    // The key may include an extended delta varint; the raw value starts after
    // *all* of it, otherwise a verbatim copy would swallow those bytes.
    _valueRawStart = _pos;
    if (delta <= 0) {
      throw VxsFormatException('field ids must ascend', offset: _entryStart);
    }
    _fieldId += delta;
    if (_fieldId > 0xFFFF) {
      throw VxsFormatException('field id overflow', offset: _entryStart);
    }
    switch (_wire) {
      case VxsWire.varint:
        _valueStart = _pos;
        _intValue = _readVarint();
        _valueLength = _pos - _valueStart;
      case VxsWire.fixed32:
        _valueStart = _pos;
        _valueLength = 4;
        _pos += 4;
        if (_pos > _end) {
          throw VxsFormatException('truncated fixed32', offset: _valueStart);
        }
      case VxsWire.fixed64:
        _valueStart = _pos;
        _valueLength = 8;
        _pos += 8;
        if (_pos > _end) {
          throw VxsFormatException('truncated fixed64', offset: _valueStart);
        }
      default:
        final length = _readVarint();
        _valueStart = _pos;
        _valueLength = length;
        _pos += length;
        if (_pos > _end) {
          throw VxsFormatException(
            'length-delimited value of $length bytes overruns the document',
            offset: _valueStart,
          );
        }
    }
    return true;
  }

  int _readVarint() {
    // Same limb accumulation as VxsVarint.decode, inlined: this is the hot path
    // for every field, and a record return would allocate on the web.
    var lo = 0;
    var hi = 0;
    var shift = 0;
    for (var count = 0; count < 10; count++) {
      if (_pos >= _end) {
        throw VxsFormatException('truncated varint', offset: _pos);
      }
      final byte = _bytes[_pos++];
      final bits = byte & 0x7F;
      if (shift < 32) {
        lo += bits * _varintPow2[shift ~/ 7];
      } else {
        final k = shift - 32;
        if (k >= 32) {
          throw VxsFormatException('varint wider than 64 bits', offset: _pos);
        }
        hi += bits * (1 << k);
      }
      if (byte < 0x80) return hi * 0x100000000 + lo;
      shift += 7;
    }
    throw VxsFormatException('varint longer than 10 bytes', offset: _pos);
  }

  static const List<int> _varintPow2 = <int>[
    1,
    128,
    16384,
    2097152,
    268435456,
  ];
}
