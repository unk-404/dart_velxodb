import 'dart:typed_data';

import '../directory.dart';
import '../file.dart';

/// Web build placeholder for the local engine's directory.
///
/// The local engine needs synchronous file access, which browsers do not offer
/// on the main thread. A future OPFS backend will implement [SyncStorageFile]
/// on top of `FileSystemSyncAccessHandle` inside a worker; until then this
/// throws a clear error instead of failing at an import.
final class LocalStorageDirectory implements SyncStorageDirectory {
  /// Always throws [UnsupportedError].
  LocalStorageDirectory(String path) {
    throw UnsupportedError(
      'the local storage engine is not available in this build; '
      'use an object-store backend on the web',
    );
  }

  @override
  SyncStorageFile openSync(String name, {bool create = true}) => _unsupported();

  @override
  bool existsSync(String name) => _unsupported();

  @override
  void deleteSync(String name) => _unsupported();

  @override
  void renameSync(String from, String to) => _unsupported();

  @override
  List<String> listSync() => _unsupported();

  Never _unsupported() => throw UnsupportedError('no local storage on the web');
}

/// Web build placeholder for a local file.
final class LocalStorageFile implements SyncStorageFile {
  @override
  int get lengthSync => _unsupported();

  @override
  void appendSync(Uint8List bytes) => _unsupported();

  @override
  Uint8List readAtSync(int offset, int length) => _unsupported();

  @override
  void truncateSync(int length) => _unsupported();

  @override
  void flushSync() => _unsupported();

  @override
  Uint8List readAllSync() => _unsupported();

  @override
  void writeAllSync(Uint8List bytes) => _unsupported();

  @override
  void closeSync() => _unsupported();

  Never _unsupported() => throw UnsupportedError('no local storage on the web');
}
