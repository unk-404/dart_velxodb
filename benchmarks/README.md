# benchmarks/

How velxodb is measured, what each number means, and how to regenerate every
chart in `assets/`.

This is the single methodology document. The engine-versus-competitor
comparison has its own run details in [`compare/README.md`](compare/README.md),
but the rules below apply to both.

---

## Layout

```
benchmarks/
├─ benchcat.toml          headline card (12 rows)        -> assets/benchmarks.svg
├─ cards/                 one config per layer card      -> assets/benchmarks-<card>.svg
│   ├─ format.toml        VXS codec + buffer primitives
│   ├─ storage.toml       block/WAL/segment/engine + real-disk rows
│   ├─ query.toml         collections, indexes, graph, references
│   └─ objectstore.toml   object-store request shape
├─ suites/                micro benchmarks, driven by benchmark_test
├─ scenarios/             system benchmarks, plain `dart run` scripts
├─ lib/                   shared harness (workload constants, fixtures, stats, report, manifest)
├─ tool/                  normalize / run_all / gate
├─ results/               raw output (gitignored)
└─ compare/               velxodb vs sled and isar (separate package, own README)
```

Two kinds of benchmark, split by how they run and what they cost:

| | `suites/` | `scenarios/` |
| --- | --- | --- |
| Driver | `dart run benchmark_test` | `dart run scenarios/<name>.dart` |
| File pattern | `*_test.dart` (auto-discovered) | `*_bench.dart` (never auto-discovered) |
| Cost | seconds, in-memory | seconds to minutes, real filesystem |
| Output | JSONL on stdout | `results/<name>.json` |
| Charted | card rows | card rows (storage, objectstore) |

A file is `*_test.dart` only if it is cheap and safe to run on every push.
Anything that writes hundreds of megabytes or fsyncs belongs in `scenarios/`.

## Run everything

```sh
# from the repository root
dart run benchmarks/tool/run_all.dart             # micro + scenarios + render
dart run benchmarks/tool/run_all.dart --quick     # small scales (CI-friendly)
dart run benchmarks/tool/run_all.dart --only=query
dart run benchmarks/tool/run_all.dart --no-render # collect results only
dart run benchmarks/tool/run_all.dart --compare   # also run compare/run.py
```

Rendering needs benchcat. `run_all` uses `--benchcat=<path>`, then `$BENCHCAT`,
then `.agents/tools/benchcat/benchcat.exe`, then `benchcat` on `PATH`. CI uses
the `unk-404/benchcat` action instead.

**Fonts are supplied by benchcat.** Every card names the bundled catalogue
family `sniglet` (`[font] family`), and the action points the renderer at its
own OFL catalogue automatically. No font file is committed to this repository.
For a local render, fetch benchcat's
[`fonts/` catalogue](https://github.com/unk-404/benchcat/tree/master/fonts) (or
extract `benchcat-fonts.7z` from its `fonts-latest` release) and point
`BENCHCAT_FONT_DIR` at it; `--font-file` is only for a custom face whose license
permits embedding. Never point `BENCHCAT_FONT_DIR` at `C:\Windows\Fonts` and
never render with Arial, Segoe or any commercial CJK face.

The micro suites default to the JIT VM, which is what CI renders today. They
also run under AOT, which is 1.0–1.6x faster (median ~1.2x) and matches the
comparison harness's compiler:

```sh
dart run benchmark_test -c aot --output jsonl suites | grep -E '^\{' > results/main.jsonl
```

Individual steps, if you want them separately:

```sh
cd benchmarks
dart run benchmark_test --output jsonl suites | grep -E '^\{' > results/main.jsonl
dart run scenarios/object_store_bench.dart                          # request shape
dart run scenarios/open_rss_bench.dart      [--quick|--large]       # open, RSS, disk
dart run scenarios/durability_bench.dart                            # fsync tiers
dart run tool/normalize.dart                                        # JSONL -> cards
dart run tool/gate.dart                                             # sanity gate
```

> Note: `benchmark_test` writes progress lines in addition to the JSONL, and a
> build failure can look like a silent exit after `Running benchmarks with
> jit...`. Keep only lines starting with `{` (as above; `normalize` does the
> same) and check the exit code, not the log.

## What each row means

- **Unit.** `MB/s` and `docs/s` are throughput; `ns/op` and `us` are per
  operation; `requests`, `MB`, `B`, `x` and `ms` are absolute costs.
- **Direction.** Rows are higher-is-better unless the report says
  `direction: lower` (latency, bytes, request counts, disk size).
- **The workload factor lives in `lib/workload.dart` and the unit conversion in
  `lib/manifest.dart`.** The cards contain no formulas. If a suite's batch size
  changes, the chart denominator follows; nothing is re-derived by hand.
- **Error.** Micro rows carry `benchmark_test`'s relative margin of error and
  sample count in the row note (`±0.31% (83946 samples)`). Scenario rows carry
  the spread of their own samples where they have more than one.
- **JIT.** The micro suites run on the JIT VM by default, which is what
  `benchmark_test` reports; the comparison harness is AOT-compiled. Do not mix
  the two sets of numbers in one sentence — pass `-c aot` to the micro suite if
  you want both sides on the same compiler.
- **In-memory versus real disk.** Rows under `Storage` in the micro suites run
  over a counting no-I/O directory, so they measure codecs and data structures,
  not the disk. Everything from `open.…` and `durability.…` down in
  `assets/benchmarks-storage.svg` runs on `LocalStorageDirectory` and pays for
  real writes and fsyncs.

## Cards

| Card | Asset | Rows |
| --- | --- | --- |
| headline | `assets/benchmarks.svg` | one representative row per layer |
| format | `assets/benchmarks-format.svg` | encode/decode/projection/CRC + blit primitives |
| storage | `assets/benchmarks-storage.svg` | block, WAL, memtable, segment, engine, real-disk open/RSS/durability |
| query | `assets/benchmarks-query.svg` | collections, indexes, paging, full-text, graph, references |
| objectstore | `assets/benchmarks-objectstore.svg` | request counts and bytes for a 200k-doc workload |
| engine vs sled | `assets/benchmarks-engine.svg` | `compare/` tier A |
| database vs isar | `assets/benchmarks-db.svg` | `compare/` tier B |

## Deterministic gates

Timing is machine-dependent, request and byte counts are not. These are asserted
by the scenarios themselves (a violation exits non-zero) and re-checked by
`tool/gate.dart`:

- object store: `open` and `reopen` are exactly 2 requests each
  (1 GET manifest + 1 LIST); import is `docs/batch + 2*flushes` PUTs plus
  `flushes` batch DELETEs; churn is `updates/batch + deletes/batch + 2` PUTs plus
  one batch DELETE; stored bytes ≤ 1.5× payload. (The whole-workload
  `requestAmplification` row is reported but not gated: it legitimately includes
  the compaction rewrite.)
- open/RSS: on-disk size ≤ 1.5× payload; RSS increase on reopen ≤ 4× payload.
- every measured micro row reaches a card (an uncharted measurement is a bug,
  not a detail).

`tool/gate.dart` also fails on a missing/empty card report and on any zero or
non-finite value, and can compare timing rows against `results/baseline.json`
(`--update-baseline` writes it; `--timing=warn` is the default, use
`--timing=fail` only on a dedicated runner).

## Caveats that stay visible

- The object store is the in-repo simulator: counts are exact, wall times are
  local CPU only, and there is no network latency, retry or bandwidth model.
  LIST is charged one request per 1000 returned keys, which is what S3 does.
- The page cache is warm for every scenario. `open_rss_bench.dart` measures a
  reopen, not a cold start; dropping the OS cache is not portable in CI.
- RSS is sampled in the same process around `openSync`, allocator slack
  included.
- The micro suites use a 64-key, 64-document, 130-byte world. They are codec and
  data-structure benchmarks; scale behaviour is what `scenarios/` and `compare/`
  are for.
- `compare/` is a separate package with its own `pubspec.yaml` and lockfile and
  is analyzed separately (`analysis_options.yaml` excludes it).

## Not measured yet

Tracked for the next round, so the absence is deliberate and visible:

crash-recovery time, read/write mixed workloads and delete churn on the local
engine, documents larger than a block, multi-isolate throughput through
`VelxoWorker`, cold-cache reads, and a 1M-document scale card
(`open_rss_bench.dart --large` exists but is nightly-only).
