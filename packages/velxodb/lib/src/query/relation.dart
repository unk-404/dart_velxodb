/// A named relation (edge type) registered in the catalog.
final class RelationDefinition {
  /// Creates a relation definition.
  const RelationDefinition(this.id, this.name);

  /// Stable two-byte namespace id.
  final int id;

  /// Relation name, for example `follows` or `member_of`.
  final String name;
}
