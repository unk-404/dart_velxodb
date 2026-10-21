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

## Caveats (deliberately visible)

- **The engine stores VXS documents.** `StorageEngine.get` returns a parsed
  document, so tier A writes valid VXS values; sled accepts opaque bytes. This
  is an abstraction difference, not a trick.
- **No engine-level KV range.** Tier A therefore measures no range row for
  velxodb. sled's 10k-key range is reported in the run output but not charted.
- **Closed ranges.** isar 3.4.1 returns zero rows for an exclusive-upper string
  `senderBetween(..., includeUpper: false)`; both sides use a closed range
  (`u10..u20`, 12k hits) so the hit counts match.
- **Single run, no cache flush.** Compare deltas, not absolute numbers.
- **Dart AOT vs native.** The Dart harness is compiled AOT; isar is its native
  library, sled is a release build.

## CI

The `compare` job in `.github/workflows/ci.yml` downloads the isar Linux core,
runs both suites, renders both cards and uploads/commits them.
