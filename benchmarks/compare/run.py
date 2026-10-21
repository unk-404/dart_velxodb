"""Run the two comparison suites and write benchcat canonical reports.

Tier A: velxodb storage engine vs sled (raw KV).
Tier B: velxodb document database vs isar_community (document store + index).

Every read/query phase runs after flush + close + reopen on all engines, so no
side serves from a warm memtable. Each suite runs RUNS times; the reports carry
the median and the semi-range as the error estimate.

    python benchmarks/compare/run.py

Dart needs `dart pub get`; the isar native library must be at
`benchmarks/compare/dart/bin/libisar.dll` (Windows) or `libisar.so` (Linux).
Rust uses `cargo run --release`.
"""

import json
import os
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DART = ROOT / "dart"
RUST = ROOT / "rust"
OUT = ROOT / "out"
RUNS = 3

PHASE_SPECS = {
    "import": ("Import 100k values", "docs/s", "higher"),
    "get": ("20k point reads (post-reopen)", "reads/s", "higher"),
    "range": ("10k key range scan", "keys/s", "higher"),
    "index_eq": ("Indexed equality (1k hits)", "queries/s", "higher"),
    "index_range": ("Indexed range (12k hits, closed)", "queries/s", "higher"),
    "reopen": ("Reopen + 1k reads", "reads/s", "higher"),
    "disk": ("On-disk size", "MB", "lower"),
}

GROUPS = {
    "engine": {
        "title": "velxodb engine vs sled",
        "group": "Storage engine (raw KV / 130 B values)",
        "engines": {"velxodb-engine": "velxodb", "sled": "sled (raw KV)"},
        # engine.range is measured for sled but not charted: velxodb has no
        # public engine-level KV range cursor yet.
        "phases": ["import", "reopen", "get", "range", "disk"],
    },
    "db": {
        "title": "velxodb database vs isar",
        "group": "Document database (100k docs, one string index)",
        "engines": {"velxodb-db": "velxodb", "isar": "isar_community"},
        "phases": [
            "import",
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


def run(command, cwd):
    print(f"$ {' '.join(command)}", flush=True)
    result = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout or "")
        sys.stderr.write(result.stderr or "")
        raise SystemExit(f"command failed: {command}")
    return result.stdout


def ensure_aot():
    print("$ dart compile exe bin/run.dart -o bin/run.exe", flush=True)
    result = subprocess.run(
        dart_command(["compile", "exe", "bin/run.dart", "-o", "bin/run.exe"]),
        cwd=DART,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout or "")
        sys.stderr.write(result.stderr or "")
        raise SystemExit("dart compile failed")
    return DART / "bin" / "run.exe"


def parse(output):
    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def median_row(rows):
    ms = statistics.median(row["ms"] for row in rows)
    entries = int(statistics.median(row["entries"] for row in rows))
    byte_length = int(statistics.median(row["bytes"] for row in rows))
    if len(rows) > 1 and ms > 0:
        rme = (max(row["ms"] for row in rows) - min(row["ms"] for row in rows)) / 2 / ms * 100
    else:
        rme = 0.0
    return {
        "ms": ms,
        "entries": entries,
        "bytes": byte_length,
        "rme": rme,
    }


def write_reports(by_engine):
    OUT.mkdir(parents=True, exist_ok=True)
    for group, spec in GROUPS.items():
        for engine_key, series_label in spec["engines"].items():
            phases = by_engine.get(engine_key, {})
            benchmarks = []
            for phase in spec["phases"]:
                row = phases.get(phase)
                if row is None:
                    continue
                label, unit, direction = PHASE_SPECS[phase]
                if phase == "disk":
                    value = row["bytes"] / 1e6
                    note = f"median of {RUNS} · {value:.1f} MB"
                else:
                    seconds = max(row["ms"], 0.001) / 1000
                    value = (row["entries"] or 1) / seconds
                    note = (
                        f"median of {RUNS} · {row['ms']:.1f} ms for "
                        f"{row['entries']} ops"
                    )
                benchmarks.append(
                    {
                        "id": f"{group}.{phase}",
                        "group": spec["group"],
                        "label": label,
                        "note": note,
                        "unit": unit,
                        "value": value,
                        "direction": direction,
                        "stats": {"samples": RUNS, "rme_pct": row["rme"]},
                    }
                )
            report = {
                "schema": "benchcat/report@1",
                "meta": {
                    "tool": "velxo-compare",
                    "tool_version": "3",
                    "platform": {"os": "Windows", "arch": "x86_64"},
                },
                "benchmarks": benchmarks,
            }
            target = OUT / f"{group}-{engine_key}.json"
            target.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(f"wrote {target} ({series_label})")


def print_group(group, by_engine):
    spec = GROUPS[group]
    print()
    print(spec["title"])
    print(f"{'engine':16} " + " ".join(f"{p:>14}" for p in spec["phases"]))
    for engine_key, series_label in spec["engines"].items():
        cells = []
        for phase in spec["phases"]:
            row = by_engine.get(engine_key, {}).get(phase)
            if row is None:
                cells.append(f"{'n/a':>14}")
            elif phase == "disk":
                cells.append(f"{row['bytes'] / 1e6:>8.1f} MB".rjust(14))
            else:
                cells.append(
                    f"{row['ms']:>8.1f} ms/{row['entries']:>4}".rjust(14)
                )
        print(f"{series_label:16} " + " ".join(cells))


def main():
    isar_lib = DART / "bin" / ("libisar.dll" if os.name == "nt" else "libisar.so")
    if not isar_lib.exists():
        print(f"warning: {isar_lib} missing; isar will be skipped", file=sys.stderr)

    exe = ensure_aot()
    all_rows = []
    for _ in range(RUNS):
        all_rows += parse(run([str(exe), "engine"], DART))
        all_rows += parse(run([str(exe), "db"], DART))
        if isar_lib.exists():
            all_rows += parse(run([str(exe), "isar"], DART))
        all_rows += parse(run(["cargo", "run", "--release", "--quiet"], RUST))

    grouped = {}
    for row in all_rows:
        grouped.setdefault((row["engine"], row["phase"]), []).append(row)

    by_engine = {}
    for (engine, phase), rows in grouped.items():
        by_engine.setdefault(engine, {})[phase] = median_row(rows)

    write_reports(by_engine)
    print_group("engine", by_engine)
    print_group("db", by_engine)


if __name__ == "__main__":
    main()
