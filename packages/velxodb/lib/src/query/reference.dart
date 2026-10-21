import 'index.dart';

/// What happens to referring documents when the target is deleted.
enum OnDelete {
  /// Refuse the delete while any document still references the target.
  restrict,

  /// Delete every referring document (recursively, depth-limited).
  cascade,

  /// Not implemented yet: clearing the field needs a schema-aware rewrite.
  setNull,
}

/// A reference binding: `source.fieldId` holds the key of a document in
/// `targetCollectionId`.
final class ReferenceDefinition {
  /// Creates a reference definition.
  const ReferenceDefinition({
    required this.sourceCollectionId,
    required this.fieldId,
    required this.targetCollectionId,
    required this.onDelete,
  });

  /// Collection that owns the field.
  final int sourceCollectionId;

  /// Field id holding the target key.
  final int fieldId;

  /// Collection the key points into.
  final int targetCollectionId;

  /// Behaviour when a target is deleted.
  final OnDelete onDelete;
}

/// Catalog capabilities needed by reference bindings.
abstract interface class ReferenceCatalog {
  /// Looks up a reference by `(source, field)`.
  ReferenceDefinition? referenceFor(int collectionId, int fieldId);

  /// References declared by [collectionId].
  List<ReferenceDefinition> referencesFor(int collectionId);

  /// References pointing at [collectionId].
  List<ReferenceDefinition> referencesTo(int collectionId);

  /// Persists a reference binding and returns it.
  ReferenceDefinition registerReference(
    int sourceCollectionId,
    int fieldId,
    int targetCollectionId,
    OnDelete onDelete,
  );

  /// Resolves a collection name, or `null`.
  int? collectionIdOf(String name);
}

/// Everything a [Collection] needs from the catalog.
abstract interface class CollectionCatalog
    implements IndexCatalog, ReferenceCatalog {}
