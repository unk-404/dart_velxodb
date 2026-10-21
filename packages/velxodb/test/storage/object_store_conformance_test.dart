import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/testing.dart';

void main() {
  test(
    'the simulated object store satisfies the ObjectStore contract',
    () async {
      await const ObjectStoreConformance(prefix: 'conformance/')
          .run(SimulatedObjectStore());
    },
  );

  test('the conformance kit reports a broken backend', () async {
    await expectLater(
      const ObjectStoreConformance(prefix: 'broken/').run(_DeletingStore()),
      throwsA(isA<ObjectStoreConformanceException>()),
    );
  });
}

/// A store that forgets deletes; the kit must catch it.
final class _DeletingStore implements ObjectStore {
  final Map<String, Uint8List> _values = <String, Uint8List>{};

  @override
  Future<Uint8List?> get(String key) async => _values[key];

  @override
  Future<void> put(String key, Uint8List bytes) async => _values[key] = bytes;

  @override
  Future<void> delete(String key) async {
    // Bug: delete is ignored.
  }

  @override
  Future<void> deleteMany(List<String> keys) async {}

  @override
  Future<List<String>> list(String prefix) async => <String>[
    for (final key in _values.keys)
      if (key.startsWith(prefix)) key,
  ];
}
