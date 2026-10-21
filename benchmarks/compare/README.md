# Comparison harness

Two suites, one per abstraction layer, so the numbers are apples to apples.

| Tier | velxodb side | compared with | Workload |
| --- | --- | --- | --- |
| A | `StorageEngine` (raw KV) | sled 0.34 (raw KV) | 100k × one 130 B value, 20k point reads, reopen, disk size |
| B | `VelxoDatabase` + `Collection` | isar_community 3.4.1 | 100k documents, one string index, equality/range, point reads, reopen, disk size |

## Run

```sh
dart pub get                      # repository root
cd benchmarks/compare/dart && dart pub get

# Windows: bin/libisar.dll, Linux: bin/libisar.so
python run.py                    # from benchmarks/compare
```

`run.py` compiles the Dart harness AOT, runs both suites and writes canonical
benchcat reports under `out/`. Render the cards with:

```sh
benchcat render --config benchmarks/compare/benchcat-engine.toml \
  -o assets/benchmarks-engine.svg
benchcat render --config benchmarks/compare/benchcat-db.toml \
  -o assets/benchmarks-db.svg
```

CI does exactly this on Linux and commits the two SVGs on `main`.

## Methodology

- Every import is written with the engine's synchronous batch API
  (`putManySync`, `writeTxnSync` + `putAllSync`, `apply_batch`).
- Every read/query phase runs after flush + close + reopen, so no engine serves
  from a warm memtable; a 1k-read warm-up precedes the timed reads.
- Opening is measured as its own phase: the stopwatch starts before `open` and
  stops before the first read, for every engine.
- All engines read the same deterministic key sequence (one seed, one xorshift
  shared with the Rust side); the engine order is shuffled per run so thermal
  drift cannot systematically favour one side.
- 3 runs per suite; reports carry the median and the semi-range (stored as
  `semi_range_pct`, printed as `±` on the cards).
- Tier A writes the same 130-byte payload on both sides: the Dart harness dumps
  it to `.tmp/fixture130.bin` and the sled side writes those exact bytes.
- On-disk size is sampled after flush + close; isar additionally reports its
  compacted copy (`copyToFile`) because its live directory keeps an append-only
  journal.
- Result sets are verified: equality returns 1,000 rows, the closed range
  12,000 rows, and every timed read must hit; the harness throws otherwise.

## Caveats (deliberately visible)

- **The engine stores VXS documents.** `StorageEngine.get` parses the document,
  so tier A writes valid VXS values; sled accepts opaque bytes. This is an
  abstraction difference, not a trick.
- **No engine-level KV range.** Tier A therefore measures no range row for
  velxodb. sled's 10k-key range is reported in the run output but not charted.
- **Closed ranges.** isar 3.4.1 returns zero rows for an exclusive-upper string
  `senderBetween(..., includeUpper: false)`; both sides use a closed range
  (`u10..u20`, 12k hits) so the hit counts match.
- **OS page cache is warm.** The systems are reopened but caches are not
  dropped; this is a post-reopen comparison, not a cold-start one.
- **Return types differ.** velxodb returns zero-copy bytes/views; isar
  materializes `Doc` objects. That is a design advantage, not a hidden shortcut.
- **Dart AOT vs native.** The Dart harness is compiled AOT; isar is its native
  library, sled is a release build.

## CI

The `compare` job in `.github/workflows/ci.yml` downloads the isar Linux core,
runs both suites with `python3 run.py`, renders both cards and uploads them with
the raw `out/*.json`; the `assets` job commits all charts to `main`. The job is
pinned to the same Dart SDK as the rest of the matrix.
