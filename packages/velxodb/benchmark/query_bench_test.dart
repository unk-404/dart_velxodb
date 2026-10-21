// Query-layer benchmarks: collection point reads and prefix scans.
//   dart run benchmark_test --output jsonl benchmark
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

int sink = 0;
const int batch = 100;
const int keyCount = 64;

Bytes chatMessage() => (DocBuilder(schemaId: 1)
      ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
      ..putInt(2, 7)
      ..putString(3, '在吗？今天下午三点开会，别忘了带材料。'))
    .finish();

Bytes indexedMessage(int value) => (DocBuilder(schemaId: 1)
      ..putString(1, '01J8Z4K2M3N4P5Q6R7S8T9V0W1')
      ..putInt(2, value))
    .finish();

/// In-memory catalog so the benchmark does not need a real directory.
final class _StubCatalog implements IndexCatalog {
  final List<IndexDefinition> _definitions = <IndexDefinition>[];

  @override
  IndexDefinition? indexFor(int collectionId, int fieldId) {
    for (final definition in _definitions) {
      if (definition.collectionId == collectionId &&
          definition.fieldId == fieldId) {
        return definition;
      }
    }
    return null;
  }

  @override
  List<IndexDefinition> indexesFor(int collectionId) => <IndexDefinition>[
    for (final definition in _definitions)
      if (definition.collectionId == collectionId) definition,
  ];

  @override
  IndexDefinition registerIndex(int collectionId, int fieldId, VxsType type) {
    final definition = IndexDefinition(
      collectionId: collectionId,
      fieldId: fieldId,
      type: type,
      indexId: 500 + fieldId,
    );
    _definitions.add(definition);
    return definition;
  }
}

void main() {
  final engine = StorageEngine(directory: MemoryStorageDirectory())
    ..openSync();
  final collection = Collection(engine, 1, 'bench');
  final document = chatMessage();
  final keys = <Uint8List>[
    for (var i = 0; i < keyCount; i++)
      Uint8List.fromList('key-${i.toString().padLeft(4, '0')}'.codeUnits),
  ];
  for (final key in keys) {
    collection.putSync(key, document);
  }
  // Flush once so lookups walk the segment path, then shadow half the keys in
  // the memtable so scans have to merge both sources.
  engine.flushSync();
  for (var i = 0; i < keyCount; i += 2) {
    collection.putSync(keys[i], document);
  }

  // A collection with a secondary index on field 2.
  final indexed = Collection(engine, 2, 'indexed', catalog: _StubCatalog());
  indexed.createIndex(2, VxsType.int64);
  for (var i = 0; i < keyCount; i++) {
    indexed.putSync(keys[i], indexedMessage(i % 8));
  }

  group('query', () {
    benchmark('collection.get', () {
      for (var round = 0; round < batch; round++) {
        for (final key in keys) {
          sink += collection.get(key)?.length ?? -1;
        }
      }
    });

    benchmark('collection.scan', () {
      for (var round = 0; round < batch; round++) {
        sink += collection.scanPrefixSync().length;
      }
    });

    benchmark('collection.cursor', () {
      for (var round = 0; round < batch; round++) {
        final cursor = collection.cursor();
        var count = 0;
        while (cursor.moveNext()) {
          count++;
        }
        sink += count;
      }
    });

    benchmark('collection.put.indexed', () {
      for (var round = 0; round < batch; round++) {
        for (var i = 0; i < keyCount; i++) {
          indexed.putSync(keys[i], indexedMessage(i % 8));
        }
      }
    });

    benchmark('collection.indexLookup', () {
      for (var round = 0; round < batch; round++) {
        sink += indexed.lookupByIndexSync(2, 3).length;
      }
    });
  });
}
