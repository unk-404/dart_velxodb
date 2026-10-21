import 'dart:io';
import 'dart:typed_data';

import '../directory.dart';
import '../file.dart';

/// Real-filesystem implementation of [SyncStorageDirectory].
///
/// This file is only compiled on the VM (see `storage_io.dart`); the web build
/// gets a stub until the OPFS backend lands.
final class LocalStorageDirectory implements SyncStorageDirectory {
  /// Opens (and creates) the directory at [path].
  LocalStorageDirectory(String path) : directory = Directory(path) {
    directory.createSync(recursive: true);
  }

  /// Root directory.
  final Directory directory;

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
