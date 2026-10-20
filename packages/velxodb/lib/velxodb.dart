/// velxodb — an embedded, pure-Dart document database.
///
/// The public surface is intentionally small and layered:
///
/// * `package:velxodb/velxodb.dart` — database, collections, queries.
/// * `package:velxodb/serde.dart` — the zero-copy `VXS` binary format.
/// * `package:velxodb/testing.dart` — conformance kits for custom backends.
library;

/// Semantic version of the package.
const String velxodbVersion = '0.1.0';
