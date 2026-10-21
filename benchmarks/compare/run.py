"""Run the two comparison suites and write benchcat canonical reports.

Tier A: velxodb storage engine vs sled (raw KV).
Tier B: velxodb document database vs isar_community (document store + index).

    python .agents/benchmarks/compare/run.py

Dart needs `dart pub get` + build_runner output; isar native library at
compare/dart/bin/libisar.dll on Windows. Rust uses `cargo run --release`.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DART = ROOT / "dart"
RUST = ROOT / "rust"
OUT = ROOT / "out"

PHASE_SPECS = {
    "import": ("Import 100k documents", "docs/s", "higher"),
    "get": ("20k point reads", "reads/s", "higher"),
    "range": ("10k key range scan", "keys/s", "higher"),
    "index_eq": ("Indexed equality (1k hits)", "queries/s", "higher"),
    "index_range": ("Indexed range (10k hits)", "queries/s", "higher"),
    "reopen": ("Reopen + 1k reads", "reads/s", "higher"),
    "disk": ("On-disk size", "MB", "lower"),
}

GROUPS = {
    "engine": {
        "title": "velxodb engine vs sled",
        "group": "Storage engine (raw KV / 130 B values)",
        "engines": {"velxodb-engine": "velxodb", "sled": "sled (raw KV)"},
        "phases": ["import", "get", "reopen", "range", "disk"],
    },
    "db": {
        "title": "velxodb database vs isar",
        "group": "Document database (100k docs, one string index)",
        "engines": {"velxodb-db": "velxodb", "isar": "isar_community"},
        "phases": [
            "import",
            "get",
            "index_eq",
            "index_range",
            "reopen",
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
                else:
                    seconds = max(row["ms"], 0.001) / 1000
                    value = (row["entries"] or 1) / seconds
                benchmarks.append(
                    {
                        "id": f"{group}.{phase}",
                        "group": spec["group"],
                        "label": label,
                        "note": (
                            f"{row['bytes'] / 1e6:.1f} MB"
                            if phase == "disk"
                            else f"{row['ms']:.1f} ms for {row['entries']} ops"
                        ),
                        "unit": unit,
                        "value": value,
                        "direction": direction,
                    }
                )
            report = {
                "schema": "benchcat/report@1",
                "meta": {
                    "tool": "velxo-compare",
                    "tool_version": "2",
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
    dll = DART / "bin" / "libisar.dll"
    if not dll.exists():
        print(f"warning: {dll} missing; isar will be skipped", file=sys.stderr)

    exe = ensure_aot()
    rows = []
    rows += parse(run([str(exe), "engine"], DART))
    rows += parse(run([str(exe), "db"], DART))
    if dll.exists():
        rows += parse(run([str(exe), "isar"], DART))
    rows += parse(run(["cargo", "run", "--release", "--quiet"], RUST))

    by_engine = {}
    for row in rows:
        by_engine.setdefault(row["engine"], {})[row["phase"]] = row

    write_reports(by_engine)
    print_group("engine", by_engine)
    print_group("db", by_engine)


if __name__ == "__main__":
    main()
