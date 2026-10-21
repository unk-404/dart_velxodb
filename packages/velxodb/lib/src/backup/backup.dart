import 'dart:typed_data';

import '../errors.dart';
import '../storage/directory.dart';
import '../upgrade_journal.dart';

/// Copy chunk size: a segment is streamed, never held in memory whole.
const int _copyChunkBytes = 1 << 20;

/// Names that must never be copied into a backup.
const Set<String> _skippedNames = <String>{'LOCK', 'FORMAT.tmp'};

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
/// The `LOCK`, `FORMAT.tmp` and upgrade-journal files are not copied: the first
/// is backend state, the second is a half-written stamp, and copying a journal
/// would make the backup refuse to open. [target] must contain no files yet (an
/// empty directory created by its backend is fine). Files are streamed in
/// chunks, so a large segment is not held in memory.
BackupReport copyDatabase(
  SyncStorageDirectory source,
  SyncStorageDirectory target,
) {
  if (source.existsSync(upgradeJournalFileName)) {
    throw const VelxoUpgradeRequiredException(
      'source has an unfinished upgrade journal; roll it back before backing up',
    );
  }
  if (target.listSync().any((name) => name != 'LOCK')) {
    throw StateError('backup target is not empty');
  }
  var files = 0;
  var bytes = 0;
  for (final name in source.listSync()) {
    if (_skippedNames.contains(name)) continue;
    final input = source.openSync(name, create: false);
    try {
      final length = input.lengthSync;
      final output = target.openSync(name);
      try {
        var offset = 0;
        while (offset < length) {
          final take = length - offset < _copyChunkBytes
              ? length - offset
              : _copyChunkBytes;
          output.appendSync(Uint8List.fromList(input.readAtSync(offset, take)));
          offset += take;
        }
        output.flushSync();
      } finally {
        output.closeSync();
      }
      files++;
      bytes += length;
    } finally {
      input.closeSync();
    }
  }
  return BackupReport(files: files, bytes: bytes);
}
