import 'dart:typed_data';

/// Minimal object-store contract.
///
/// Real adapters (S3, GCS, R2) implement this with HTTP; tests and benchmarks
/// use [SimulatedObjectStore]. Keys are flat strings; Slash-separated prefixes
/// are the only hierarchy.
abstract interface class ObjectStore {
  /// Reads [key], or `null` when absent.
  Future<Uint8List?> get(String key);

  /// Creates or replaces [key].
  Future<void> put(String key, Uint8List bytes);

  /// Deletes [key]. Missing keys are ignored.
  Future<void> delete(String key);

  /// Deletes several keys with one request (S3 `DeleteObjects`).
  Future<void> deleteMany(List<String> keys);

  /// Lists keys starting with [prefix].
  Future<List<String>> list(String prefix);
}

/// Request and byte counters for one phase of object-store work.
final class ObjectStoreStats {
  /// Creates a snapshot.
  const ObjectStoreStats({
    this.gets = 0,
    this.puts = 0,
    this.deletes = 0,
    this.lists = 0,
    this.requestBytes = 0,
    this.responseBytes = 0,
  });

  /// GET requests.
  final int gets;

  /// PUT requests.
  final int puts;

  /// DELETE requests.
  final int deletes;

  /// LIST requests.
  final int lists;

  /// Bytes sent to the service (keys + payloads).
  final int requestBytes;

  /// Bytes received from the service (values + listing names).
  final int responseBytes;

  /// Total requests.
  int get requests => gets + puts + deletes + lists;

  /// Total responses. Every request is answered, including 404-style misses.
  int get responses => requests;

  /// Difference between two snapshots.
  ObjectStoreStats operator -(ObjectStoreStats other) => ObjectStoreStats(
    gets: gets - other.gets,
    puts: puts - other.puts,
    deletes: deletes - other.deletes,
    lists: lists - other.lists,
    requestBytes: requestBytes - other.requestBytes,
    responseBytes: responseBytes - other.responseBytes,
  );

  /// Compact description for logs.
  String describe() =>
      'req=$requests (get=$gets put=$puts del=$deletes list=$lists) '
      'out=${_mb(requestBytes)} in=${_mb(responseBytes)}';

  static String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(1)}MB';
}

/// In-memory object store that counts every request and byte.
///
/// Values are shared by reference (no copy on read), which is the point: the
/// benchmark measures the engine's request shape, not a memcpy.
final class SimulatedObjectStore implements ObjectStore {
  final Map<String, Uint8List> _objects = <String, Uint8List>{};
  ObjectStoreStats _stats = const ObjectStoreStats();

  /// Current counters.
  ObjectStoreStats get stats => _stats;

  /// Number of stored objects.
  int get objectCount => _objects.length;

  /// Total stored payload bytes.
  int get storedBytes {
    var total = 0;
    for (final value in _objects.values) {
      total += value.length;
    }
    return total;
  }

  /// Keys currently stored, sorted.
  List<String> keys() => _objects.keys.toList()..sort();

  @override
  Future<Uint8List?> get(String key) async {
    final value = _objects[key];
    _stats = ObjectStoreStats(
      gets: _stats.gets + 1,
      puts: _stats.puts,
      deletes: _stats.deletes,
      lists: _stats.lists,
      requestBytes: _stats.requestBytes + key.length,
      responseBytes: _stats.responseBytes + (value?.length ?? 0),
    );
    return value;
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    _objects[key] = bytes;
    _stats = ObjectStoreStats(
      gets: _stats.gets,
      puts: _stats.puts + 1,
      deletes: _stats.deletes,
      lists: _stats.lists,
      requestBytes: _stats.requestBytes + key.length + bytes.length,
      responseBytes: _stats.responseBytes,
    );
  }

  @override
  Future<void> delete(String key) => deleteMany(<String>[key]);

  @override
  Future<void> deleteMany(List<String> keys) async {
    if (keys.isEmpty) return;
    var bytes = 0;
    for (final key in keys) {
      _objects.remove(key);
      bytes += key.length;
    }
    _stats = ObjectStoreStats(
      gets: _stats.gets,
      puts: _stats.puts,
      deletes: _stats.deletes + 1,
      lists: _stats.lists,
      requestBytes: _stats.requestBytes + bytes,
      responseBytes: _stats.responseBytes,
    );
  }

  @override
  Future<List<String>> list(String prefix) async {
    final matches = <String>[
      for (final key in _objects.keys)
        if (key.startsWith(prefix)) key,
    ];
    var bytes = 0;
    for (final key in matches) {
      bytes += key.length;
    }
    _stats = ObjectStoreStats(
      gets: _stats.gets,
      puts: _stats.puts,
      deletes: _stats.deletes,
      lists: _stats.lists + 1,
      requestBytes: _stats.requestBytes + prefix.length,
      responseBytes: _stats.responseBytes + bytes,
    );
    return matches;
  }
}
