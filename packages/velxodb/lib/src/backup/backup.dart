import 'dart:typed_data';

import '../storage/directory.dart';

/// Summary of a backup or restore.
final class BackupReport {
  /// Creates a report.
  const BackupReport({required this.files, required this.bytes});

  /// Number of files copied.
  final int files;

  /// Total bytes copied.
  final int bytes;

  @override
  String toString() => 'BackupReport(files: $files, bytes: $bytes)';
}

/// Copies every database file from [source] into the empty [target].
///
/// The `LOCK` file is not copied. [target] must contain no files yet (an empty
/// directory created by its backend is fine). Both directories stay owned by
/// the caller; close them after copying.
BackupReport copyDatabase(
  SyncStorageDirectory source,
  SyncStorageDirectory target,
) {
  if (target.listSync().any((name) => name != 'LOCK')) {
    throw StateError('backup target is not empty');
  }
  var files = 0;
  var bytes = 0;
  for (final name in source.listSync()) {
    if (name == 'LOCK') continue;
    final input = source.openSync(name, create: false);
    try {
      final data = Uint8List.fromList(input.readAllSync());
      final output = target.openSync(name);
      try {
        output.writeAllSync(data);
        output.flushSync();
      } finally {
        output.closeSync();
      }
      files++;
      bytes += data.length;
    } finally {
      input.closeSync();
    }
  }
  return BackupReport(files: files, bytes: bytes);
}
