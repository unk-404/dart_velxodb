import 'vxs.dart';

/// Logical field types understood by the VXS format.
enum VxsType {
  /// `0` / `1`.
  boolean,

  /// Signed 32-bit integer, zigzag varint.
  int32,

  /// Signed 64-bit integer, zigzag varint.
  int64,

  /// IEEE-754 single precision, 4 bytes little-endian.
  float32,

  /// IEEE-754 double precision, 8 bytes little-endian.
  float64,

  /// UTF-8 text.
  string,

  /// Opaque bytes.
  bytes,

  /// `List<String>`.
  stringList,

  /// `List<int>`.
  intList,

  /// A nested VXS document, carried verbatim.
  doc,
}

/// Wire type used on disk for each logical [VxsType].
extension VxsTypeWire on VxsType {
  /// The [VxsWire] constant this type is encoded with.
  int get wireType => switch (this) {
    VxsType.boolean || VxsType.int32 || VxsType.int64 => VxsWire.varint,
    VxsType.float32 => VxsWire.fixed32,
    VxsType.float64 => VxsWire.fixed64,
    VxsType.string ||
    VxsType.bytes ||
    VxsType.stringList ||
    VxsType.intList ||
    VxsType.doc => VxsWire.lengthDelimited,
  };
}

/// One field declaration: a stable numeric id, a name, a type.
///
/// The id is the on-disk identity. It must never be reused or reordered; the
/// name is for humans and queries only.
final class VxsField {
  /// Creates a field declaration.
  const VxsField(this.id, this.name, this.type);

  /// Stable on-disk id, `1..65535`. Zero is reserved.
  final int id;

  /// Name used by query APIs and generated code.
  final String name;

  /// Logical type.
  final VxsType type;

  @override
  String toString() => 'VxsField($id, $name, $type)';
}

/// An ordered set of [VxsField]s identified by a stable [id].
///
/// Schema ids and versions are single bytes on disk, so a database supports at
/// most 255 distinct schemas with 255 versions each.
final class VxsSchema {
  /// Creates a schema, validating id, version and field ordering.
  VxsSchema({
    required this.id,
    required this.version,
    required List<VxsField> fields,
  }) : fields = List<VxsField>.unmodifiable(fields) {
    if (id < 0 || id > 255) {
      throw ArgumentError.value(id, 'id', 'must be in 0..255');
    }
    if (version < 0 || version > 255) {
      throw ArgumentError.value(version, 'version', 'must be in 0..255');
    }
    var previous = 0;
    for (final field in fields) {
      if (field.id <= previous) {
        throw ArgumentError(
          'fields must be declared in strictly ascending id order '
          '(${field.name} has id ${field.id} after $previous)',
        );
      }
      previous = field.id;
      _byId[field.id] = field;
      _byName[field.name] = field;
    }
  }

  /// Schema id written into every document.
  final int id;

  /// Schema version this declaration represents.
  final int version;

  /// Fields in ascending id order.
  final List<VxsField> fields;

  final Map<int, VxsField> _byId = <int, VxsField>{};
  final Map<String, VxsField> _byName = <String, VxsField>{};

  /// Looks a field up by its stable id.
  VxsField? fieldById(int id) => _byId[id];

  /// Looks a field up by name.
  VxsField? fieldByName(String name) => _byName[name];

  /// Whether [id] is declared.
  bool hasField(int id) => _byId.containsKey(id);
}
