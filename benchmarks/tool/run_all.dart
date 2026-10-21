// One command for the whole local benchmark flow.
//
// From the repository root:
//   dart run benchmarks/tool/run_all.dart                 # micro + scenarios + cards
//   dart run benchmarks/tool/run_all.dart --quick         # small scales, fast
//   dart run benchmarks/tool/run_all.dart --only=query    # one card
//   dart run benchmarks/tool/run_all.dart --compare       # also run compare/run.py
//   dart run benchmarks/tool/run_all.dart --no-render     # collect results only
//
// It never runs `dart pub get`; CI does that explicitly. Rendering needs a
// benchcat binary: `--benchcat=<path>` or `$BENCHCAT`, falling back to
// `.agents/tools/benchcat/benchcat.exe` and then to `benchcat` on PATH.
// The cards name the bundled catalogue family `sniglet`; the action supplies
// the catalogue, and a local render needs `BENCHCAT_FONT_DIR` pointing at a
// copy of benchcat's `fonts/` directory.
import 'dart:io';

/// Where a card's rows come from, and where its SVG goes.
final class _Card {
  /// Creates a card description.
  const _Card(this.name, this.output, {this.scenarios = const <String>[]});

  /// Card name; the config is `cards/<name>.toml` and the input
  /// `results/<name>.json`.
  final String name;

  /// Output SVG, relative to the repository root.
  final String output;

  /// Scenarios that must run before this card can be normalized.
  final List<String> scenarios;
}

const List<_Card> _cards = <_Card>[
  _Card('hero', 'assets/benchmarks.svg'),
  _Card('format', 'assets/benchmarks-format.svg'),
  _Card(
    'storage',
    'assets/benchmarks-storage.svg',
    scenarios: <String>['open_rss', 'durability'],
  ),
  _Card('query', 'assets/benchmarks-query.svg'),
  _Card(
    'objectstore',
    'assets/benchmarks-objectstore.svg',
    scenarios: <String>['object_store'],
  ),
  _Card('engine', 'assets/benchmarks-engine.svg'),
  _Card('db', 'assets/benchmarks-db.svg'),
];

Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final noRender = args.contains('--no-render');
  final withCompare = args.contains('--compare');
  var only = <String>{};
  var benchcat = Platform.environment['BENCHCAT'] ?? '';

  for (final arg in args) {
    if (arg.startsWith('--only=')) {
      only = arg.substring('--only='.length).split(',').toSet();
    } else if (arg.startsWith('--benchcat=')) {
      benchcat = arg.substring('--benchcat='.length);
    }
  }

  final toolDir = File.fromUri(Platform.script).parent;
  final benchDir = toolDir.parent;
  final rootDir = benchDir.parent;
  final results = Directory('${benchDir.path}/results')..createSync();

  bool wants(String card) => only.isEmpty || only.contains(card);

  // 1. Micro suites -------------------------------------------------------
  if (wants('hero') || wants('format') || wants('storage') || wants('query')) {
    stdout.writeln('== micro suites (benchmark_test) ==');
    final run = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'benchmark_test',
      '--output',
      'jsonl',
      'suites',
    ], workingDirectory: benchDir.path);
    if (run.exitCode != 0) {
      stderr.writeln(run.stdout);
      stderr.writeln(run.stderr);
      exitCode = run.exitCode;
      return;
    }
    File('${results.path}/main.jsonl')
        .writeAsStringSync(run.stdout as String? ?? '');
    stdout.writeln('wrote results/main.jsonl');
  }

  // 2. Scenarios ----------------------------------------------------------
  final scenarioFlags = quick ? <String>['--quick'] : <String>[];
  Future<void> scenario(String script, List<String> extra) async {
    stdout.writeln('== scenarios/$script ${extra.join(' ')} ==');
    final run = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'scenarios/$script',
      ...extra,
    ], workingDirectory: benchDir.path);
    stdout.write(run.stdout);
    if (run.exitCode != 0) {
      stderr.writeln(run.stderr);
      exitCode = run.exitCode;
      return;
    }
  }

  for (final card in _cards) {
    if (!wants(card.name)) continue;
    for (final name in card.scenarios) {
      if (name == 'object_store') {
        await scenario('object_store_bench.dart', scenarioFlags);
      } else if (name == 'open_rss') {
        await scenario('open_rss_bench.dart', scenarioFlags);
      } else if (name == 'durability') {
        await scenario('durability_bench.dart', const <String>[]);
      }
    }
    if (exitCode != 0) return;
  }

  // 3. Normalize ---------------------------------------------------------
  stdout.writeln('== normalize ==');
  final normalize = await Process.run(Platform.resolvedExecutable, <String>[
    'run',
    'tool/normalize.dart',
  ], workingDirectory: benchDir.path);
  stdout.write(normalize.stdout);
  stderr.write(normalize.stderr);
  if (normalize.exitCode != 0) {
    exitCode = normalize.exitCode;
    return;
  }

  // 4. Compare (optional) ------------------------------------------------
  if (withCompare) {
    stdout.writeln('== compare/run.py ==');
    final run = await Process.run('python', <String>[
      'compare/run.py',
    ], workingDirectory: benchDir.path);
    stdout.write(run.stdout);
    stderr.write(run.stderr);
    if (run.exitCode != 0) {
      exitCode = run.exitCode;
      return;
    }
  }

  // 5. Render ------------------------------------------------------------
  if (noRender) return;
  final exe = _resolveBenchcat(benchcat, rootDir);
  if (exe == null) {
    stderr.writeln(
      'warning: no benchcat binary found; skipping render '
      '(pass --benchcat=<path> or set BENCHCAT)',
    );
    return;
  }
  for (final card in _cards) {
    if (!wants(card.name)) continue;
    final config = File(_configPath(benchDir, card.name));
    if (!config.existsSync()) {
      stderr.writeln('warning: ${config.path} missing; skipping ${card.name}');
      continue;
    }
    final out = File('${rootDir.path}/${card.output}');
    out.parent.createSync(recursive: true);
    final render = await Process.run(exe, <String>[
      'render',
      '--config',
      config.path,
      '-o',
      out.path,
    ], workingDirectory: rootDir.path);
    if (render.exitCode != 0) {
      stderr.writeln(render.stderr);
      exitCode = render.exitCode;
      return;
    }
    stdout.writeln('rendered ${card.output}');
  }
}

String? _resolveBenchcat(String configured, Directory root) {
  if (configured.isNotEmpty) {
    return File(configured).existsSync() ? configured : null;
  }
  final local = File('${root.path}/.agents/tools/benchcat/benchcat.exe');
  if (local.existsSync()) return local.path;
  final posix = File('${root.path}/.agents/tools/benchcat/benchcat');
  if (posix.existsSync()) return posix.path;
  return 'benchcat';
}

/// Card config location, relative to `benchmarks/`.
///
/// The headline card keeps its historical path because CI references it; the
/// two comparison cards stay next to the reports they read.
String _configPath(Directory benchDir, String card) {
  switch (card) {
    case 'hero':
      return '${benchDir.path}/benchcat.toml';
    case 'engine':
      return '${benchDir.path}/compare/benchcat-engine.toml';
    case 'db':
      return '${benchDir.path}/compare/benchcat-db.toml';
    default:
      return '${benchDir.path}/cards/$card.toml';
  }
}
