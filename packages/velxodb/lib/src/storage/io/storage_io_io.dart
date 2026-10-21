import 'dart:io';
import 'dart:typed_data';

import 'package:blit/bytes_ffi.dart' show MappedRegion, MmapFile, openMmapFileSync;

import '../directory.dart';
import '../file.dart';

/// Real-filesystem implementation of [SyncStorageDirectory].
///
/// This file is only compiled on the VM (see `storage_io.dart`); the web build
/// gets a stub until the OPFS backend lands.
final class LocalStorageDirectory implements SyncStorageDirectory {
  /// Opens (and creates) the directory at [path] and takes an exclusive lock.
  ///
  /// A second open of the same directory fails fast instead of letting two
  /// engines corrupt each other's WAL and segments.
  LocalStorageDirectory(String path) : directory = Directory(path) {
    directory.createSync(recursive: true);
    final lock = File('${directory.path}${Platform.pathSeparator}LOCK');
    final handle = lock.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
    } on FileSystemException {
      handle.closeSync();
      throw StateError('database is already open: ${directory.path}');
    }
    _lock = handle;
  }

  /// Root directory.
  final Directory directory;

  RandomAccessFile? _lock;

  @override
  void closeSync() {
    _lock?.closeSync();
    _lock = null;
  }

  @override
  SyncStorageFile openSync(String name, {bool create = true}) {
    final file = File(_pathOf(name));
    if (!file.existsSync()) {
      if (!create) throw StateError('no such file: $name');
      file.createSync(recursive: true);
    }
    return LocalStorageFile(file.openSync(mode: FileMode.append), file.path);
  }

  @override
  bool existsSync(String name) => File(_pathOf(name)).existsSync();

  @override
  void deleteSync(String name) {
    final file = File(_pathOf(name));
    if (file.existsSync()) file.deleteSync();
  }

  @override
  void renameSync(String from, String to) {
    File(_pathOf(from)).renameSync(_pathOf(to));
  }

  @override
  List<String> listSync() {
    final names = <String>[];
    for (final entity in directory.listSync()) {
      if (entity is File) {
        names.add(entity.uri.pathSegments.last);
      }
    }
    names.sort();
    return names;
  }

  @override
  MappedFile mapSync(String name) {
    final path = _pathOf(name);
    final file = openMmapFileSync(path, create: false, readOnly: true);
    try {
      return _LocalMappedFile(file, file.map(writable: false));
    } catch (_) {
      file.close();
      rethrow;
    }
  }

  String _pathOf(String name) =>
      '${directory.path}${Platform.pathSeparator}$name';
}

/// [SyncStorageFile] over a `RandomAccessFile`.
final class LocalStorageFile implements SyncStorageFile {
  /// Wraps an open file.
  LocalStorageFile(this._file, this.path);

  final RandomAccessFile _file;

  /// Absolute path of the file.
  final String path;

  bool _closed = false;

  @override
  int get lengthSync {
    _checkOpen();
    return _file.lengthSync();
  }

  @override
  void appendSync(Uint8List bytes) {
    _checkOpen();
    _file.setPositionSync(_file.lengthSync());
    _file.writeFromSync(bytes);
  }

  @override
  Uint8List readAtSync(int offset, int length) {
    _checkOpen();
    if (offset < 0 || length < 0 || offset + length > lengthSync) {
      throw RangeError('read [$offset, ${offset + length}) outside file');
    }
    _file.setPositionSync(offset);
    return _file.readSync(length);
  }

  @override
  void truncateSync(int length) {
    _checkOpen();
    _file.truncateSync(length);
  }

  @override
  void flushSync() {
    _checkOpen();
    _file.flushSync();
  }

  @override
  Uint8List readAllSync() => readAtSync(0, lengthSync);

  @override
  void writeAllSync(Uint8List bytes) {
    _checkOpen();
    _file.truncateSync(0);
    _file.setPositionSync(0);
    _file.writeFromSync(bytes);
  }

  @override
  void closeSync() {
    if (_closed) return;
    _closed = true;
    _file.closeSync();
  }

  void _checkOpen() {
    if (_closed) throw StateError('file is closed');
  }
}

/// Read-only mmap of a whole file.
final class _LocalMappedFile implements MappedFile {
  _LocalMappedFile(this._file, this._region);

  final MmapFile _file;
  final MappedRegion _region;

  @override
  Uint8List get bytes => _region.bytes;

  @override
  void closeSync() {
    _region.close();
    _file.close();
  }
}
