@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish();

String textOf(Bytes bytes) => DocView.parse(bytes.asUint8List()).getString(1)!;

Uint8List readFile(LocalStorageDirectory directory, String name) {
  final file = directory.openSync(name, create: false);
  try {
    return file.readAllSync();
  } finally {
    file.closeSync();
  }
}

void writeFile(LocalStorageDirectory directory, String name, Uint8List bytes) {
  final file = directory.openSync(name);
  try {
    file.writeAllSync(bytes);
    file.flushSync();
  } finally {
    file.closeSync();
  }
}

void main() {
  group('backend compatibility', () {
    test('a segment written locally opens in the object-store engine', () async {
      final root = Directory.systemTemp.createTempSync('velxo_compat_a_');
      try {
        final local = LocalStorageDirectory(root.path);
        final engine = StorageEngine(directory: local)..openSync();
        engine.putSync(k('a'), doc('alpha'));
        engine.flushSync();
        await engine.close();

        final store = SimulatedObjectStore();
        Uint8List? manifestBytes;
        var generation = -1;
        for (final name in local.listSync()) {
          if (name == StorageEngine.walFileName) continue;
          final bytes = readFile(local, name);
          if (name.startsWith('MANIFEST-')) {
            final manifest = Manifest.decode(bytes);
            if (manifest.generation > generation) {
              generation = manifest.generation;
              manifestBytes = bytes;
            }
          } else {
            await store.put('db/$name', bytes);
          }
        }
        // Files use two alternating slots; an object store replaces one object.
        await store.put('db/MANIFEST', manifestBytes!);

        final remote = ObjectStoreEngine(store: store);
        await remote.open();
        expect(textOf((await remote.get(k('a')))!), 'alpha');
        await remote.close(flush: false);
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('a segment written by the object engine opens locally', () async {
      final store = SimulatedObjectStore();
      final remote = ObjectStoreEngine(store: store);
      await remote.open();
      await remote.put(k('b'), doc('beta'));
      await remote.flush();
      await remote.close(flush: false);

      final root = Directory.systemTemp.createTempSync('velxo_compat_b_');
      try {
        final local = LocalStorageDirectory(root.path);
        for (final key in store.keys()) {
          if (key.contains('/wal/') || key == 'db/MANIFEST') continue;
          final bytes = await store.get(key);
          writeFile(local, key.substring('db/'.length), bytes!);
        }
        final manifestBytes = (await store.get('db/MANIFEST'))!;
        final manifest = Manifest.decode(manifestBytes);
        writeFile(local, 'MANIFEST-${manifest.generation % 2}', manifestBytes);

        final engine = StorageEngine(directory: local)..openSync();
        expect(textOf(engine.get(k('b'))!), 'beta');
        await engine.close();
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });
}
