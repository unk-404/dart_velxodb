import 'database.dart';

/// Entry point for opening an embedded database.
///
/// ```dart
/// final db = await Velxo.open('data/chat');
/// final messages = db.collection('messages');
/// messages.putSync(key, encodedDocument);
/// ```
final class Velxo {
  const Velxo._();

  /// Opens (and creates) the database at [path] synchronously.
  ///
  /// The local engine is synchronous by design; this is the real entry point.
  static VelxoDatabase openSync(String path) => VelxoDatabase.openSync(path);

  /// Async facade over [openSync].
  static Future<VelxoDatabase> open(String path) => VelxoDatabase.open(path);
}
