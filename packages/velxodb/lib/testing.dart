/// Conformance kit for custom [ObjectStore] backends.
///
/// velxodb ships no cloud adapter: `ObjectStore` is the integration point, and
/// a backend is "correct" when it satisfies this suite. Wrap any implementation
/// in an [ObjectStoreConformance] run — in CI, in an integration test, or as a
/// smoke check before deploying a new adapter.
///
/// ```dart
/// import 'package:velxodb/testing.dart';
///
/// await ObjectStoreConformance(prefix: 'ci/').run(myStore);
/// ```
library;

import 'dart:typed_data';

import 'src/storage/object_store.dart';

/// Thrown when a backend violates the [ObjectStore] contract.
final class ObjectStoreConformanceException implements Exception {
  /// Creates a failure with the check name and a human-readable [message].
  const ObjectStoreConformanceException(this.check, this.message);

  /// Name of the failed check.
  final String check;

  /// What was expected and what the backend did.
  final String message;

  @override
  String toString() => 'ObjectStoreConformanceException($check): $message';
}

/// Runs the [ObjectStore] contract against one implementation.
///
/// Every check uses keys under [prefix], so a shared bucket can be used as long
/// as the prefix is unique. The suite leaves no keys behind on success.
final class ObjectStoreConformance {
  /// Creates a suite that writes under [prefix].
  const ObjectStoreConformance({this.prefix = 'velxodb-conformance/'});

  /// Key prefix owned by this run.
  final String prefix;

  /// Runs every check in order, throwing on the first violation.
  Future<void> run(ObjectStore store) async {
    final created = <String>[];
    try {
      await _checkMissing(store);
      await _checkRoundTrip(store, created);
      await _checkOverwrite(store, created);
      await _checkLargeValue(store, created);
      await _checkDelete(store, created);
      await _checkDeleteMany(store, created);
      await _checkList(store, created);
    } finally {
      if (created.isNotEmpty) {
        try {
          await store.deleteMany(created);
        } on Object {
          // Best effort cleanup; a failing backend has already failed a check.
        }
      }
    }
  }

  Future<void> _checkMissing(ObjectStore store) async {
    final missing = await store.get('${prefix}definitely-absent');
    _expect(missing == null, 'get', 'absent key must return null');
  }

  Future<void> _checkRoundTrip(ObjectStore store, List<String> created) async {
    final key = '${prefix}round-trip';
    created.add(key);
    final value = _bytes(0, 1, 2, 253, 254, 255);
    await store.put(key, value);
    final read = await store.get(key);
    _expect(read != null, 'get', 'put followed by get returned null');
    _expect(_same(read!, value), 'get', 'value changed through the store');

    final emptyKey = '${prefix}empty-value';
    created.add(emptyKey);
    await store.put(emptyKey, Uint8List(0));
    final empty = await store.get(emptyKey);
    _expect(
      empty != null && empty.isEmpty,
      'get',
      'zero-length objects must round-trip',
    );
  }

  Future<void> _checkOverwrite(ObjectStore store, List<String> created) async {
    final key = '${prefix}overwrite';
    created.add(key);
    await store.put(key, _bytes(1, 2, 3));
    await store.put(key, _bytes(9, 8));
    final read = await store.get(key);
    _expect(
      read != null && _same(read, _bytes(9, 8)),
      'put',
      'put must replace the previous value',
    );
  }

  Future<void> _checkLargeValue(ObjectStore store, List<String> created) async {
    final key = '${prefix}large';
    created.add(key);
    final value = Uint8List(1 << 20);
    for (var i = 0; i < value.length; i++) {
      value[i] = i & 0xFF;
    }
    await store.put(key, value);
    final read = await store.get(key);
    _expect(
      read != null && read.length == value.length,
      'get',
      'a 1 MiB object must round-trip',
    );
    _expect(_same(read!, value), 'get', 'large object bytes changed');
  }

  Future<void> _checkDelete(ObjectStore store, List<String> created) async {
    final key = '${prefix}delete';
    created.add(key);
    await store.put(key, _bytes(7));
    await store.delete(key);
    _expect(await store.get(key) == null, 'delete', 'deleted key is readable');
    // Deleting a missing key must not throw.
    await store.delete(key);
  }

  Future<void> _checkDeleteMany(ObjectStore store, List<String> created) async {
    final keys = <String>[for (var i = 0; i < 4; i++) '${prefix}batch-$i'];
    created.addAll(keys);
    for (final key in keys) {
      await store.put(key, _bytes(1));
    }
    await store.deleteMany(keys);
    final listed = await store.list('${prefix}batch-');
    _expect(
      listed.isEmpty,
      'deleteMany',
      'deleteMany left keys behind: $listed',
    );
    await store.deleteMany(const <String>[]);
  }

  Future<void> _checkList(ObjectStore store, List<String> created) async {
    final keys = <String>[
      '${prefix}list/a',
      '${prefix}list/b',
      '${prefix}list/nested/c',
      '${prefix}listed-elsewhere',
    ];
    created.addAll(keys);
    for (final key in keys) {
      await store.put(key, _bytes(1));
    }
    final listed = await store.list('${prefix}list/')
      ..sort();
    final expected = <String>[
      '${prefix}list/a',
      '${prefix}list/b',
      '${prefix}list/nested/c',
    ];
    _expect(
      listed.length == expected.length && _sameStrings(listed, expected),
      'list',
      'list(prefix) must return exactly the matching keys '
          '(got $listed, expected $expected)',
    );
    final all = await store.list(prefix);
    _expect(
      all.contains('${prefix}listed-elsewhere'),
      'list',
      'list must include every key under the prefix',
    );
  }

  static Uint8List _bytes(int a, [int? b, int? c, int? d, int? e, int? f]) {
    final out = <int>[a];
    for (final value in <int?>[b, c, d, e, f]) {
      if (value != null) out.add(value);
    }
    return Uint8List.fromList(out);
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static void _expect(bool condition, String check, String message) {
    if (!condition) throw ObjectStoreConformanceException(check, message);
  }
}
