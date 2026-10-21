/// velxodb — an embedded, pure-Dart document database.
///
/// The public surface is intentionally small and layered:
///
/// * `package:velxodb/velxodb.dart` — database, collections, queries.
/// * `package:velxodb/serde.dart` — the zero-copy `VXS` binary format.
/// * `package:velxodb/storage.dart` — the storage engine building blocks.
/// * `package:velxodb/testing.dart` — conformance kits for custom backends.
library;

export 'src/backup/backup.dart';
export 'src/errors.dart';
export 'src/query/catalog.dart' show Catalog, CollectionEntry;
export 'src/query/collection.dart' show Collection;
export 'src/query/cursor.dart' show CollectionCursor;
export 'src/query/database.dart';
export 'src/query/fulltext.dart'
    show
        NgramTokenizer,
        TextIndexDefinition,
        TextQueryMode,
        Tokenizer,
        WordTokenizer;
export 'src/query/graph.dart'
    show EdgeDirection, GraphEdge, GraphStore, NodeRef, RelationCatalog;
export 'src/query/index.dart' show IndexCatalog, IndexDefinition;
export 'src/query/migration.dart'
    show CollectionMigration, MigrationReport, MigrationStep, copyFields;
export 'src/query/plan.dart'
    show Predicate, Query, QueryPlan, ScanStrategy;
export 'src/query/reference.dart'
    show CollectionCatalog, OnDelete, ReferenceCatalog, ReferenceDefinition;
export 'src/query/relation.dart' show RelationDefinition;
export 'src/query/schema.dart'
    show DocumentSchema, Field, TypedCollection;
export 'src/query/types.dart' show ScanEntry, ScanPage;
export 'src/query/velxo.dart';
export 'src/version.dart';
export 'src/worker/worker_client.dart';

/// Semantic version of the package.
const String velxodbVersion = '0.1.0';
