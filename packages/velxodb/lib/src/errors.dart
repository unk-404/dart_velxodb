/// Typed errors thrown by velxodb.
///
/// Everything the database refuses or fails to read maps to one of these, so
/// callers can react without string matching. Programmer mistakes (bad
/// arguments, using an API without a catalog handle) still use standard
/// `ArgumentError` / `StateError`.
library;

/// Base type for every velxodb error.
sealed class VelxoException implements Exception {
  /// Creates an exception with a human-readable [message].
  const VelxoException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The database directory is already open by another writer.
final class VelxoLockedException extends VelxoException {
  /// Creates a lock error.
  const VelxoLockedException(super.message);
}

/// On-disk data could not be decoded or failed a checksum.
final class VelxoCorruptException extends VelxoException {
  /// Creates a corruption error, optionally wrapping [cause].
  const VelxoCorruptException(super.message, [this.cause]);

  /// The underlying decoder error, when there is one.
  final Object? cause;
}

/// The engine or database has been closed.
final class VelxoClosedException extends VelxoException {
  /// Creates a closed-handle error.
  const VelxoClosedException(super.message);
}

/// A conflict with the current transaction state (for example nesting).
final class VelxoConflictException extends VelxoException {
  /// Creates a conflict error.
  const VelxoConflictException(super.message);
}

/// A requested resource (index, text index, target collection) is missing.
final class VelxoNotFoundException extends VelxoException {
  /// Creates a not-found error.
  const VelxoNotFoundException(super.message);
}
