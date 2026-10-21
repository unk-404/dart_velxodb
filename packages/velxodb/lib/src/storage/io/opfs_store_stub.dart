import 'dart:typed_data';

import '../object_store.dart';

/// Web-only store; the VM build cannot reach this implementation.
final class OpfsObjectStore implements ObjectStore {
  static Future<OpfsObjectStore> open({String root = 'velxodb'}) async {
    throw UnsupportedError('OPFS is only available in a browser build');
  }

  @override
  Future<Uint8List?> get(String key) => Future<Uint8List?>.error(_unsupported);

  @override
  Future<void> put(String key, Uint8List bytes) =>
      Future<void>.error(_unsupported);

  @override
  Future<void> delete(String key) => Future<void>.error(_unsupported);

  @override
  Future<void> deleteMany(List<String> keys) =>
      Future<void>.error(_unsupported);

  @override
  Future<List<String>> list(String prefix) =>
      Future<List<String>>.error(_unsupported);

  Future<void> close() => Future<void>.error(_unsupported);

  static final UnsupportedError _unsupported = UnsupportedError(
    'OPFS is only available in a browser build',
  );
}
