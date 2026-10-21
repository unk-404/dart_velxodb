import 'dart:convert';
import 'dart:typed_data';

import '../serde/schema.dart';
import '../serde/view.dart';

/// Declares which catalog entity owns an index definition.
abstract interface class IndexCatalog {
  /// Looks up the index for `(collectionId, fieldId)`.
  IndexDefinition? indexFor(int collectionId, int fieldId);

  /// Every index declared on [collectionId].
  List<IndexDefinition> indexesFor(int collectionId);

  /// Registers an index and persists the catalog.
  IndexDefinition registerIndex(int collectionId, int fieldId, VxsType type);
}

/// A secondary index on one field of one collection.
///
/// Index entries share the engine's key space by using their own two-byte
/// collection id: `[indexId][encodedValue][primaryKey]`. Values are encoded so
/// that byte order matches value order, which keeps range scans possible later.
final class IndexDefinition {
  /// Creates a definition.
  const IndexDefinition({
    required this.collectionId,
    required this.fieldId,
    required this.type,
    required this.indexId,
  });

  /// Owning collection id.
  final int collectionId;

  /// Field id being indexed.
  final int fieldId;

  /// Declared field type.
  final VxsType type;

  /// Two-byte namespace id used in the engine.
  final int indexId;

  /// Two-byte namespace prefix shared by every entry of this index.
  Uint8List get namespacePrefix =>
      Uint8List.fromList(<int>[(indexId >> 8) & 0xFF, indexId & 0xFF]);

  /// Length of the encoded value starting at [offset] in an index key.
  ///
  /// Integers and booleans are fixed width; strings are scanned until the
  /// `0x00 0x00` terminator, skipping `0x00 0xFF` escapes.
  int encodedValueLength(Uint8List bytes, int offset) {
    switch (type) {
      case VxsType.int32:
      case VxsType.int64:
        return 9;
      case VxsType.boolean:
        return 1;
      case VxsType.string:
        var position = offset;
        while (true) {
          final byte = bytes[position++];
          if (byte != 0) continue;
          final next = bytes[position++];
          if (next == 0x00) return position - offset;
        }
      default:
        throw UnsupportedError('indexing ${type.name} is not supported');
    }
  }

  /// Compares two values of this index's type.
  int compareValues(Object a, Object b) => switch (type) {
    VxsType.string => (a as String).compareTo(b as String),
    _ => (a as int).compareTo(b as int),
  };

  /// Prefix shared by every entry for [value].
  Uint8List valuePrefix(Object value) {
    final encoded = encodeValue(value);
    final out = Uint8List(2 + encoded.length);
    out[0] = (indexId >> 8) & 0xFF;
    out[1] = indexId & 0xFF;
    out.setRange(2, out.length, encoded);
    return out;
  }

  /// Full index key for [value] and [primaryKey].
  Uint8List entryKey(Object value, Uint8List primaryKey) {
    final prefix = valuePrefix(value);
    final out = Uint8List(prefix.length + primaryKey.length);
    out
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, out.length, primaryKey);
    return out;
  }

  /// Encodes [value] order-preservingly.
  Uint8List encodeValue(Object value) => switch (type) {
    VxsType.int32 || VxsType.int64 => encodeInt(value as int),
    VxsType.string => encodeString(value as String),
    VxsType.boolean => Uint8List.fromList(<int>[value == true ? 1 : 0]),
    _ => throw UnsupportedError('indexing ${type.name} is not supported'),
  };

  /// Reads this index's field from [document].
  Object? readValue(DocView document) => switch (type) {
    VxsType.int32 || VxsType.int64 => document.getInt(fieldId),
    VxsType.string => document.getString(fieldId),
    VxsType.boolean => document.getBool(fieldId),
    _ => throw UnsupportedError('indexing ${type.name} is not supported'),
  };

  /// Order-preserving 9-byte integer encoding: sign byte, then magnitude.
  ///
  /// Negatives sort before positives and use the complement of the magnitude,
  /// so a larger magnitude sorts earlier (more negative first).
  static Uint8List encodeInt(int value) {
    final out = Uint8List(9);
    if (value >= 0) {
      out[0] = 0x80;
      _writeMagnitude(out, 1, value);
    } else {
      out[0] = 0x00;
      var magnitude = -value;
      if (magnitude < 0) {
        // minInt64 negates to itself; clamp to the largest magnitude without
        // writing a literal that dart2js cannot represent.
        magnitude = (1 << 62) + ((1 << 62) - 1);
      }
      for (var i = 0; i < 8; i++) {
        final shift = 56 - i * 8;
        out[i + 1] = ((magnitude >> shift) & 0xFF) ^ 0xFF;
      }
    }
    return out;
  }

  /// Order-preserving string encoding: UTF-8 with `0x00` escaped as
  /// `0x00 0xFF` and terminated by `0x00 0x00`.
  ///
  /// The terminator sorts before any escaped byte, so a prefix sorts before its
  /// extensions and exact-match prefixes are unambiguous.
  static Uint8List encodeString(String value) {
    final bytes = utf8.encode(value);
    var size = 2;
    for (final byte in bytes) {
      size += byte == 0 ? 2 : 1;
    }
    final out = Uint8List(size);
    var position = 0;
    for (final byte in bytes) {
      if (byte == 0) {
        out[position++] = 0x00;
        out[position++] = 0xFF;
      } else {
        out[position++] = byte;
      }
    }
    out[position++] = 0x00;
    out[position] = 0x00;
    return out;
  }

  static void _writeMagnitude(Uint8List out, int offset, int magnitude) {
    for (var i = 0; i < 8; i++) {
      final shift = 56 - i * 8;
      out[offset + i] = (magnitude >> shift) & 0xFF;
    }
  }
}
