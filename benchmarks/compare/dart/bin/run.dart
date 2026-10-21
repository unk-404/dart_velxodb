import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:isar_community/isar.dart' hide Query;
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';
import 'package:velxodb_compare/model.dart';

const int total = 100000;
const int batch = 500;
const int reads = 20000;
const int reopenReads = 1000;

final String body =
    '在吗？今天下午三点开会，别忘了带材料。01J8Z4K2M3N4P5Q6R7S8T9V0W1';

Uint8List keyOf(int index) =>
    Uint8List.fromList('doc-${index.toString().padLeft(9, '0')}'.codeUnits);

String senderOf(int index) => 'u${index % 100}';

Uint8List documentFor(int index) => (DocBuilder(schemaId: 1)
      ..putString(1, 'doc-${index.toString().padLeft(9, '0')}')
      ..putString(2, senderOf(index))
      ..putInt(3, 1750000000000)
      ..putString(4, body))
    .finish()
    .asUint8List();

var seed = 0x9E3779B9;

int nextSeed() {
  seed ^= (seed << 13) & 0xFFFFFFFF;
  seed ^= seed >> 17;
  seed ^= (seed << 5) & 0xFFFFFFFF;
  return seed & 0x7FFFFFFF;
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

Future<void> runEngine() async {
  final root = tempDir('velxo_engine');
  var directory = LocalStorageDirectory(root.path);
  var engine = StorageEngine(directory: directory)..openSync();
  // The engine stores VXS documents, not opaque blobs (sled does). Use one
  // valid 117 B document for every key so both sides write one value per key.
  final value = Bytes.fromUint8List(documentFor(0));

  var stopwatch = Stopwatch()..start();
  for (var offset = 0; offset < total; offset += batch) {
    final end = (offset + batch > total) ? total : offset + batch;
    engine.putManySync(<({Uint8List key, Bytes document})>[
      for (var i = offset; i < end; i++) (key: keyOf(i), document: value),
    ]);
  }
  emit(
    'velxodb-engine',
    'import',
    stopwatch.elapsedMicroseconds,
    entries: total,
  );

  stopwatch = Stopwatch()..start();
  var hits = 0;
  for (var i = 0; i < reads; i++) {
    if (engine.get(keyOf(nextSeed() % total)) != null) hits++;
  }
  emit('velxodb-engine', 'get', stopwatch.elapsedMicroseconds, entries: reads);
  stdout.writeln('  engine hits=$hits');

  engine.flushSync();
  engine.closeSync();
  emit('velxodb-engine', 'disk', 0, bytes: directoryBytes(root));

  directory = LocalStorageDirectory(root.path);
  engine = StorageEngine(directory: directory)..openSync();
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    engine.get(keyOf(nextSeed() % total));
  }
  emit(
    'velxodb-engine',
    'reopen',
    stopwatch.elapsedMicroseconds,
    entries: reopenReads,
  );
  engine.closeSync();
  root.deleteSync(recursive: true);
}

Future<void> runDatabase() async {
  final root = tempDir('velxo_db');
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
  emit('velxodb-db', 'import', stopwatch.elapsedMicroseconds, entries: total);

  stopwatch = Stopwatch()..start();
  var hits = 0;
  for (var i = 0; i < reads; i++) {
    if (collection.get(keyOf(nextSeed() % total)) != null) hits++;
  }
  emit('velxodb-db', 'get', stopwatch.elapsedMicroseconds, entries: reads);
  stdout.writeln('  db hits=$hits');

  stopwatch = Stopwatch()..start();
  final equality = collection.findSync(Query(where: Predicate.eq(2, 'u1')));
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
  emit(
    'velxodb-db',
    'index_range',
    stopwatch.elapsedMicroseconds,
    entries: range.length,
  );

  db.flushSync();
  await db.close();
  emit('velxodb-db', 'disk', 0, bytes: directoryBytes(root));

  db = VelxoDatabase.openSync(root.path);
  collection = db.collection('docs');
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    collection.get(keyOf(nextSeed() % total));
  }
  emit(
    'velxodb-db',
    'reopen',
    stopwatch.elapsedMicroseconds,
    entries: reopenReads,
  );
  await db.close(flush: true);
  root.deleteSync(recursive: true);
}

Future<void> runIsar() async {
  await Isar.initializeIsarCore();
  final root = tempDir('isar_db');
  var isar = await Isar.open(<CollectionSchema<dynamic>>[DocSchema],
      directory: root.path);

  var stopwatch = Stopwatch()..start();
  for (var offset = 0; offset < total; offset += batch) {
    final end = (offset + batch > total) ? total : offset + batch;
    await isar.writeTxn(() async {
      for (var i = offset; i < end; i++) {
        await isar.docs.put(
          Doc()
            ..id = i + 1
            ..sender = senderOf(i)
            ..createdAt = 1750000000000
            ..body = body,
        );
      }
    });
  }
  emit('isar', 'import', stopwatch.elapsedMicroseconds, entries: total);

  stopwatch = Stopwatch()..start();
  var hits = 0;
  for (var i = 0; i < reads; i++) {
    if (await isar.docs.get((nextSeed() % total) + 1) != null) hits++;
  }
  emit('isar', 'get', stopwatch.elapsedMicroseconds, entries: reads);
  stdout.writeln('  isar hits=$hits');

  stopwatch = Stopwatch()..start();
  final equality = await isar.docs.filter().senderEqualTo('u1').findAll();
  emit(
    'isar',
    'index_eq',
    stopwatch.elapsedMicroseconds,
    entries: equality.length,
  );

  stopwatch = Stopwatch()..start();
  final range = await isar.docs
      .filter()
      .senderBetween('u10', 'u20')
      .findAll();
  emit(
    'isar',
    'index_range',
    stopwatch.elapsedMicroseconds,
    entries: range.length,
  );

  await isar.close();
  emit('isar', 'disk', 0, bytes: directoryBytes(root));

  isar = await Isar.open(<CollectionSchema<dynamic>>[DocSchema],
      directory: root.path);
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < reopenReads; i++) {
    await isar.docs.get((nextSeed() % total) + 1);
  }
  emit('isar', 'reopen', stopwatch.elapsedMicroseconds, entries: reopenReads);
  await isar.close(deleteFromDisk: true);
  root.deleteSync(recursive: true);
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'all' : args.first;
  if (mode == 'engine' || mode == 'all') await runEngine();
  if (mode == 'db' || mode == 'all') await runDatabase();
  if (mode == 'isar' || mode == 'all') await runIsar();
}
