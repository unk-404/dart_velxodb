import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:isar_community/isar.dart' hide Query;
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';
import 'package:velxodb_compare/model.dart';

const int total = 100000;
const int batch = 500;
const int reads = 20000;
const int reopenReads = 1000;
const int warmupReads = 1000;

/// Both sides write one 130-byte value per key.
const int targetValueBytes = 130;

/// Seed of the shared read sequence. The same indices are used by every engine
/// and by every run, so a cache-locality accident cannot favour one side.
const int seed = 0x9E3779B9;

final String body = '在吗？今天下午三点开会，别忘了带材料。01J8Z4K2M3N4P5Q6R7S8T9V0W1';

Uint8List keyOf(int index) =>
    Uint8List.fromList('doc-${index.toString().padLeft(9, '0')}'.codeUnits);

String senderOf(int index) => 'u${index % 100}';

/// A valid VXS document padded to exactly [targetValueBytes] bytes, so the
/// sled comparison writes the same payload size.
Uint8List documentFor(int index) {
  for (var pad = 0; pad < 96; pad++) {
    final builder = DocBuilder(schemaId: 1)
      ..putString(1, 'doc-${index.toString().padLeft(9, '0')}')
      ..putString(2, senderOf(index))
      ..putInt(3, 1750000000000)
      ..putString(4, body);
    if (pad > 0) builder.putBytes(9, List<int>.filled(pad, 0));
    final bytes = builder.finish().asUint8List();
    if (bytes.length == targetValueBytes) return bytes;
    if (bytes.length > targetValueBytes) break;
  }
  throw StateError('cannot pad document to $targetValueBytes bytes');
}

/// xorshift32, byte-for-byte the same as `compare/rust/src/main.rs`.
final class Rng {
  Rng([int initial = seed]) : _state = initial & 0xFFFFFFFF;

  int _state;

  int next() {
    var state = _state;
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    _state = state & 0xFFFFFFFF;
    return state & 0x7FFFFFFF;
  }
}

/// The shared key sequence: reopen reads, warm-up reads, then timed reads.
List<int> readSequence() {
  final rng = Rng();
  return <int>[
    for (var i = 0; i < reopenReads + warmupReads + reads; i++)
      rng.next() % total,
  ];
}

Directory tempDir(String name) {
  final dir = Directory('${Directory.current.path}/.tmp/${name}_$pid');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  return dir;
}

int directoryBytes(Directory root) {
  if (!root.existsSync()) return 0;
  var bytes = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) bytes += entity.lengthSync();
  }
  return bytes;
}

void emit(
  String engine,
  String phase,
  int microseconds, {
  int entries = 0,
  int bytes = 0,
}) {
  print(
    jsonEncode(<String, Object>{
      'engine': engine,
      'phase': phase,
      'ms': microseconds / 1000.0,
      'entries': entries,
      'bytes': bytes,
    }),
  );
}

/// Writes the exact 130-byte payload to `.tmp/fixture130.bin` so the sled side
/// writes the same bytes velxodb writes, not an arbitrary 130-byte blob.
String writeFixture() {
  final file = File('${Directory.current.path}/.tmp/fixture130.bin');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(documentFor(0));
  return file.path;
}

Future<void> runEngine(List<int> sequence) async {
  final root = tempDir('velxo_engine');
  var directory = LocalStorageDirectory(root.path);

  // The first open is on an empty database and is not a measured phase.
  var engine = StorageEngine(directory: directory)..openSync();
  final value = Bytes.fromUint8List(documentFor(0));

  var stopwatch = Stopwatch()..start();
  for (var offset = 0; offset < total; offset += batch) {
    final end = (offset + batch > total) ? total : offset + batch;
    engine.putManySync(<({Uint8List key, Bytes document})>[
      for (var i = offset; i < end; i++) (key: keyOf(i), document: value),
    ]);
  }
  stopwatch.stop();
  emit(
    'velxodb-engine',
    'import',
    stopwatch.elapsedMicroseconds,
    entries: total,
  );

  // Everything below runs from the persisted segment, not the memtable.
  engine.flushSync();
  engine.closeSync();
  emit('velxodb-engine', 'disk', 0, bytes: directoryBytes(root));

  // Reopen: open is measured on its own line, then the reads.
  directory = LocalStorageDirectory(root.path);
  final openWatch = Stopwatch()..start();
  engine = StorageEngine(directory: directory)..openSync();
  openWatch.stop();
  emit('velxodb-engine', 'open', openWatch.elapsedMicroseconds);

  var cursor = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    engine.get(keyOf(sequence[cursor++]));
  }
  stopwatch.stop();
  emit(
    'velxodb-engine',
    'reopen',
    stopwatch.elapsedMicroseconds,
    entries: reopenReads,
  );

  for (var i = 0; i < warmupReads; i++) {
    engine.get(keyOf(sequence[cursor++]));
  }
  var hits = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reads; i++) {
    if (engine.get(keyOf(sequence[cursor++])) != null) hits++;
  }
  stopwatch.stop();
  if (hits != reads) throw StateError('engine hits $hits != $reads');
  emit('velxodb-engine', 'get', stopwatch.elapsedMicroseconds, entries: reads);

  engine.closeSync();
  root.deleteSync(recursive: true);
}

Future<void> runDatabase(List<int> sequence) async {
  final root = tempDir('velxo_db');

  // The first open is on an empty database and is not a measured phase.
  var db = VelxoDatabase.openSync(root.path);

  var collection = db.collection('docs');
  collection.createIndex(2, VxsType.string);

  var stopwatch = Stopwatch()..start();
  for (var offset = 0; offset < total; offset += batch) {
    final end = (offset + batch > total) ? total : offset + batch;
    collection.putManySync(<ScanEntry>[
      for (var i = offset; i < end; i++)
        (key: keyOf(i), value: Bytes.fromUint8List(documentFor(i))),
    ]);
  }
  stopwatch.stop();
  emit('velxodb-db', 'import', stopwatch.elapsedMicroseconds, entries: total);

  db.flushSync();
  await db.close();
  emit('velxodb-db', 'disk', 0, bytes: directoryBytes(root));

  final openWatch = Stopwatch()..start();
  db = VelxoDatabase.openSync(root.path);
  openWatch.stop();
  emit('velxodb-db', 'open', openWatch.elapsedMicroseconds);

  collection = db.collection('docs');
  var cursor = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    collection.get(keyOf(sequence[cursor++]));
  }
  stopwatch.stop();
  emit(
    'velxodb-db',
    'reopen',
    stopwatch.elapsedMicroseconds,
    entries: reopenReads,
  );

  for (var i = 0; i < warmupReads; i++) {
    collection.get(keyOf(sequence[cursor++]));
  }
  var hits = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reads; i++) {
    if (collection.get(keyOf(sequence[cursor++])) != null) hits++;
  }
  stopwatch.stop();
  if (hits != reads) throw StateError('db hits $hits != $reads');
  emit('velxodb-db', 'get', stopwatch.elapsedMicroseconds, entries: reads);

  stopwatch = Stopwatch()..start();
  final equality = collection.findSync(Query(where: Predicate.eq(2, 'u1')));
  stopwatch.stop();
  if (equality.length != 1000) {
    throw StateError('db equality ${equality.length} != 1000');
  }
  emit(
    'velxodb-db',
    'index_eq',
    stopwatch.elapsedMicroseconds,
    entries: equality.length,
  );

  stopwatch = Stopwatch()..start();
  final range = collection.lookupByIndexRangeSync(
    2,
    from: 'u10',
    to: 'u20',
    includeTo: true,
  );
  stopwatch.stop();
  if (range.length != 12000) {
    throw StateError('db range ${range.length} != 12000');
  }
  emit(
    'velxodb-db',
    'index_range',
    stopwatch.elapsedMicroseconds,
    entries: range.length,
  );

  await db.close(flush: true);
  root.deleteSync(recursive: true);
}

Future<void> runIsar(List<int> sequence) async {
  await Isar.initializeIsarCore();
  final root = tempDir('isar_db');

  // The first open is on an empty database and is not a measured phase.
  var isar = await Isar.open(<CollectionSchema<dynamic>>[
    DocSchema,
  ], directory: root.path);

  var stopwatch = Stopwatch()..start();
  for (var offset = 0; offset < total; offset += batch) {
    final end = (offset + batch > total) ? total : offset + batch;
    isar.writeTxnSync(() {
      isar.docs.putAllSync(<Doc>[
        for (var i = offset; i < end; i++)
          Doc()
            ..id = i + 1
            ..sender = senderOf(i)
            ..createdAt = 1750000000000
            ..body = body,
      ]);
    });
  }
  stopwatch.stop();
  emit('isar', 'import', stopwatch.elapsedMicroseconds, entries: total);

  await isar.close();
  // isar is append-only: the live directory keeps its journal, so the fair
  // analogue of velxodb's flushed segment set is the compacted copy.
  emit('isar', 'disk', 0, bytes: directoryBytes(root));
  final compacted = File(
    '${Directory.current.path}/.tmp/isar_compacted_$pid.isar',
  );
  if (compacted.existsSync()) compacted.deleteSync();
  isar = await Isar.open(<CollectionSchema<dynamic>>[
    DocSchema,
  ], directory: root.path);
  await isar.copyToFile(compacted.path);
  await isar.close();
  emit('isar', 'disk.compacted', 0, bytes: compacted.lengthSync());
  compacted.deleteSync();

  final openWatch = Stopwatch()..start();
  isar = await Isar.open(<CollectionSchema<dynamic>>[
    DocSchema,
  ], directory: root.path);
  openWatch.stop();
  emit('isar', 'open', openWatch.elapsedMicroseconds);

  var cursor = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    isar.docs.getSync(sequence[cursor++] + 1);
  }
  stopwatch.stop();
  emit('isar', 'reopen', stopwatch.elapsedMicroseconds, entries: reopenReads);

  for (var i = 0; i < warmupReads; i++) {
    isar.docs.getSync(sequence[cursor++] + 1);
  }
  var hits = 0;
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reads; i++) {
    if (isar.docs.getSync(sequence[cursor++] + 1) != null) hits++;
  }
  stopwatch.stop();
  if (hits != reads) throw StateError('isar hits $hits != $reads');
  emit('isar', 'get', stopwatch.elapsedMicroseconds, entries: reads);

  stopwatch = Stopwatch()..start();
  final equality = isar.docs.filter().senderEqualTo('u1').findAllSync();
  stopwatch.stop();
  if (equality.length != 1000) {
    throw StateError('isar equality ${equality.length} != 1000');
  }
  emit(
    'isar',
    'index_eq',
    stopwatch.elapsedMicroseconds,
    entries: equality.length,
  );

  stopwatch = Stopwatch()..start();
  final range = isar.docs.filter().senderBetween('u10', 'u20').findAllSync();
  stopwatch.stop();
  if (range.length != 12000) {
    throw StateError('isar range ${range.length} != 12000');
  }
  emit(
    'isar',
    'index_range',
    stopwatch.elapsedMicroseconds,
    entries: range.length,
  );

  await isar.close(deleteFromDisk: true);
  root.deleteSync(recursive: true);
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty || args.first == 'all' ? 'all' : args.first;
  // Written before any engine runs so the Rust side can read the same payload.
  final fixture = writeFixture();
  stderr.writeln('fixture: $fixture');
  if (mode == 'fixture') return;
  final sequence = readSequence();
  if (mode == 'engine' || mode == 'all') await runEngine(sequence);
  if (mode == 'db' || mode == 'all') await runDatabase(sequence);
  if (mode == 'isar' || mode == 'all') await runIsar(sequence);
}
