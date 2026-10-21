// Query-layer benchmarks: collection point reads, scans, indexes, paging and
// full-text search.
//
// The engine runs on an in-memory directory; the catalog is the shared
// `MemoryCatalog` from `lib/fixtures.dart`.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

void main() {
  final engine = StorageEngine(directory: MemoryStorageDirectory())..openSync();
  final collection = Collection(engine, 1, 'bench');
  final document = compactDocument();
  final keys = keysFor(kKeyCount);
  for (final key in keys) {
    collection.putSync(key, document);
  }
  // Flush once so lookups walk the segment path, then shadow half the keys in
  // the memtable so scans have to merge both sources.
  engine.flushSync();
  for (var i = 0; i < kKeyCount; i += 2) {
    collection.putSync(keys[i], document);
  }

  // A collection with a secondary index on field 2.
  final indexed = Collection(engine, 2, 'indexed', catalog: MemoryCatalog());
  indexed.createIndex(2, VxsType.int64);
  for (var i = 0; i < kKeyCount; i++) {
    indexed.putSync(keys[i], indexedDocument(i % kIndexValues));
  }

  // A collection with a full-text index on field 1.
  final textCollection = Collection(
    engine,
    3,
    'text',
    catalog: MemoryCatalog(),
  );
  textCollection.createTextIndex(1, tokenizer: const WordTokenizer());
  for (var i = 0; i < kKeyCount; i++) {
    textCollection.putSync(
      keys[i],
      (DocBuilder(
        schemaId: 1,
      )..putString(1, 'alpha beta gamma item$i')).finish(),
    );
  }

  group('query', () {
    benchmark('collection.get', () {
      for (var round = 0; round < kBatch; round++) {
        for (final key in keys) {
          sink += collection.get(key)?.length ?? -1;
        }
      }
    });

    benchmark('collection.scan', () {
      for (var round = 0; round < kBatch; round++) {
        sink += collection.scanPrefixSync().length;
      }
    });

    benchmark('collection.cursor', () {
      for (var round = 0; round < kBatch; round++) {
        final cursor = collection.cursor();
        var count = 0;
        while (cursor.moveNext()) {
          count++;
        }
        sink += count;
      }
    });

    benchmark('collection.put.indexed', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kKeyCount; i++) {
          indexed.putSync(keys[i], indexedDocument(i % kIndexValues));
        }
      }
    });

    benchmark('collection.indexLookup', () {
      for (var round = 0; round < kBatch; round++) {
        sink += indexed.lookupByIndexSync(2, 3).length;
      }
    });

    benchmark('collection.indexRange', () {
      for (var round = 0; round < kBatch; round++) {
        sink += indexed.lookupByIndexRangeSync(2, from: 2, to: 5).length;
      }
    });

    benchmark('collection.page', () {
      for (var round = 0; round < kBatch; round++) {
        Uint8List? token;
        do {
          final page = indexed.pageSync(limit: kPageLimit, after: token);
          token = page.next;
          sink += page.entries.length;
        } while (token != null);
      }
    });

    benchmark('collection.textSearch', () {
      for (var round = 0; round < kBatch; round++) {
        sink += textCollection.searchTextSync(1, 'alpha').length;
      }
    });
  });
}
