import 'dart:typed_data';

import 'errors.dart';
import 'serde/crc32c.dart';
import 'serde/vxs.dart';
import 'storage/directory.dart';
import 'upgrade_journal.dart';

/// On-disk format major version.
///
/// Bumping this requires an explicit, backed-up upgrade and a downgrade path.
const int formatMajor = 1;

/// On-disk format minor version.
///
/// Bumping this is implicitly upgraded inside the same [formatMajor].
const int formatMinor = 0;

/// Name of the root format stamp.
const String formatFileName = 'FORMAT';

/// Magic bytes of the format stamp.
const List<int> formatMagic = <int>[0x56, 0x58, 0x46, 0x4D]; // "VXFM"

/// Reads the format stamp, or `null` when the database predates stamping.
({int major, int minor})? readFormatStamp(SyncStorageDirectory directory) {
  if (!directory.existsSync(formatFileName)) return null;
  final file = directory.openSync(formatFileName, create: false);
  try {
    final bytes = file.readAllSync();
    if (bytes.length != 12) {
      throw const VelxoCorruptException('FORMAT stamp has an invalid length');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != formatMagic[i]) {
        throw const VelxoCorruptException('FORMAT stamp has a bad magic');
      }
    }
    final expected = VxsLe.u32(bytes, 8);
    if (VxsCrc32c.compute(bytes, 0, 8) != expected) {
      throw const VelxoCorruptException('FORMAT stamp checksum mismatch');
    }
    return (major: VxsLe.u16(bytes, 4), minor: VxsLe.u16(bytes, 6));
  } finally {
    file.closeSync();
  }
}

/// Writes the current format stamp.
void writeFormatStamp(SyncStorageDirectory directory) {
  final bytes = Uint8List(12);
  bytes.setRange(0, 4, formatMagic);
  VxsLe.w16(bytes, 4, formatMajor);
  VxsLe.w16(bytes, 6, formatMinor);
  VxsLe.w32(bytes, 8, VxsCrc32c.compute(bytes, 0, 8));
  final file = directory.openSync(formatFileName);
  try {
    file.writeAllSync(bytes);
    file.flushSync();
  } finally {
    file.closeSync();
  }
}

/// Enforces the version policy before a database is opened.
///
/// - missing stamp: treated as 1.0, written on a writable open;
/// - newer major: [VelxoIncompatibleException];
/// - older major: [VelxoUpgradeRequiredException];
/// - same major: accepted, and an older minor is stamped forward on write.
void checkFormatCompatibility(
  SyncStorageDirectory directory, {
  required bool readOnly,
}) {
  if (directory.existsSync(upgradeJournalFileName)) {
    throw const VelxoUpgradeRequiredException(
      'an upgrade journal is present: the upgrade did not finish. Run '
      'VelxoDatabase.rollbackUpgradeSync(path)',
    );
  }
  final stamp = readFormatStamp(directory);
  if (stamp == null) {
    if (!readOnly) writeFormatStamp(directory);
    return;
  }
  if (stamp.major > formatMajor) {
    throw VelxoIncompatibleException(
      'database format ${stamp.major}.${stamp.minor} is newer than '
      'this build ($formatMajor.$formatMinor)',
    );
  }
  if (stamp.major < formatMajor) {
    throw VelxoUpgradeRequiredException(
      'database format ${stamp.major}.${stamp.minor} needs an explicit '
      'upgrade to $formatMajor.$formatMinor; run '
      'VelxoDatabase.upgradeSync(path)',
    );
  }
  if (!readOnly && stamp.minor < formatMinor) {
    writeFormatStamp(directory);
  }
}
