import 'dart:typed_data';

import 'package:velxodb/storage.dart';

/// Test-only helpers that model "the process died": they copy a directory's
/// bytes, then restore a chosen subset into a fresh directory. Production code
/// never sees this file.
///
/// Handles are intentionally left open: `MemoryStorageDirectory` returns the
/// same handle for an open file, so closing a snapshot handle would close the
/// engine's own WAL handle.
Map<String, Uint8List> snapshot(SyncStorageDirectory directory) {
  final files = <String, Uint8List>{};
  for (final name in directory.listSync()) {
    final file = directory.openSync(name, create: false);
    files[name] = Uint8List.fromList(file.readAllSync());
  }
  return files;
}

void restore(SyncStorageDirectory directory, Map<String, Uint8List> files) {
  for (final name in directory.listSync()) {
    if (!files.containsKey(name)) directory.deleteSync(name);
  }
  for (final entry in files.entries) {
    final file = directory.openSync(entry.key);
    file.writeAllSync(entry.value);
  }
}

Uint8List readFile(SyncStorageDirectory directory, String name) {
  final file = directory.openSync(name, create: false);
  return Uint8List.fromList(file.readAllSync());
}

void writeFile(
  SyncStorageDirectory directory,
  String name,
  Uint8List bytes,
) {
  final file = directory.openSync(name);
  file.writeAllSync(bytes);
}

int fileLength(SyncStorageDirectory directory, String name) {
  final file = directory.openSync(name, create: false);
  return file.lengthSync;
}
