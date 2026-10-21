// blit intentionally exposes the Web backend from src for opt-in use.
// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:typed_data';

import 'package:blit/src/io/bytes_file.dart';
import 'package:blit/src/io/web/web.dart';

import '../../serde/crc32c.dart';
import '../../serde/vxs.dart';
import '../object_store.dart';

/// An [ObjectStore] over the browser's Origin Private File System.
///
/// Each object is a blit chunked `BytesFile`; a small append-only index log
/// makes `list` possible without walking OPFS. The index is written before the
/// object, so a crash can leave a listed-but-missing object (reads return null)
/// but never a committed object that `list` cannot see.
///
/// Must run in a browser. OPFS sync handles are worker-only; blit manages its
/// worker pool transparently.
final class OpfsObjectStore implements ObjectStore {
  OpfsObjectStore._(this._root, this._index, this._keys);

  /// Opens (or creates) a store under the logical OPFS [root].
  static Future<OpfsObjectStore> open({String root = 'velxodb'}) async {
    final normalized = root.endsWith('/') ? root : '$root/';
    final index = await openOpfsBytesFile(
      '${normalized}__index',
      create: true,
      chunkSize: 1 << 20,
    );
    final keys = <String>{};
    try {
      final bytes = await _readAll(index);
      final valid = _replay(bytes, keys);
      if (valid < bytes.length) {
        await index.truncate(valid);
        await index.flush();
      }
    } on Object {
      await index.close();
      rethrow;
    }
    return OpfsObjectStore._(normalized, index, keys);
  }

  final String _root;
  final BytesFile _index;
  final Set<String> _keys;
  bool _closed = false;

  String _objectPath(String key) =>
      '${_root}o_${base64Url.encode(utf8.encode(key))}';

  @override
  Future<Uint8List?> get(String key) async {
    _checkOpen();
    BytesFile? file;
    try {
      file = await openOpfsBytesFile(
        _objectPath(key),
        create: false,
        readOnly: true,
      );
    } on WebFileSystemException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
    try {
      return await _readAll(file);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    _checkOpen();
    // Object first, then the index record. A crash in between leaves an
    // unlisted object (wasted bytes, invisible) rather than a listed key with
    // no object, which would make a committed write unreadable.
    final file = await openOpfsBytesFile(_objectPath(key));
    try {
      await file.writeAt(0, bytes);
      await file.truncate(bytes.length);
      await file.flush();
    } finally {
      await file.close();
    }
    await _appendIndex(1, key);
  }

  @override
  Future<void> delete(String key) async {
    _checkOpen();
    await _appendIndex(2, key);
    try {
      await deleteOpfsFile(_objectPath(key));
    } on WebFileSystemException catch (error) {
      if (!error.isNotFound) rethrow;
    }
  }

  @override
  Future<void> deleteMany(List<String> keys) async {
    for (final key in keys) {
      await delete(key);
    }
  }

  @override
  Future<List<String>> list(String prefix) async {
    _checkOpen();
    final keys = <String>[
      for (final key in _keys)
        if (key.startsWith(prefix)) key,
    ]..sort();
    return keys;
  }

  /// Closes the index handle. Other handle opens are per call.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _index.close();
  }

  Future<void> _appendIndex(int op, String key) async {
    final keyBytes = utf8.encode(key);
    if (keyBytes.length > 0xFFFF) {
      throw ArgumentError.value(key, 'key', 'key is too long');
    }
    final record = Uint8List(1 + 2 + keyBytes.length + 4);
    record[0] = op;
    VxsLe.w16(record, 1, keyBytes.length);
    record.setRange(3, 3 + keyBytes.length, keyBytes);
    final end = 3 + keyBytes.length;
    VxsLe.w32(record, end, VxsCrc32c.compute(record, 0, end));
    await _index.append(record);
    await _index.flush();
    if (op == 1) {
      _keys.add(key);
    } else {
      _keys.remove(key);
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('OPFS object store is closed');
  }

  static int _replay(Uint8List bytes, Set<String> keys) {
    var pos = 0;
    var validEnd = 0;
    while (pos + 1 + 2 + 4 <= bytes.length) {
      final start = pos;
      final op = bytes[pos++];
      final keyLength = VxsLe.u16(bytes, pos);
      pos += 2;
      if (pos + keyLength + 4 > bytes.length) break;
      final keyBytes = Uint8List.sublistView(bytes, pos, pos + keyLength);
      pos += keyLength;
      final crc = VxsLe.u32(bytes, pos);
      pos += 4;
      if (VxsCrc32c.compute(bytes, start, pos - 4) != crc) break;
      final String key;
      try {
        key = utf8.decode(keyBytes);
      } on FormatException {
        // Valid checksum but invalid UTF-8: the record is damaged, treat the
        // rest of the log as a torn tail instead of failing every open.
        break;
      }
      if (op == 1) {
        keys.add(key);
      } else if (op == 2) {
        keys.remove(key);
      } else {
        break;
      }
      validEnd = pos;
    }
    // Truncate at the *start* of the torn record, not after it: otherwise the
    // leftover bytes would be read as a record on the next open and every
    // later index append would be silently dropped.
    return validEnd;
  }

  static Future<Uint8List> _readAll(BytesFile file) async {
    final length = await file.length;
    final out = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final read = await file.readAt(offset, out, start: offset);
      if (read <= 0) break;
      offset += read;
    }
    return out;
  }
}
