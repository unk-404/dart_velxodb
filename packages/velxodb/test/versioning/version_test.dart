@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

void stamp(Directory root, int major, int minor) {
  final bytes = Uint8List(12);
  bytes.setRange(0, 4, formatMagic);
  VxsLe.w16(bytes, 4, major);
  VxsLe.w16(bytes, 6, minor);
  VxsLe.w32(bytes, 8, VxsCrc32c.compute(bytes, 0, 8));
  File('${root.path}${Platform.pathSeparator}$formatFileName')
      .writeAsBytesSync(bytes);
}

void main() {
  late Directory root;
  late String path;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_ver_');
    path = '${root.path}${Platform.pathSeparator}db';
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a writable open creates the format stamp', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();

    final directory = LocalStorageDirectory(path);
    try {
      final file = directory.openSync(formatFileName);
      try {
        final bytes = file.readAllSync();
        expect(bytes, hasLength(12));
        expect(bytes[0], formatMagic[0]);
        expect(bytes[4], formatMajor);
        expect(bytes[5], 0);
        expect(bytes[6], formatMinor);
      } finally {
        file.closeSync();
      }
    } finally {
      directory.closeSync();
    }
  });

  test('a newer major is refused', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();
    stamp(Directory(path), formatMajor + 1, 0);

    await expectLater(
      Future<void>.sync(() => VelxoDatabase.openSync(path)),
      throwsA(isA<VelxoIncompatibleException>()),
    );
  });

  test('an older major requires an explicit upgrade', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();
    stamp(Directory(path), formatMajor - 1, 0);

    await expectLater(
      () => VelxoDatabase.openSync(path),
      throwsA(isA<VelxoUpgradeRequiredException>()),
    );
    await expectLater(
      () => VelxoDatabase.upgradeSync(path),
      throwsA(isA<VelxoUpgradeRequiredException>()),
    );
  });

  test('a newer minor opens without action', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();
    stamp(Directory(path), formatMajor, formatMinor + 7);

    final reopened = VelxoDatabase.openSync(path);
    await reopened.close();
  });

  test('a missing stamp is treated as 1.0', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();
    File('$path${Platform.pathSeparator}$formatFileName').deleteSync();

    final reader = VelxoDatabase.openSync(path, readOnly: true);
    await reader.close();

    final writer = VelxoDatabase.openSync(path);
    await writer.close();
    expect(
      File('$path${Platform.pathSeparator}$formatFileName').existsSync(),
      isTrue,
    );
  });

  test('a corrupt stamp is typed corruption', () async {
    final db = VelxoDatabase.openSync(path);
    await db.close();
    final file = File('$path${Platform.pathSeparator}$formatFileName');
    final bytes = file.readAsBytesSync();
    bytes[8] ^= 0xFF;
    file.writeAsBytesSync(bytes);

    await expectLater(
      () => VelxoDatabase.openSync(path),
      throwsA(isA<VelxoCorruptException>()),
    );
  });
}
