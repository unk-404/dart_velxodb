@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List keyOf(String value) => Uint8List.fromList(value.codeUnits);

Bytes document(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish();

void writeFile(MemoryStorageDirectory directory, String name, Uint8List data) {
  final file = directory.openSync(name);
  try {
    file.writeAllSync(data);
  } finally {
    file.closeSync();
  }
}

Uint8List readFile(MemoryStorageDirectory directory, String name) {
  final file = directory.openSync(name, create: false);
  try {
    return Uint8List.fromList(file.readAllSync());
  } finally {
    file.closeSync();
  }
}

void main() {
  test('a torn first manifest recovers from the WAL', () {
    final directory = MemoryStorageDirectory();
    final key = keyOf('k1');
    final value = document('recovered');
    final wal = Wal(directory.openSync(StorageEngine.walFileName));
    wal.appendBatchSync(<WalOp>[WalOp.put(key, value.asUint8List())]);
    wal.file.closeSync();
    // A crash during the first manifest write leaves an empty slot.
    directory.openSync('MANIFEST-1').closeSync();

    final engine = StorageEngine(directory: directory)..openSync();
    expect(DatabaseView.textOf(engine.get(key)), 'recovered');
    expect(engine.recoveredFromWal, isTrue);
    expect(
      engine.checkSync().issues.any((i) => i.code == 'wal-only-recovery'),
      isTrue,
    );
    // The unusable slot must not block the first flush after recovery.
    final info = engine.flushSync();
    expect(info, isNotNull);
    expect(directory.existsSync(ManifestStore.slotNames[1]), isTrue);
    engine.closeSync();
  });

  test('a corrupt block is refused instead of returned as data', () {
    final key = keyOf('k1');
    final builder = SegmentBuilder();
    builder.add(key, document('hello'));
    final bytes = builder.finish().asUint8List();
    // Segment header 16 B + block header 4 B + document header 6 B + body.
    bytes[27] ^= 0xFF;

    final reader = SegmentReader(bytes);
    expect(() => reader.lookup(key), throwsA(isA<VxsFormatException>()));
  });

  test('a flipped block count cannot steer the table into the index', () {
    final builder = SegmentBuilder();
    builder.add(keyOf('k1'), document('hello'));
    final bytes = builder.finish().asUint8List();
    // blockCount lives in the header, outside the metadata checksum; the
    // structural tiling check must still catch it.
    bytes[8] = bytes[8] ^ 0x01;
    expect(() => SegmentReader(bytes), throwsA(isA<VxsFormatException>()));
  });

  test('two bad manifest slots stay fatal instead of silently empty', () {
    final directory = MemoryStorageDirectory();
    final wal = Wal(directory.openSync(StorageEngine.walFileName));
    wal.appendBatchSync(<WalOp>[
      WalOp.put(keyOf('k1'), document('value').asUint8List()),
    ]);
    wal.file.closeSync();
    directory.openSync('MANIFEST-0').closeSync();
    directory.openSync('MANIFEST-1').closeSync();

    expect(
      () => StorageEngine(directory: directory).openSync(),
      throwsA(isA<VelxoCorruptException>()),
    );
  });

  test('backup skips the format temp file and streams large files', () {
    final source = MemoryStorageDirectory();
    final payload = Uint8List(3 << 20);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i & 0xFF;
    }
    writeFile(source, 'SEG-000001.seg', payload);
    writeFile(source, 'FORMAT.tmp', Uint8List.fromList(<int>[1, 2, 3]));
    writeFile(source, 'FORMAT', Uint8List(12));

    final target = MemoryStorageDirectory();
    final report = copyDatabase(source, target);
    expect(report.files, 2);
    expect(report.bytes, payload.length + 12);
    expect(target.existsSync('FORMAT.tmp'), isFalse);
    expect(readFile(target, 'SEG-000001.seg'), payload);
  });

  test('backup refuses a database with an unfinished upgrade journal', () {
    final source = MemoryStorageDirectory();
    writeFile(source, 'data', Uint8List.fromList(<int>[1]));
    writeFile(source, 'UPGRADE-JOURNAL', Uint8List(8));
    expect(
      () => copyDatabase(source, MemoryStorageDirectory()),
      throwsA(isA<VelxoUpgradeRequiredException>()),
    );
  });
}

/// Reads a field from an engine value without importing private helpers.
abstract final class DatabaseView {
  static String? textOf(Bytes? value) =>
      value == null ? null : DocView.parse(value.asUint8List()).getString(1);
}
