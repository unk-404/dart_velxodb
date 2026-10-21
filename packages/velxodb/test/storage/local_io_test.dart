@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)
      ..putString(1, text)
      ..putInt(2, text.length))
    .finish();

String textOf(Bytes bytes) =>
    DocView.parse(bytes.asUint8List()).getString(1)!;

void main() {
  late Directory root;
  late LocalStorageDirectory directory;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_local_');
    directory = LocalStorageDirectory(root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('engine writes, flushes and reopens from real files', () async {
    final engine = StorageEngine(directory: directory);
    engine.openSync();
    engine.putSync(k('a'), doc('alpha'));
    engine.putSync(k('b'), doc('beta'));
    engine.deleteSync(k('b'));
    final info = engine.flushSync();
    expect(info, isNotNull);
    await engine.close();

    expect(directory.listSync(), contains(info!.name));

    final reopened = StorageEngine(directory: directory);
    reopened.openSync();
    expect(textOf(reopened.get(k('a'))!), 'alpha');
    expect(reopened.get(k('b')), isNull);
    await reopened.close();
  });

  test('survives a process restart with unflushed WAL data', () async {
    final engine = StorageEngine(directory: directory);
    engine.openSync();
    engine.putSync(k('flushed'), doc('one'));
    engine.flushSync();
    engine.putSync(k('pending'), doc('two'));
    await engine.close();

    final reopened = StorageEngine(directory: directory);
    reopened.openSync();
    expect(textOf(reopened.get(k('flushed'))!), 'one');
    expect(textOf(reopened.get(k('pending'))!), 'two');
    await reopened.close();
  });

  test('compaction rewrites real segment files', () async {
    final engine = StorageEngine(directory: directory);
    engine.openSync();
    engine.putSync(k('k'), doc('v1'));
    engine.flushSync();
    engine.putSync(k('k'), doc('v2'));
    engine.flushSync();
    expect(engine.compactSync(), isTrue);
    expect(textOf(engine.get(k('k'))!), 'v2');
    await engine.close();

    final files = directory.listSync();
    expect(files.where((f) => f.startsWith('SEG-')), hasLength(1));
  });

  test('autoSync keeps the WAL on disk after every write', () async {
    final engine = StorageEngine(directory: directory, autoSync: true);
    engine.openSync();

    engine.putSync(k('a'), doc('x'));
    final first = directory.openSync(StorageEngine.walFileName);
    final firstLength = first.lengthSync;
    first.closeSync();
    expect(firstLength, greaterThan(0));

    engine.putSync(k('b'), doc('y'));
    final second = directory.openSync(StorageEngine.walFileName);
    expect(second.lengthSync, greaterThan(firstLength));
    second.closeSync();

    await engine.close();
  });

  test('rejects a second concurrent open of the same directory', () {
    directory.closeSync(); // release the lock held by setUp
    final path = '${root.path}${Platform.pathSeparator}locked';
    final first = LocalStorageDirectory(path);
    expect(() => LocalStorageDirectory(path), throwsStateError);
    first.closeSync();

    final second = LocalStorageDirectory(path);
    second.closeSync();
  });
}
