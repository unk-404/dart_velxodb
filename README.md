# velxodb

An embedded, pure-Dart document database built for very large local datasets.

- **Pure Dart** - runs on the VM, dart2js and dart2wasm.
- **Zero-copy storage** - a self-designed binary format (\VXS\) with field-level
  random access, no deserialization into maps.
- **Built for scale** - point lookups over 10^9 documents, indexed retrieval over
  10^7 documents on a single machine.
- **Pluggable storage** - a public \ObjectStore\ SPI; local mmap, OPFS and HTTP
  Range ship in-box, anything else (S3, GCS, your gateway) is a small adapter.
- **Mongo-style API** - \collection('x').insertOne({...})\, \ind(filter)\,
  \updateOne\, \ggregate\. Client-side facade, no wire protocol.
- **Generated codecs** - annotate a Dart class, get a monomorphic codec.

## Status

Pre-alpha. The workspace, the binary format and the storage engine are being
built in that order; see the roadmap for what is expected to work when.

| Milestone | Contents |
| --- | --- |
| M1 | local CRUD, crash recovery |
| M2 | primary/secondary indexes, query planner |
| M3 | retrieval primitives (inverted / n-gram) |
| M4 | code generator |
| M5 | web (OPFS), HTTP backends |
| M6 | Mongo-style facade |

## Packages

| Package | Purpose |
| --- | --- |
| \packages/velxodb\ | engine, format, indexes, public API |
| \packages/velxodb_generator\ | annotation-driven codecs (planned) |
| \packages/velxodb_mongo\ | Mongo-style facade (planned) |

## Benchmarks

Benchmarks use [\enchmark_test\](https://pub.dev/packages/benchmark_test) and are
rendered to \ssets/benchmarks.svg\ by
[benchcat](https://github.com/unk-404/benchcat) in CI:

\\\sh
cd packages/velxodb
dart run benchmark_test --output jsonl benchmark > ../../bench.jsonl
\\\

## License

MIT.