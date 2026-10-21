import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import 'collection.dart';
import 'plan.dart';
import 'types.dart';

/// One field of a typed document.
///
/// Fields carry their own codec so schemas stay plain data and generated code
/// never needs reflection.
final class Field {
  /// Creates a field from explicit codecs.
  Field({
    required this.id,
    required this.name,
    required this.type,
    required this.encode,
    required this.decode,
    this.indexed = false,
    this.nullable = false,
  });

  /// A UTF-8 string field.
  factory Field.string(
    int id,
    String name, {
    bool indexed = false,
    bool nullable = false,
  }) => Field(
    id: id,
    name: name,
    type: VxsType.string,
    indexed: indexed,
    nullable: nullable,
    encode: (builder, value) => builder.putString(id, value as String),
    decode: (view) => view.getString(id),
  );

  /// A 64-bit integer field.
  factory Field.int64(
    int id,
    String name, {
    bool indexed = false,
    bool nullable = false,
  }) => Field(
    id: id,
    name: name,
    type: VxsType.int64,
    indexed: indexed,
    nullable: nullable,
    encode: (builder, value) => builder.putInt(id, value as int),
    decode: (view) => view.getInt(id),
  );

  /// A boolean field.
  factory Field.boolean(
    int id,
    String name, {
    bool indexed = false,
    bool nullable = false,
  }) => Field(
    id: id,
    name: name,
    type: VxsType.boolean,
    indexed: indexed,
    nullable: nullable,
    encode: (builder, value) => builder.putBool(id, value as bool),
    decode: (view) => view.getBool(id),
  );

  /// Field id written into the binary format.
  final int id;

  /// Human-readable name, used by generated code and diagnostics.
  final String name;

  /// Wire type.
  final VxsType type;

  /// Whether this field should get a secondary index.
  final bool indexed;

  /// Whether `null` is a meaningful value rather than "absent".
  final bool nullable;

  /// Writes [value] into [builder].
  final void Function(DocBuilder builder, Object? value) encode;

  /// Reads this field from [view].
  final Object? Function(DocView view) decode;
}

/// Maps a model type to a VXS document and declares its fields.
final class DocumentSchema<T> {
  /// Creates a schema.
  DocumentSchema({
    required this.name,
    required this.fields,
    required this.write,
    required this.read,
  });

  /// Collection name.
  final String name;

  /// Declared fields.
  final List<Field> fields;

  /// Writes model fields into a builder.
  final void Function(T value, DocBuilder builder) write;

  /// Reads a model back from a view.
  final T Function(DocView view) read;

  /// Encodes [value].
  Bytes encode(T value) {
    final builder = DocBuilder(schemaId: 1);
    write(value, builder);
    return builder.finish();
  }

  /// Decodes [bytes].
  T decode(Bytes bytes) => read(DocView.parse(bytes.asUint8List()));

  /// Indexed fields.
  Iterable<Field> get indexedFields => fields.where((field) => field.indexed);
}

/// A collection paired with a typed schema.
final class TypedCollection<T> {
  /// Wraps [collection] with [schema].
  TypedCollection(this.collection, this.schema);

  /// Underlying untyped collection.
  final Collection collection;

  /// Model schema.
  final DocumentSchema<T> schema;

  /// Creates the secondary indexes declared by [schema].
  void ensureIndexes() {
    for (final field in schema.indexedFields) {
      collection.createIndex(field.id, field.type);
    }
  }

  /// Reads [key], or `null`.
  T? getSync(Uint8List key) {
    final bytes = collection.get(key);
    return bytes == null ? null : schema.decode(bytes);
  }

  /// Inserts or replaces [key].
  void putSync(Uint8List key, T value) =>
      collection.putSync(key, schema.encode(value));

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, T value) async => putSync(key, value);

  /// Deletes [key].
  void deleteSync(Uint8List key) => collection.deleteSync(key);

  /// Runs [query] and decodes the matching documents.
  List<T> findSync(Query query) => <T>[
    for (final entry in collection.findSync(query))
      schema.decode(entry.value),
  ];

  /// Scans and decodes, optionally filtering on the model.
  List<ScanEntry> scanSync({int? limit}) =>
      collection.scanSync(limit: limit);
}
