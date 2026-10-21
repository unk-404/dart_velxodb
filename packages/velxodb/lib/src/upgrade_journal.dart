import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'serde/crc32c.dart';
import 'serde/vxs.dart';
import 'storage/directory.dart';

/// Name of the in-place upgrade undo journal.
const String upgradeJournalFileName = 'UPGRADE-JOURNAL';

const List<int> _journalMagic = <int>[0x56, 0x58, 0x55, 0x4A]; // "VXUJ"
const int _journalVersion = 1;
const int _journalHeaderSize = 8;

enum _JournalOp { writeRange, createFile, deleteFile }

final class _JournalRecord {
  const _JournalRecord(this.op, this.name, this.offset, this.data);
  final _JournalOp op;
  final String name;
  final int offset;
  final Uint8List data;
}

/// An in-place undo journal for an A-major upgrade.
///
/// Before a format upgrade mutates a file, it records the original bytes for
/// the affected range (or the full content of a file it deletes). [rollback]
/// applies the records in reverse, restoring the exact pre-upgrade bytes. The
/// journal is not a copy of the database: it stores only original ranges and
/// files that the upgrade creates or removes.
///
/// Callers must record a change *before* performing it, and flush the journal
/// first. The journal lives inside the database directory so it is crash-safe
/// with the data it protects.
final class UpgradeJournal {
  /// Creates a journal over [directory].
  UpgradeJournal(this.directory, {this.fileName = upgradeJournalFileName});

  /// Directory holding the journal and the database files.
  final SyncStorageDirectory directory;

  /// Journal file name inside [directory].
  final String fileName;

  /// Whether a journal file exists.
  bool get exists => directory.existsSync(fileName);

  /// Starts a new, empty journal, replacing any previous one.
  void begin() {
    final file = directory.openSync(fileName);
    try {
      final header = Uint8List(_journalHeaderSize);
      header.setRange(0, 4, _journalMagic);
      VxsLe.w16(header, 4, _journalVersion);
      file.writeAllSync(header);
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }

  /// Records the original bytes of `[offset, offset + original.length)`.
  void recordWrite(String name, int offset, Uint8List original) {
    _append(_JournalOp.writeRange, name, offset, original);
  }

  /// Records that [name] did not exist before the upgrade.
  void recordCreate(String name) {
    _append(_JournalOp.createFile, name, 0, Uint8List(0));
  }

  /// Records that [name] is about to be deleted, with its full content.
  void recordDelete(String name, Uint8List original) {
    _append(_JournalOp.deleteFile, name, 0, original);
  }

  /// Applies every recorded change in reverse and removes the journal.
  void rollback() {
    final records = _read();
    for (final record in records.reversed) {
      switch (record.op) {
        case _JournalOp.writeRange:
          _restoreRange(record.name, record.offset, record.data);
        case _JournalOp.createFile:
          if (directory.existsSync(record.name)) {
            directory.deleteSync(record.name);
          }
        case _JournalOp.deleteFile:
          _writeWhole(record.name, record.data);
      }
    }
    discard();
  }

  /// Deletes the journal without restoring anything.
  void discard() {
    if (directory.existsSync(fileName)) {
      directory.deleteSync(fileName);
    }
  }

  void _append(
    _JournalOp op,
    String name,
    int offset,
    Uint8List data,
  ) {
    if (!exists) {
      throw StateError('upgrade journal has not been started');
    }
    final nameBytes = utf8.encode(name);
    final bodyLength = 1 + 2 + nameBytes.length + 8 + 4 + data.length;
    final record = Uint8List(bodyLength + 4);
    record[0] = op.index + 1;
    VxsLe.w16(record, 1, nameBytes.length);
    record.setRange(3, 3 + nameBytes.length, nameBytes);
    var pos = 3 + nameBytes.length;
    VxsLe.w64(record, pos, offset);
    pos += 8;
    VxsLe.w32(record, pos, data.length);
    pos += 4;
    record.setRange(pos, pos + data.length, data);
    pos += data.length;
    VxsLe.w32(record, pos, VxsCrc32c.compute(record, 0, pos));

    final file = directory.openSync(fileName);
    try {
      file.appendSync(record);
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }

  List<_JournalRecord> _read() {
    if (!exists) return const <_JournalRecord>[];
    final file = directory.openSync(fileName, create: false);
    final bytes = Uint8List.fromList(file.readAllSync());
    file.closeSync();
    if (bytes.length < _journalHeaderSize ||
        bytes[0] != _journalMagic[0] ||
        bytes[1] != _journalMagic[1] ||
        bytes[2] != _journalMagic[2] ||
        bytes[3] != _journalMagic[3] ||
        VxsLe.u16(bytes, 4) != _journalVersion) {
      throw const VelxoCorruptException('UPGRADE-JOURNAL has a bad header');
    }
    final records = <_JournalRecord>[];
    var pos = _journalHeaderSize;
    while (pos + 1 + 2 + 8 + 4 + 4 <= bytes.length) {
      final start = pos;
      final opCode = bytes[pos++];
      final nameLength = VxsLe.u16(bytes, pos);
      pos += 2;
      if (pos + nameLength + 8 + 4 > bytes.length) break;
      final name = utf8.decode(
        Uint8List.sublistView(bytes, pos, pos + nameLength),
      );
      pos += nameLength;
      final offset = VxsLe.u64(bytes, pos);
      pos += 8;
      final dataLength = VxsLe.u32(bytes, pos);
      pos += 4;
      if (pos + dataLength + 4 > bytes.length) break;
      final data = Uint8List.sublistView(bytes, pos, pos + dataLength);
      pos += dataLength;
      final crc = VxsLe.u32(bytes, pos);
      pos += 4;
      if (VxsCrc32c.compute(bytes, start, pos - 4) != crc) break;
      final op = switch (opCode) {
        1 => _JournalOp.writeRange,
        2 => _JournalOp.createFile,
        3 => _JournalOp.deleteFile,
        _ => null,
      };
      if (op == null) break;
      records.add(_JournalRecord(op, name, offset, data));
    }
    return records;
  }

  void _restoreRange(String name, int offset, Uint8List original) {
    final file = directory.openSync(name);
    try {
      final current = file.readAllSync();
      final needed = offset + original.length;
      final out = Uint8List(
        current.length > needed ? current.length : needed,
      );
      out.setRange(0, current.length, current);
      out.setRange(offset, offset + original.length, original);
      file.writeAllSync(out);
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }

  void _writeWhole(String name, Uint8List bytes) {
    final file = directory.openSync(name);
    try {
      file.writeAllSync(bytes);
      file.flushSync();
    } finally {
      file.closeSync();
    }
  }
}
