// Relation benchmarks: graph edges in both directions, BFS, and the reference
// binding lifecycle (write, reverse lookup, restrict, cascade).
//
// The group name stays `query` on purpose: `graph.link` and `graph.outgoing`
// have been charted under `query …` ids since the first card, and renaming the
// group would orphan every historical number.
//
// Run: dart run benchmark_test --output jsonl .
import 'dart:typed_data';

import 'package:benchmark_test/benchmark_test.dart';
import 'package:test/test.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/workload.dart';

/// Keeps results observable so the JIT/AOT cannot elide the work.
int sink = 0;

void main() {
  final engine = StorageEngine(directory: MemoryStorageDirectory())..openSync();

  final catalog = MemoryCatalog()
    ..addCollection('users', 1)
    ..addCollection('messages', 2);
  final users = Collection(engine, 1, 'users', catalog: catalog);
  final messages = Collection(engine, 2, 'messages', catalog: catalog);
  final notes = Collection(engine, 3, 'notes', catalog: catalog);

  // messages.field_2 -> users, cascade; notes.field_2 -> messages, restrict.
  messages.createReference(2, 'users', onDelete: OnDelete.cascade);
  notes.createReference(2, 'messages', onDelete: OnDelete.restrict);

  for (var i = 0; i <= kKeyCount; i++) {
    users.putSync(userKey(i), compactDocument());
  }
  final userKeys = <Uint8List>[for (var i = 0; i < kKeyCount; i++) userKey(i)];

  // One message per user, plus the notes that pin those messages.
  for (var i = 0; i < kKeyCount; i++) {
    messages.putSync(
      messageKey(i),
      referringDocument(String.fromCharCodes(userKeys[i])),
    );
    notes.putSync(
      messageKey(i),
      referringDocument(String.fromCharCodes(messageKey(i))),
    );
  }

  // A separate target with children only for the cascade cycle, so the cycle
  // benchmark cannot disturb the data the other rows read.
  final cascadeTarget = userKey(kKeyCount);
  final cascadeChildren = <Uint8List>[
    for (var i = 0; i < kCascadeChildren; i++)
      Uint8List.fromList('child-${i.toString().padLeft(3, '0')}'.codeUnits),
  ];
  void rebuildCascadeTarget() {
    users.putSync(cascadeTarget, compactDocument());
    for (final child in cascadeChildren) {
      messages.putSync(
        child,
        referringDocument(String.fromCharCodes(cascadeTarget)),
      );
    }
  }

  rebuildCascadeTarget();

  // Cascade must actually remove the children; verified once, not charted.
  users.deleteSync(cascadeTarget);
  for (final child in cascadeChildren) {
    if (messages.get(child) != null) {
      throw StateError('cascade left ${String.fromCharCodes(child)} behind');
    }
  }
  rebuildCascadeTarget();

  // A 64-node graph with out-degree 4: the ring plus three skips.
  final relations = MemoryRelations();
  final graph = GraphStore(engine, relations);
  final nodes = <NodeRef>[
    for (var i = 0; i < kKeyCount; i++) NodeRef(1, userKeys[i]),
  ];
  for (var i = 0; i < kKeyCount; i++) {
    for (var skip = 1; skip <= kGraphOutDegree; skip *= 2) {
      graph.link('follows', nodes[i], nodes[(i + skip) % kKeyCount]);
    }
  }
  const relationSet = <String>{'follows'};

  group('query', () {
    benchmark('graph.link', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kKeyCount; i++) {
          graph.link('follows', nodes[i], nodes[(i + 1) % kKeyCount]);
        }
      }
    });

    benchmark('graph.outgoing', () {
      for (var round = 0; round < kBatch; round++) {
        for (final node in nodes) {
          sink += graph.outgoing('follows', node).length;
        }
      }
    });

    benchmark('graph.incoming', () {
      for (var round = 0; round < kBatch; round++) {
        for (final node in nodes) {
          sink += graph.incoming('follows', node).length;
        }
      }
    });

    benchmark('graph.walk', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < 16; i++) {
          final walk = graph.walk(
            nodes[i],
            maxDepth: 2,
            relations: relationSet,
          );
          sink += walk.nodes.length;
        }
      }
    });

    benchmark('reference.put', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kKeyCount; i++) {
          messages.putSync(
            messageKey(i),
            referringDocument(String.fromCharCodes(userKeys[i])),
          );
        }
      }
    });

    benchmark('reference.reverse', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kKeyCount; i++) {
          final target = String.fromCharCodes(userKeys[i]);
          sink += messages.lookupByIndexSync(2, target).length;
        }
      }
    });

    benchmark('reference.restrict', () {
      var conflicts = 0;
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < kKeyCount; i++) {
          try {
            messages.deleteSync(messageKey(i));
          } on VelxoException {
            // restrict/constraint: the delete must be refused and rolled back.
            conflicts++;
          }
        }
      }
      if (conflicts != kBatch * kKeyCount) {
        throw StateError(
          'restrict let ${kBatch * kKeyCount - conflicts} '
          'referenced deletes through',
        );
      }
      sink += conflicts;
    });

    benchmark('reference.cascadeCycle', () {
      for (var round = 0; round < kBatch; round++) {
        for (var i = 0; i < 8; i++) {
          users.deleteSync(cascadeTarget);
          rebuildCascadeTarget();
        }
      }
    });
  });
}
