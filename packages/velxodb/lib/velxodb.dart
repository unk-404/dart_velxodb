/// velxodb — an embedded, pure-Dart document database.
///
/// The public surface is intentionally small and layered:
///
/// * `package:velxodb/velxodb.dart` — database, collections, queries.
/// * `package:velxodb/serde.dart` — the zero-copy `VXS` binary format.
/// * `package:velxodb/storage.dart` — the storage engine building blocks.
/// * `package:velxodb/testing.dart` — conformance kits for custom backends.
library;

export 'src/query/catalog.dart' show Catalog, CollectionEntry;
export 'src/query/collection.dart' show Collection;
export 'src/query/cursor.dart' show CollectionCursor;
export 'src/query/database.dart';
export 'src/query/types.dart' show ScanEntry;
export 'src/query/velxo.dart';

/// Semantic version of the package.
const String velxodbVersion = '0.1.0';
