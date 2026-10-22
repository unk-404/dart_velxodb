/// Workload constants shared by every suite and by the card manifest.
///
/// Single source of truth: the suites import these constants and
/// `lib/manifest.dart` derives every card value from the same numbers, so a
/// change here cannot silently invalidate the charts.
library;

/// Operations per benchmark iteration in the micro suites.
///
/// `benchmark_test` reports the rate of the whole iteration and its timer has
/// microsecond granularity; batching keeps a 130 B encode measurable.
const int kBatch = 100;

/// Keys per collection in the query suite.
const int kKeyCount = 64;

/// Documents per block in the block/write benchmarks.
const int kDocsPerBlock = 20;

/// Documents per segment in the segment benchmarks.
const int kSegmentDocs = 64;

/// Size of one encoded sample document, in bytes.
const int kDocBytes = 130;

/// Entries in the isolated memtable benchmark.
const int kMemtableDocs = 50000;

/// Entries returned by one memtable range seek.
const int kMemtableWindow = 1000;

/// Distinct index values used by the secondary-index benchmarks.
const int kIndexValues = 8;

/// Page size for the paging benchmark.
const int kPageLimit = 16;

/// Hits per index equality lookup.
const int kIndexLookupHits = 8;

/// Hits per index range lookup.
const int kIndexRangeHits = 24;

/// Bytes per CRC benchmark payload.
const int kCrcBytes = 1024;

/// Out-edges per node in the graph benchmark, including the ring edge.
const int kGraphOutDegree = 4;

/// Documents that reference one deleted target in the cascade benchmark.
const int kCascadeChildren = 8;

/// Documents imported by the open/RSS scenario at the small scale.
const int kOpenDocsSmall = 10000;

/// Documents imported by the open/RSS scenario by default.
const int kOpenDocsLarge = 100000;

/// Documents imported by the open/RSS scenario with `--large` (nightly only).
const int kOpenDocsHuge = 1000000;

/// Documents imported by the object-store scenario.
const int kObjectStoreDocs = 200000;

/// Write batch size used by every scenario that imports documents.
const int kImportBatch = 500;

/// Reads issued by the point-read scenarios.
const int kScenarioReads = 20000;

/// Documents in the durability scenario.
const int kDurabilityDocs = 20000;
