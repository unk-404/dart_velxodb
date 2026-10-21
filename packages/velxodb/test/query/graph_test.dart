@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes props(String text) =>
    (DocBuilder(schemaId: 9)..putString(1, text)).finish();

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection users;
  late GraphStore graph;
  late NodeRef u1;
  late NodeRef u2;
  late NodeRef u3;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_graph_');
    db = VelxoDatabase.openSync(root.path);
    users = db.collection('users');
    graph = db.graph;
    u1 = NodeRef.of(users, k('u1'));
    u2 = NodeRef.of(users, k('u2'));
    u3 = NodeRef.of(users, k('u3'));
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('graph store', () {
    test('links and reads both directions', () {
      graph.link('follows', u1, u2);
      expect(graph.has('follows', u1, u2), isTrue);
      expect(graph.has('follows', u2, u1), isFalse);

      final outgoing = graph.outgoing('follows', u1);
      expect(outgoing, hasLength(1));
      expect(outgoing.single.to, u2);
      expect(outgoing.single.from, u1);

      final incoming = graph.incoming('follows', u2);
      expect(incoming, hasLength(1));
      expect(incoming.single.from, u1);
    });

    test('unlink removes both directions', () {
      graph.link('follows', u1, u2);
      graph.unlink('follows', u1, u2);
      expect(graph.has('follows', u1, u2), isFalse);
      expect(graph.outgoing('follows', u1), isEmpty);
      expect(graph.incoming('follows', u2), isEmpty);
    });

    test('stores properties on both directions', () {
      graph.link('follows', u1, u2, properties: props('since 2020'));
      final from = graph.outgoing('follows', u1).single.properties;
      final reverse = graph.incoming('follows', u2).single.properties;
      expect(DocView.parse(from.asUint8List()).getString(1), 'since 2020');
      expect(DocView.parse(reverse.asUint8List()).getString(1), 'since 2020');
    });

    test('overwrites properties when linking the same edge twice', () {
      graph.link('follows', u1, u2, properties: props('old'));
      graph.link('follows', u1, u2, properties: props('new'));
      final edges = graph.outgoing('follows', u1);
      expect(edges, hasLength(1));
      expect(
        DocView.parse(edges.single.properties.asUint8List()).getString(1),
        'new',
      );
      expect(graph.incoming('follows', u2), hasLength(1));
    });

    test('isolates relations', () {
      graph.link('follows', u1, u2);
      graph.link('blocks', u1, u2);
      expect(graph.outgoing('follows', u1), hasLength(1));
      expect(graph.outgoing('blocks', u1), hasLength(1));
      expect(graph.outgoing('likes', u1), isEmpty);
    });

    test('lists neighbours and multiple edges', () {
      graph.link('follows', u1, u2);
      graph.link('follows', u1, u3);
      expect(graph.outgoing('follows', u1), hasLength(2));
      expect(graph.neighbours('follows', u1).toSet(), <NodeRef>{u2, u3});
      expect(graph.neighbours('follows', u2), isEmpty);
    });

    test('edges survive a flush and reopen', () async {
      graph.link('member_of', u1, u2, properties: props('admin'));
      db.flushSync();
      await db.close();

      db = VelxoDatabase.openSync(root.path);
      users = db.collection('users');
      graph = db.graph;
      u1 = NodeRef.of(users, k('u1'));
      u2 = NodeRef.of(users, k('u2'));

      final edges = graph.outgoing('member_of', u1);
      expect(edges, hasLength(1));
      expect(edges.single.to, u2);
      expect(
        DocView.parse(edges.single.properties.asUint8List()).getString(1),
        'admin',
      );
    });

    test('nodes from different collections do not collide', () {
      final posts = db.collection('posts');
      final post = NodeRef.of(posts, k('u1'));
      graph.link('authored', u1, post);
      expect(graph.outgoing('authored', u1).single.to.collectionId, posts.id);
      expect(post.collectionId, isNot(users.id));
    });

    test('walks two hops and deduplicates nodes', () {
      graph.link('follows', u1, u2);
      graph.link('follows', u2, u3);
      graph.link('follows', u1, u3);

      final walk = graph.walk(u1, maxDepth: 2);
      expect(walk.levels, hasLength(2));
      expect(walk.levels[0], <NodeRef>[u1]);
      expect(walk.levels[1].toSet(), <NodeRef>{u2, u3});
      expect(walk.truncated, isFalse);
    });

    test('walk follows only the requested relations', () {
      graph.link('follows', u1, u2);
      graph.link('blocks', u1, u3);

      expect(
        graph.walk(u1, relations: <String>{'follows'}).levels[1],
        <NodeRef>[u2],
      );
      expect(graph.walk(u1).levels[1].toSet(), <NodeRef>{u2, u3});
    });

    test('walk honours inbound direction', () {
      graph.link('follows', u2, u1);
      final walk = graph.walk(
        u1,
        maxDepth: 1,
        direction: EdgeDirection.inbound,
      );
      expect(walk.levels[1], <NodeRef>[u2]);
    });

    test('walk reports truncation at the depth limit', () {
      graph.link('follows', u1, u2);
      graph.link('follows', u2, u3);
      final walk = graph.walk(u1, maxDepth: 1);
      expect(walk.levels, hasLength(2));
      expect(walk.truncated, isTrue);
      expect(walk.nodes, hasLength(2));
    });

    test('finds dangling edges after a node is deleted', () {
      graph.link('follows', u1, u2);
      users.deleteSync(k('u2'));

      final dangling = graph.danglingEdges();
      expect(dangling, hasLength(1));
      expect(dangling.single.relation, 'follows');
      expect(dangling.single.from, u1);
      expect(dangling.single.to, u2);
    });
  });
}
