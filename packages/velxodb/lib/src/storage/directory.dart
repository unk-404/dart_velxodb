import 'dart:typed_data';

import 'file.dart';

/// Minimal directory abstraction for the local engine.
///
/// The engine owns exactly three kinds of files: the WAL, one or two manifest
/// slots, and immutable segments. It needs to create, list, rename and delete
/// them — nothing else.
abstract interface class SyncStorageDirectory {
  /// Opens (and by default creates) the named file.
  SyncStorageFile openSync(String name, {bool create = true});

  /// Whether a file with that name exists.
  bool existsSync(String name);

  /// Deletes the named file if it exists.
  void deleteSync(String name);

  /// Renames [from] to [to], replacing [to].
  void renameSync(String from, String to);

  /// Names of all files, sorted.
  List<String> listSync();
}

/// In-memory directory used by tests and benchmarks.
final class MemoryStorageDirectory implements SyncStorageDirectory {
  final Map<String, MemoryStorageFile> _files = <String, MemoryStorageFile>{};

  @override
  SyncStorageFile openSync(String name, {bool create = true}) {
    final existing = _files[name];
    if (existing != null) {
      if (!existing.isClosed) return existing;
      // Closing a file must not lose its bytes: reopen over a fresh handle
      // that starts with the same contents, mirroring a real filesystem.
      final restored = MemoryStorageFile(existing.bytes.length + 64);
      restored.writeAllSync(existing.bytes);
      _files[name] = restored;
      return restored;
    }
    if (!create) throw StateError('no such file: $name');
    final file = MemoryStorageFile();
    _files[name] = file;
    return file;
  }

  @override
  bool existsSync(String name) => _files.containsKey(name);

  @override
  void deleteSync(String name) => _files.remove(name);

  @override
  void renameSync(String from, String to) {
    final file = _files.remove(from);
    if (file == null) throw StateError('no such file: $from');
    _files[to] = file;
  }

  @override
  List<String> listSync() => _files.keys.toList()..sort();

  /// Raw bytes of a file, for assertions.
  Uint8List? bytesOf(String name) => _files[name]?.bytes;
}
