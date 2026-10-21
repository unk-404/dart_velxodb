/// Placeholder for non-web builds.
///
/// The OPFS database only runs in a browser, where
/// `opfs_write_lock_web.dart` takes a real origin-wide Web Lock.
final class OpfsWriteLock {
  OpfsWriteLock._();

  /// Returns a lock that excludes nothing (non-web build).
  static Future<OpfsWriteLock> acquire(String name) async => OpfsWriteLock._();

  /// Releases the lock. A no-op here.
  Future<void> release() async {}
}
