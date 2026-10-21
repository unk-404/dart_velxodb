import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/builder.dart';
import '../serde/schema.dart';
import '../serde/view.dart';
import 'collection.dart';
import 'plan.dart';
import 'reference.dart';

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
    this.target,
    this.onDelete,
  });

  /// A reference field pointing at [target]'s key.
  factory Field.reference(
    int id,
    String name, {
    required String target,
    OnDelete onDelete = OnDelete.restrict,
    bool nullable = false,
  }) => Field(
    id: id,
    name: name,
    type: VxsType.string,
    indexed: true,
    nullable: nullable,
    target: target,
    onDelete: onDelete,
    encode: (builder, value) => builder.putString(id, value as String),
    decode: (view) => view.getString(id),
  );

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

  /// Target collection name when this field is a reference.
  final String? target;

  /// Delete behaviour for a reference field.
  final OnDelete? onDelete;

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
    this.schemaId = 1,
    this.version = 1,
  });

  /// Collection name.
  final String name;

  /// Declared fields.
  final List<Field> fields;

  /// Schema id written into document headers.
  final int schemaId;

  /// Schema version written into document headers.
  final int version;

  /// Writes model fields into a builder.
  final void Function(T value, DocBuilder builder) write;

  /// Reads a model back from a view.
  final T Function(DocView view) read;

  /// Encodes [value].
  Bytes encode(T value) {
    final builder = DocBuilder(schemaId: schemaId, schemaVersion: version);
    write(value, builder);
    return builder.finish();
  }

  /// Decodes [bytes].
  T decode(Bytes bytes) => read(DocView.parse(bytes.asUint8List()));

  /// Indexed fields.
  Iterable<Field> get indexedFields => fields.where((field) => field.indexed);
}

/// A collection paired with typed encode/decode functions.
///
/// Direct functions (usually static method tear-offs from generated code) keep
/// the hot path free of schema objects and per-document indirection through a
/// closure field; [TypedCollection.schema] is available when a
/// [DocumentSchema] is what you have.
final class TypedCollection<T> {
  /// Wraps [collection] with direct codec functions.
  TypedCollection(
    this.collection,
    this.encodeValue,
    this.decodeValue, {
    this.schemaId = 1,
    this.version = 1,
  }) : schema = null;

  /// Wraps [collection] with a [DocumentSchema].
  TypedCollection.schema(
    this.collection,
    DocumentSchema<T> schema, {
    this.schemaId = 1,
    this.version = 1,
  }) : schema = schema,
       encodeValue = ((value, builder) => schema.write(value, builder)),
       decodeValue = schema.read;

  /// Underlying untyped collection.
  final Collection collection;

  /// Schema this handle was opened with, when using [TypedCollection.schema].
  final DocumentSchema<T>? schema;

  /// Writes a model into a builder.
  final void Function(T value, DocBuilder builder) encodeValue;

  /// Reads a model from a view.
  final T Function(DocView view) decodeValue;

  /// Schema id stored in the document header.
  final int schemaId;

  /// Schema version stored in the document header.
  final int version;

  /// Creates the indexes and reference bindings declared by [schema].
  ///
  /// Generated code emits its own equivalent; this is for hand-written schemas.
  void ensureIndexes() {
    final source = schema;
    if (source == null) {
      throw StateError('this handle has no DocumentSchema; call ensureIndexes '
          'through the generated open() instead');
    }
    for (final field in source.fields) {
      if (field.indexed) collection.createIndex(field.id, field.type);
      final target = field.target;
      if (target != null) {
        collection.createReference(
          field.id,
          target,
          onDelete: field.onDelete ?? OnDelete.restrict,
        );
      }
    }
  }

  /// Reads [key], or `null`.
  T? getSync(Uint8List key) {
    final bytes = collection.get(key);
    if (bytes == null) return null;
    return decodeValue(DocView.parse(bytes.asUint8List()));
  }

  /// Inserts or replaces [key] at the current schema version.
  void putSync(Uint8List key, T value) {
    final builder = DocBuilder(
      schemaId: schemaId,
      schemaVersion: version,
    );
    encodeValue(value, builder);
    collection.putSync(key, builder.finish());
  }

  /// Async facade over [putSync].
  Future<void> put(Uint8List key, T value) async => putSync(key, value);

  /// Deletes [key].
  void deleteSync(Uint8List key) => collection.deleteSync(key);

  /// Runs [query] and decodes the matching documents.
  List<T> findSync(Query query) => <T>[
    for (final entry in collection.findSync(query))
      decodeValue(DocView.parse(entry.value.asUint8List())),
  ];

  /// Scans and decodes, optionally limiting.
  List<T> scanSync({int? limit}) => <T>[
    for (final entry in collection.scanSync(limit: limit))
      decodeValue(DocView.parse(entry.value.asUint8List())),
  ];
}
