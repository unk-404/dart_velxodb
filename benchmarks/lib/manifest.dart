/// The row table: every charted benchmark, its unit and the workload it runs.
///
/// This replaces the 33 hand-written `value = "..."` formulas that used to live
/// in `benchcat.toml`. The factors come from `lib/workload.dart`, which the
/// suites import too, so a workload change and its chart denominator cannot
/// drift apart.
library;

import 'workload.dart';

/// How a measured iteration rate becomes the row's value.
enum MetricKind {
  /// Value grows with the iteration rate (`MB/s`, `Mops/s`, ...).
  rate,

  /// Value is the time of one operation (`ns/op`).
  latency,
}

/// One charted row.
final class BenchRow {
  /// Creates a row.
  const BenchRow({
    required this.id,
    required this.group,
    required this.label,
    required this.unit,
    required this.ops,
    this.bytesPerOp = 0,
    this.divisor = 1e6,
    this.kind = MetricKind.rate,
    this.note = '',
    this.direction = 'higher',
  });

  /// Benchmark id as `benchmark_test` reports it: `"<group> <name>"`.
  final String id;

  /// Display group used by the card.
  final String group;

  /// Human label.
  final String label;

  /// Measurement unit.
  final String unit;

  /// Operations performed per benchmark iteration.
  final int ops;

  /// Payload bytes per operation, for byte-rate units.
  final int bytesPerOp;

  /// Unit denominator: `1e6` for mega, `1e3` for kilo.
  final double divisor;

  /// Whether [unit] is a rate or a per-operation latency.
  final MetricKind kind;

  /// Extra provenance shown under the label.
  final String note;

  /// `higher` or `lower`; which direction is better.
  final String direction;

  /// Converts an iteration rate (iterations per second) into the row value.
  double valueFor(double iterationsPerSecond) {
    switch (kind) {
      case MetricKind.rate:
        final bytes = bytesPerOp == 0 ? 1 : bytesPerOp;
        return iterationsPerSecond * ops * bytes / divisor;
      case MetricKind.latency:
        if (iterationsPerSecond <= 0) return 0;
        return 1e9 / (iterationsPerSecond * ops);
    }
  }
}

const String _format = 'VXS format';
const String _storage = 'Storage';
const String _query = 'Query';

/// Every row that a micro suite measures, in card order.
const List<BenchRow> kRows = <BenchRow>[
  // VXS format -------------------------------------------------------------
  BenchRow(
    id: 'serde encode.5field',
    group: _format,
    label: 'Encode a 130 B document',
    note: 'single-doc builder',
    unit: 'MB/s',
    ops: kBatch,
    bytesPerOp: kDocBytes,
  ),
  BenchRow(
    id: 'serde encode.sink',
    group: _format,
    label: 'Encode into a batch sink',
    note: 'one buffer, no per-doc allocation',
    unit: 'MB/s',
    ops: kBatch,
    bytesPerOp: kDocBytes,
  ),
  BenchRow(
    id: 'serde decode.singleScan',
    group: _format,
    label: 'Scan all 5 fields',
    note: 'cursor, no value materialisation',
    unit: 'ns/op',
    ops: kBatch,
    kind: MetricKind.latency,
  ),
  BenchRow(
    id: 'serde decode.getters',
    group: _format,
    label: 'Read 3 fields via getters',
    note: 'O(n^2) convenience path',
    unit: 'ns/op',
    ops: kBatch,
    kind: MetricKind.latency,
  ),
  BenchRow(
    id: 'serde project.one',
    group: _format,
    label: 'Project one text field',
    note: 'scan + utf8 decode',
    unit: 'ns/op',
    ops: kBatch,
    kind: MetricKind.latency,
  ),
  BenchRow(
    id: 'serde project.fields',
    group: _format,
    label: 'Project all 5 fields',
    note: 'one scan, zero-copy strings',
    unit: 'ns/op',
    ops: kBatch,
    kind: MetricKind.latency,
  ),
  BenchRow(
    id: 'serde view.compare',
    group: _format,
    label: 'Compare 26 B keys (zero-copy)',
    note: 'StringView vs String',
    unit: 'ns/op',
    ops: kBatch,
    kind: MetricKind.latency,
  ),
  BenchRow(
    id: 'serde crc.1KiB',
    group: _format,
    label: 'CRC-32C over 1 KiB',
    unit: 'MB/s',
    ops: kBatch,
    bytesPerOp: kCrcBytes,
  ),
  BenchRow(
    id: 'format bytes.mut.write',
    group: _format,
    label: 'BytesMut: write a 130 B doc',
    note: 'blit primitives, no engine involved',
    unit: 'Mops/s',
    ops: 32,
  ),
  BenchRow(
    id: 'format bytes.read.view',
    group: _format,
    label: 'BytesMut: read a doc back',
    note: 'includes the 32-doc build',
    unit: 'Mops/s',
    ops: 32,
  ),

  // Storage ----------------------------------------------------------------
  BenchRow(
    id: 'storage block.write',
    group: _storage,
    label: 'Pack a block (20 docs)',
    note: 'includes block CRC',
    unit: 'MB/s',
    ops: kBatch * kDocsPerBlock,
    bytesPerOp: kDocBytes,
  ),
  BenchRow(
    id: 'storage block.read',
    group: _storage,
    label: 'Scan a block',
    note: '20 documents',
    unit: 'Mdocs/s',
    ops: kBatch * kDocsPerBlock,
  ),
  BenchRow(
    id: 'storage wal.frame',
    group: _storage,
    label: 'Encode a WAL frame',
    note: '1 doc + CRC32C',
    unit: 'Kops/s',
    ops: kBatch,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'storage wal.batch',
    group: _storage,
    label: 'Decode a WAL batch',
    unit: 'Kops/s',
    ops: kBatch,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'storage memtable.get',
    group: _storage,
    label: 'Memtable lookup',
    note: 'hash index',
    unit: 'Mops/s',
    ops: kBatch * kKeyCount,
  ),
  BenchRow(
    id: 'storage memtable.put',
    group: _storage,
    label: 'Memtable insert',
    note: '64 keys rewritten',
    unit: 'Mops/s',
    ops: kBatch * kKeyCount,
  ),
  BenchRow(
    id: 'storage memtable.range',
    group: _storage,
    label: 'Memtable range seek',
    note: '1k of 50k entries, skip list',
    unit: 'Mdocs/s',
    ops: kBatch * kMemtableWindow,
  ),
  BenchRow(
    id: 'storage segment.build',
    group: _storage,
    label: 'Build a segment',
    note: '64 docs, sorted index + bloom',
    unit: 'Kdocs/s',
    ops: kBatch * kSegmentDocs,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'storage segment.find',
    group: _storage,
    label: 'Segment point lookup',
    note: 'bloom + binary search',
    unit: 'Mops/s',
    ops: kBatch * kSegmentDocs,
  ),
  BenchRow(
    id: 'storage segment.scan',
    group: _storage,
    label: 'Segment scan',
    unit: 'Mdocs/s',
    ops: kBatch * kSegmentDocs,
  ),
  BenchRow(
    id: 'storage engine.put',
    group: _storage,
    label: 'Engine write path',
    note: 'WAL append + arena + memtable, no I/O',
    unit: 'Mops/s',
    ops: kBatch * kKeyCount,
  ),
  BenchRow(
    id: 'storage engine.get',
    group: _storage,
    label: 'Engine point read',
    note: 'memtable hit',
    unit: 'Mops/s',
    ops: kBatch * kKeyCount,
  ),
  BenchRow(
    id: 'storage engine.get.segment',
    group: _storage,
    label: 'Engine read from segment',
    note: 'bloom + binary search',
    unit: 'Mops/s',
    ops: kBatch * kSegmentDocs,
  ),

  // Query ------------------------------------------------------------------
  BenchRow(
    id: 'query collection.get',
    group: _query,
    label: 'Collection point read',
    note: 'segment + memtable',
    unit: 'Mops/s',
    ops: kBatch * kKeyCount,
  ),
  BenchRow(
    id: 'query collection.scan',
    group: _query,
    label: 'Collection prefix scan',
    note: '64 entries, merged',
    unit: 'Kdocs/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.cursor',
    group: _query,
    label: 'Collection cursor',
    note: 'streamed, no result list',
    unit: 'Kdocs/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.put.indexed',
    group: _query,
    label: 'Write with index',
    note: 'read-old + index upkeep',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.indexLookup',
    group: _query,
    label: 'Index lookup',
    note: '8 hits + verification',
    unit: 'Kops/s',
    ops: kBatch * kIndexLookupHits,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.indexRange',
    group: _query,
    label: 'Index range scan',
    note: '24 hits over 8 values',
    unit: 'Kops/s',
    ops: kBatch * kIndexRangeHits,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.page',
    group: _query,
    label: 'Paged walk (64 keys)',
    note: '4 pages of 16',
    unit: 'Kdocs/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query collection.textSearch',
    group: _query,
    label: 'Full-text search',
    note: '64 hits, verified',
    unit: 'Kdocs/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query graph.link',
    group: _query,
    label: 'Graph link',
    note: 'both directions, 1 frame',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query graph.outgoing',
    group: _query,
    label: 'Graph outgoing edges',
    note: 'out-degree of every node',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query graph.incoming',
    group: _query,
    label: 'Graph incoming edges',
    note: 'reverse adjacency scan',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query graph.walk',
    group: _query,
    label: 'Graph BFS walk (depth 2)',
    note: '16 roots per round',
    unit: 'Kops/s',
    ops: kBatch * 16,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query reference.put',
    group: _query,
    label: 'Write with a reference',
    note: 'target check + reverse index',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query reference.reverse',
    group: _query,
    label: 'Reverse reference lookup',
    note: 'who points at this user',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query reference.restrict',
    group: _query,
    label: 'Restrict delete (conflict)',
    note: 'reverse lookup + rollback',
    unit: 'Kops/s',
    ops: kBatch * kKeyCount,
    divisor: 1e3,
  ),
  BenchRow(
    id: 'query reference.cascadeCycle',
    group: _query,
    label: 'Cascade delete + rebuild',
    note: 'target with 8 referring docs',
    unit: 'Kops/s',
    ops: kBatch * 8,
    divisor: 1e3,
  ),
];

/// Card name to the row ids it shows.
const Map<String, List<String>> kCards = <String, List<String>>{
  'hero': <String>[
    'serde encode.5field',
    'serde decode.singleScan',
    'storage block.write',
    'storage engine.put',
    'storage engine.get.segment',
    'storage memtable.range',
    'query collection.get',
    'query collection.indexLookup',
    'query collection.indexRange',
    'query collection.textSearch',
    'query graph.outgoing',
    'query reference.put',
  ],
  'format': <String>[
    'serde encode.5field',
    'serde encode.sink',
    'serde decode.singleScan',
    'serde decode.getters',
    'serde project.one',
    'serde project.fields',
    'serde view.compare',
    'serde crc.1KiB',
    'format bytes.mut.write',
    'format bytes.read.view',
  ],
  'storage': <String>[
    'storage block.write',
    'storage block.read',
    'storage wal.frame',
    'storage wal.batch',
    'storage memtable.get',
    'storage memtable.put',
    'storage memtable.range',
    'storage segment.build',
    'storage segment.find',
    'storage segment.scan',
    'storage engine.put',
    'storage engine.get',
    'storage engine.get.segment',
    // Real-filesystem rows from scenarios/open_rss_bench.dart.
    'open.import.docs_per_s',
    'open.reopen.ms',
    'open.rss_mb',
    'open.disk_mb',
    'open.read_p50_us',
    'open.read_p95_us',
    // Real-filesystem rows from scenarios/durability_bench.dart.
    'durability.always.put',
    'durability.batched.put',
    'durability.none.put',
    'durability.wal_bytes_per_doc',
  ],
  'query': <String>[
    'query collection.get',
    'query collection.scan',
    'query collection.cursor',
    'query collection.put.indexed',
    'query collection.indexLookup',
    'query collection.indexRange',
    'query collection.page',
    'query collection.textSearch',
    'query graph.link',
    'query graph.outgoing',
    'query graph.incoming',
    'query graph.walk',
    'query reference.put',
    'query reference.reverse',
    'query reference.restrict',
    'query reference.cascadeCycle',
  ],
};

/// Looks up a row by id.
BenchRow? rowById(String id) {
  for (final row in kRows) {
    if (row.id == id) return row;
  }
  return null;
}
