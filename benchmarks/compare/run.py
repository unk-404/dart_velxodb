"""Run the two comparison suites and write benchcat canonical reports.

Tier A: velxodb storage engine vs sled (raw KV).
Tier B: velxodb document database vs isar_community (document store + index).

Fairness rules this script enforces:

* every engine is flushed and closed, then reopened; the reopen *open* call is
  its own phase, so no engine's open time is hidden inside (or excluded from)
  the read phase;
* all engines read the same key sequence (one seed, one xorshift32, shared with
  the Rust side);
* velxodb and sled write the identical 130-byte payload (the Dart harness dumps
  it to `.tmp/fixture130.bin`, the Rust side reads it);
* the on-disk phase measures a clean, flushed database; isar additionally
  reports its compacted copy (`copyToFile`), because its live directory keeps an
  append-only journal;
* the engine order is shuffled per run so thermal drift cannot systematically
  favour one side;
* the report carries the real platform, the sample count and the semi-range.

    python benchmarks/compare/run.py [--runs=3] [--out=out]

Dart needs `dart pub get`; the isar native library must be at
`benchmarks/compare/dart/bin/libisar.dll` (Windows) or `libisar.so` (Linux).
Rust uses `cargo build --release` once, then runs the binary.
"""

import argparse
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DART = ROOT / "dart"
RUST = ROOT / "rust"
FIXTURE = DART / ".tmp" / "fixture130.bin"

PHASES = {
    "import": ("Import 100k values", "docs/s", "rate", "higher"),
    "open": ("Reopen (open only)", "ms", "milliseconds", "lower"),
    "get": ("20k point reads (post-reopen)", "reads/s", "rate", "higher"),
    "range": ("10k key range scan", "keys/s", "rate", "higher"),
    "index_eq": ("Indexed equality (1k hits)", "queries/s", "rate", "higher"),
    "index_range": (
        "Indexed range (12k hits, closed)",
        "queries/s",
        "rate",
        "higher",
    ),
    "reopen": ("First 1k reads after reopen", "reads/s", "rate", "higher"),
    "disk": ("On-disk size", "MB", "megabytes", "lower"),
}

GROUPS = {
    "engine": {
        "title": "velxodb engine vs sled",
        "group": "Storage engine (raw KV / 130 B values)",
        "engines": {"velxodb-engine": "velxodb", "sled": "sled (raw KV)"},
        # engine.range is measured for sled but not charted for velxodb: the raw
        # StorageEngine has no public KV range cursor yet.
        "phases": ["import", "open", "reopen", "get", "range", "disk"],
    },
    "db": {
        "title": "velxodb database vs isar",
        "group": "Document database (100k docs, one string index)",
        "engines": {"velxodb-db": "velxodb", "isar": "isar_community"},
        "phases": [
            "import",
            "open",
            "reopen",
            "get",
            "index_eq",
            "index_range",
            "disk",
        ],
    },
}


def dart_command(args):
    exe = shutil.which("dart")
    if exe is None:
        return ["dart"] + args
    if exe.lower().endswith(".bat"):
        candidate = Path(exe).parent / "cache" / "dart-sdk" / "bin" / "dart.exe"
        if candidate.exists():
            return [str(candidate)] + args
        return ["cmd", "/c", exe] + args
    return [exe] + args


def run(command, cwd, env=None):
    print(f"$ {' '.join(str(part) for part in command)}", flush=True)
    result = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout or "")
        sys.stderr.write(result.stderr or "")
        raise SystemExit(f"command failed: {command}")
    return result.stdout


def ensure_aot():
    exe = DART / "bin" / ("run.exe" if os.name == "nt" else "run")
    print("$ dart compile exe bin/run.dart", flush=True)
    run(dart_command(["compile", "exe", "bin/run.dart", "-o", str(exe)]), DART)
    return exe


def build_sled():
    exe = RUST / "target" / "release" / (
        "sled_compare.exe" if os.name == "nt" else "sled_compare"
    )
    print("$ cargo build --release", flush=True)
    run(["cargo", "build", "--release", "--quiet"], RUST)
    return exe


def parse(output):
    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "engine" not in row or "phase" not in row:
            continue
        rows.append(row)
    return rows


def median_row(rows):
    """Median of the runs, plus the semi-range as the error estimate.

    With three samples a standard deviation is meaningless; the semi-range is an
    honest bound on the observed spread and is what the cards print.
    """
    ms = statistics.median(row["ms"] for row in rows)
    entries = int(statistics.median(row["entries"] for row in rows))
    byte_length = int(statistics.median(row["bytes"] for row in rows))
    if len(rows) > 1 and ms > 0:
        spread = max(row["ms"] for row in rows) - min(row["ms"] for row in rows)
        semi_range = spread / 2 / ms * 100
    else:
        semi_range = 0.0
    return {
        "ms": ms,
        "entries": entries,
        "bytes": byte_length,
        "semi_range_pct": semi_range,
        "samples": len(rows),
    }


def phase_value(phase, row):
    """Returns (value, unit, direction, note)."""
    _, unit, kind, direction = PHASES[phase]
    if kind == "rate":
        seconds = max(row["ms"], 0.001) / 1000
        value = row["entries"] / seconds if row["entries"] else 0.0
        note = (
            f"median of {row['samples']} · {row['ms']:.1f} ms for "
            f"{row['entries']} ops · semi-range ±{row['semi_range_pct']:.1f}%"
        )
        return value, unit, direction, note
    if kind == "milliseconds":
        return (
            row["ms"],
            unit,
            direction,
            f"median of {row['samples']} · semi-range "
            f"±{row['semi_range_pct']:.1f}%",
        )
    value = row["bytes"] / 1e6
    return (
        value,
        unit,
        direction,
        f"median of {row['samples']} · {value:.1f} MB",
    )


def write_reports(by_engine, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    platform_meta = {
        "os": "macos"
        if platform.system() == "Darwin"
        else platform.system().lower(),
        "arch": platform.machine().lower(),
    }
    for group, spec in GROUPS.items():
        for engine_key, series_label in spec["engines"].items():
            phases = by_engine.get(engine_key, {})
            benchmarks = []
            for phase in spec["phases"]:
                row = phases.get(phase)
                if phase == "disk" and engine_key == "isar":
                    compacted = phases.get("disk.compacted")
                    if compacted is not None:
                        row = compacted
                if row is None:
                    continue
                value, unit, direction, note = phase_value(phase, row)
                if phase == "disk" and engine_key == "isar":
                    note += " · compacted copy (copyToFile)"
                benchmarks.append(
                    {
                        "id": f"{group}.{phase}",
                        "group": spec["group"],
                        "label": PHASES[phase][0],
                        "note": note,
                        "unit": unit,
                        "value": value,
                        "direction": direction,
                        "stats": {
                            "samples": row["samples"],
                            "rme_pct": row["semi_range_pct"],
                        },
                    }
                )
            report = {
                "schema": "benchcat/report@1",
                "meta": {
                    "tool": "velxo-compare",
                    "tool_version": "4",
                    "platform": platform_meta,
                },
                "benchmarks": benchmarks,
            }
            target = out_dir / f"{group}-{engine_key}.json"
            target.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(f"wrote {target} ({series_label})")


def print_group(group, by_engine):
    spec = GROUPS[group]
    print()
    print(spec["title"])
    print(f"{'engine':16} " + " ".join(f"{p:>16}" for p in spec["phases"]))
    for engine_key, series_label in spec["engines"].items():
        cells = []
        for phase in spec["phases"]:
            row = by_engine.get(engine_key, {}).get(phase)
            if row is None:
                cells.append(f"{'n/a':>16}")
            elif phase == "disk":
                cells.append(f"{row['bytes'] / 1e6:>10.1f} MB".rjust(16))
            elif phase == "open":
                cells.append(f"{row['ms']:>10.2f} ms".rjust(16))
            else:
                cells.append(
                    f"{row['ms']:>8.1f} ms/{row['entries']:>5}".rjust(16)
                )
        print(f"{series_label:16} " + " ".join(cells))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", default="out")
    parser.add_argument("--skip-isar", action="store_true")
    parser.add_argument("--skip-sled", action="store_true")
    parser.add_argument("--seed", type=int, default=1234)
    args = parser.parse_args()

    out_dir = (ROOT / args.out).resolve()
    if out_dir.exists():
        shutil.rmtree(out_dir)
    # A crashed run must not leave 20 MB of segments behind.
    shutil.rmtree(DART / ".tmp", ignore_errors=True)
    (DART / ".tmp").mkdir(parents=True, exist_ok=True)
    if (RUST / "sled_db").exists():
        shutil.rmtree(RUST / "sled_db", ignore_errors=True)

    isar_lib = (
        DART / "bin" / ("libisar.dll" if os.name == "nt" else "libisar.so")
    )
    use_isar = isar_lib.exists() and not args.skip_isar
    if not use_isar:
        print(f"warning: {isar_lib} missing; isar will be skipped", file=sys.stderr)

    dart_exe = ensure_aot()
    sled_exe = None if args.skip_sled else build_sled()

    # Writes .tmp/fixture130.bin before either side needs it.
    run([str(dart_exe), "fixture"], DART, env={**os.environ, "VELXO_FIXTURE": str(FIXTURE)})
    fixture_check = FIXTURE.read_bytes() if FIXTURE.exists() else b""
    print(f"fixture: {len(fixture_check)} bytes at {FIXTURE}")

    engine_names = ["engine", "db"]
    if use_isar:
        engine_names.append("isar")
    if sled_exe is not None:
        engine_names.append("sled")

    all_rows = []
    for run_index in range(args.runs):
        order = list(engine_names)
        random.Random(args.seed + run_index).shuffle(order)
        print(f"-- run {run_index + 1}/{args.runs}: {' -> '.join(order)}")
        for name in order:
            if name == "sled":
                env = {**os.environ, "VELXO_FIXTURE": str(FIXTURE)}
                all_rows += parse(run([str(sled_exe)], RUST, env=env))
            else:
                env = {**os.environ, "VELXO_FIXTURE": str(FIXTURE)}
                all_rows += parse(run([str(dart_exe), name], DART, env=env))

    grouped = {}
    for row in all_rows:
        grouped.setdefault((row["engine"], row["phase"]), []).append(row)

    by_engine = {}
    for (engine, phase), rows in grouped.items():
        by_engine.setdefault(engine, {})[phase] = median_row(rows)

    write_reports(by_engine, out_dir)
    print_group("engine", by_engine)
    print_group("db", by_engine)
    shutil.rmtree(DART / ".tmp", ignore_errors=True)


if __name__ == "__main__":
    main()
