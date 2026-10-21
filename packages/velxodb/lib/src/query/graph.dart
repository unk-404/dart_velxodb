import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../serde/builder.dart';
import '../storage/engine.dart';
import '../storage/wal.dart';
import 'collection.dart';
import 'cursor.dart';

/// Resolves relation names to stable namespace ids.
abstract interface class RelationCatalog {
  /// Returns the id for [name], registering the relation if needed.
  int relationId(String name);

  /// Returns the id for [name] if it exists, without registering it.
  int? existingRelationId(String name);

  /// Returns the name for [id], or `null`.
  String? relationName(int id);

  /// Names of every registered relation, used by a global walk.
  List<String> relationNames();
}

/// A node in the graph: a document identified by collection and key.
final class NodeRef {
  /// Creates a node reference.
  const NodeRef(this.collectionId, this.key);

  /// Creates a node reference for [key] in [collection].
  NodeRef.of(Collection collection, this.key)
    : collectionId = collection.id;

  /// Collection id the document lives in.
  final int collectionId;

  /// Document key.
  final Uint8List key;

  /// Encodes the node as `[collectionId u16][key]`.
  Uint8List encode() {
    final out = Uint8List(2 + key.length);
    out[0] = (collectionId >> 8) & 0xFF;
    out[1] = collectionId & 0xFF;
    out.setRange(2, out.length, key);
    return out;
  }

  /// Decodes a node from `[collectionId u16][key]`.
  static NodeRef decode(Uint8List bytes) {
    if (bytes.length < 2) {
      throw ArgumentError('node reference is too short');
    }
    final collectionId = (bytes[0] << 8) | bytes[1];
    return NodeRef(
      collectionId,
      Uint8List.sublistView(bytes, 2, bytes.length),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NodeRef &&
      other.collectionId == collectionId &&
      _bytesEqual(other.key, key);

  @override
  int get hashCode => collectionId * 31 + _hash(key);

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _hash(Uint8List bytes) {
    var hash = 0x811C9DC5;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x01000193;
      hash &= 0x7FFFFFFF;
    }
    return hash;
  }
}

/// Direction of an edge relative to a node.
enum EdgeDirection {
  /// Node is the source.
  outbound,

  /// Node is the target.
  inbound,
}

/// One stored edge.
final class GraphEdge {  /// Creates an edge.
  const GraphEdge({
    required this.relation,
    required this.from,
    required this.to,
    required this.properties,
  });

  /// Relation name.
  final String relation;

  /// Source node.
  final NodeRef from;

  /// Target node.
  final NodeRef to;

  /// Raw property document (may be empty).
  final Bytes properties;
}

/// Typed, bidirectional edges on top of the key/value engine.
///
/// Each edge is stored twice in one WAL frame:
///
/// ```
/// forward: [relationId][0x01][fromLength u16][from][to] -> properties
/// reverse: [relationId][0x02][toLength u16][to][from] -> properties
/// ```
///
/// The length prefix keeps the source node separable from the target during a
/// whole-namespace scan, which is what dangling-edge checks need.
///
/// A node is `[collectionId u16][key]`, so edges are globally unique across
/// collections. Adjacency is a prefix scan, O(out-degree) or O(in-degree).
final class GraphStore {
  /// Creates a graph store.
  GraphStore(this.engine, this._catalog);

  /// Underlying engine.
  final StorageEngine engine;

  final RelationCatalog _catalog;

  static final Bytes _empty = DocBuilder().finish();

  /// Links [from] to [to] under [relation], replacing properties if the edge
  /// already exists.
  void link(
    String relation,
    NodeRef from,
    NodeRef to, {
    Bytes? properties,
  }) {
    final relationId = _catalog.relationId(relation);
    final props = properties ?? _empty;
    final fromBytes = from.encode();
    final toBytes = to.encode();
    engine.applyBatchSync(<WalOp>[
      WalOp.put(
        _edgeKey(relationId, _forward, fromBytes, toBytes),
        props.asUint8List(),
      ),
      WalOp.put(
        _edgeKey(relationId, _reverse, toBytes, fromBytes),
        props.asUint8List(),
      ),
    ]);
  }

  /// Removes the edge in both directions.
  void unlink(String relation, NodeRef from, NodeRef to) {
    final relationId = _relationIdOrNull(relation);
    if (relationId == null) return;
    final fromBytes = from.encode();
    final toBytes = to.encode();
    engine.applyBatchSync(<WalOp>[
      WalOp.delete(_edgeKey(relationId, _forward, fromBytes, toBytes)),
      WalOp.delete(_edgeKey(relationId, _reverse, toBytes, fromBytes)),
    ]);
  }

  /// Whether the edge exists.
  bool has(String relation, NodeRef from, NodeRef to) {
    final relationId = _relationIdOrNull(relation);
    if (relationId == null) return false;
    final key = _edgeKey(
      relationId,
      _forward,
      from.encode(),
      to.encode(),
    );
    return engine.get(key) != null;
  }

  /// Outgoing edges of [node].
  List<GraphEdge> outgoing(String relation, NodeRef node) =>
      _scan(relation, node, EdgeDirection.outbound);

  /// Incoming edges of [node].
  List<GraphEdge> incoming(String relation, NodeRef node) =>
      _scan(relation, node, EdgeDirection.inbound);

  /// Neighbours of [node] in [direction].
  List<NodeRef> neighbours(
    String relation,
    NodeRef node, {
    EdgeDirection direction = EdgeDirection.outbound,
  }) => <NodeRef>[
    for (final edge in _scan(relation, node, direction))
      direction == EdgeDirection.outbound ? edge.to : edge.from,
  ];

  List<GraphEdge> _scan(
    String relation,
    NodeRef node,
    EdgeDirection direction,
  ) {
    final relationId = _relationIdOrNull(relation);
    if (relationId == null) return const <GraphEdge>[];
    final nodeBytes = node.encode();
    final dir = direction == EdgeDirection.outbound ? _forward : _reverse;
    final prefix = Uint8List(1 + 2 + 2 + nodeBytes.length);
    prefix[0] = (relationId >> 8) & 0xFF;
    prefix[1] = relationId & 0xFF;
    prefix[2] = dir;
    _write16(prefix, 3, nodeBytes.length);
    prefix.setRange(5, 5 + nodeBytes.length, nodeBytes);

    final cursor = buildCollectionCursor(
      engine: engine,
      fullPrefix: prefix,
      lower: prefix,
      includeLower: true,
      upper: _prefixUpperBound(prefix),
      includeUpper: false,
    );
    final edges = <GraphEdge>[];
    while (cursor.moveNext()) {
      final raw = cursor.current.key; // [dir][len][node][other]
      final otherBytes = Uint8List.sublistView(raw, 3 + nodeBytes.length);
      final other = NodeRef.decode(otherBytes);
      edges.add(
        GraphEdge(
          relation: relation,
          from: direction == EdgeDirection.outbound ? node : other,
          to: direction == EdgeDirection.outbound ? other : node,
          properties: cursor.current.value,
        ),
      );
    }
    return edges;
  }

  /// Breadth-first walk from [start].
  ///
  /// [relations] limits which edge types are followed; `null` means every
  /// registered relation. Depth is capped by [maxDepth], so a supernode cannot
  /// turn one query into a full-graph scan.
  GraphWalk walk(
    NodeRef start, {
    int maxDepth = 2,
    Set<String>? relations,
    EdgeDirection direction = EdgeDirection.outbound,
  }) {
    final names = relations ?? _catalog.relationNames();
    final visited = <NodeRef>{start};
    final levels = <List<NodeRef>>[
      <NodeRef>[start],
    ];
    var frontier = <NodeRef>[start];
    for (var depth = 1; depth <= maxDepth; depth++) {
      final next = <NodeRef>[];
      for (final node in frontier) {
        for (final name in names) {
          for (final neighbour in neighbours(name, node, direction: direction)) {
            if (visited.add(neighbour)) next.add(neighbour);
          }
        }
      }
      if (next.isEmpty) break;
      levels.add(next);
      frontier = next;
    }
    return GraphWalk(
      levels: levels,
      truncated: levels.length - 1 == maxDepth && frontier.isNotEmpty,
    );
  }

  /// Edges whose target document no longer exists.
  ///
  /// Scans every forward namespace; this is an operational check, not something
  /// to run on the query path.
  List<GraphEdge> danglingEdges({int limit = 1000}) {
    final dangling = <GraphEdge>[];
    for (final name in _catalog.relationNames()) {
      final relationId = _catalog.existingRelationId(name);
      if (relationId == null) continue;
      final prefix = Uint8List(3)
        ..[0] = (relationId >> 8) & 0xFF
        ..[1] = relationId & 0xFF
        ..[2] = _forward;
      final cursor = buildCollectionCursor(
        engine: engine,
        fullPrefix: prefix,
        lower: prefix,
        includeLower: true,
        upper: _prefixUpperBound(prefix),
        includeUpper: false,
      );
      while (cursor.moveNext() && dangling.length < limit) {
        final raw = cursor.current.key; // [dir][len][from][to]
        final fromLength = (raw[1] << 8) | raw[2];
        final fromBytes = Uint8List.sublistView(raw, 3, 3 + fromLength);
        final toBytes = Uint8List.sublistView(raw, 3 + fromLength);
        final from = NodeRef.decode(fromBytes);
        final to = NodeRef.decode(toBytes);
        final targetKey = Uint8List(2 + to.key.length)
          ..[0] = (to.collectionId >> 8) & 0xFF
          ..[1] = to.collectionId & 0xFF
          ..setRange(2, 2 + to.key.length, to.key);
        if (engine.get(targetKey) == null) {
          dangling.add(
            GraphEdge(
              relation: name,
              from: from,
              to: to,
              properties: cursor.current.value,
            ),
          );
        }
      }
    }
    return dangling;
  }

  int? _relationIdOrNull(String relation) =>
      _catalog.existingRelationId(relation);

  static const int _forward = 0x01;
  static const int _reverse = 0x02;

  static Uint8List _edgeKey(
    int relationId,
    int direction,
    Uint8List knownNode,
    Uint8List otherNode,
  ) {
    final out = Uint8List(3 + 2 + knownNode.length + otherNode.length);
    out[0] = (relationId >> 8) & 0xFF;
    out[1] = relationId & 0xFF;
    out[2] = direction;
    _write16(out, 3, knownNode.length);
    out.setRange(5, 5 + knownNode.length, knownNode);
    out.setRange(5 + knownNode.length, out.length, otherNode);
    return out;
  }

  static void _write16(Uint8List out, int offset, int value) {
    out[offset] = (value >> 8) & 0xFF;
    out[offset + 1] = value & 0xFF;
  }

  static Uint8List? _prefixUpperBound(Uint8List prefix) {
    final out = Uint8List.fromList(prefix);
    for (var i = out.length - 1; i >= 0; i--) {
      if (out[i] != 0xFF) {
        out[i]++;
        return Uint8List.sublistView(out, 0, i + 1);
      }
    }
    return null;
  }
}

/// Result of a breadth-first walk.
final class GraphWalk {
  /// Creates a walk result.
  const GraphWalk({required this.levels, required this.truncated});

  /// Level 0 is the start node, level N is N hops away.
  final List<List<NodeRef>> levels;

  /// Whether the depth limit stopped the walk with a non-empty frontier.
  final bool truncated;

  /// Every visited node, level by level.
  List<NodeRef> get nodes => <NodeRef>[for (final level in levels) ...level];
}
