@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

import 'crash_support.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)..putString(1, text)).finish();

String? textOf(Bytes? bytes) =>
    bytes == null ? null : DocView.parse(bytes.asUint8List()).getString(1);

void main() {
  group('crash matrix', () {
    test('every byte of a torn transaction frame is all-or-nothing', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('a'), doc('alpha'));
      engine.putSync(k('b'), doc('beta'));

      final before = snapshot(directory);
      final start = fileLength(directory, StorageEngine.walFileName);

      engine.transactionSync(() {
        engine.putSync(k('c'), doc('gamma'));
        engine.putSync(k('d'), doc('delta'));
      });
      final after = snapshot(directory);
      final end = after[StorageEngine.walFileName]!.length;
      engine.closeSync();

      expect(end, greaterThan(start));
      for (var cut = start + 1; cut <= end; cut++) {
        final files = Map<String, Uint8List>.from(before);
        files[StorageEngine.walFileName] = Uint8List.sublistView(
          after[StorageEngine.walFileName]!,
          0,
          cut,
        );
        final reopenedDirectory = MemoryStorageDirectory();
        restore(reopenedDirectory, files);
        final reopened = StorageEngine(directory: reopenedDirectory)..openSync();
        expect(textOf(reopened.get(k('a'))), 'alpha', reason: 'cut=$cut');
        expect(textOf(reopened.get(k('b'))), 'beta', reason: 'cut=$cut');

        final hasC = reopened.get(k('c'));
        final hasD = reopened.get(k('d'));
        if (cut == end) {
          expect(textOf(hasC), 'gamma', reason: 'full frame');
          expect(textOf(hasD), 'delta', reason: 'full frame');
        } else {
          expect(hasC, isNull, reason: 'torn frame at $cut of $end');
          expect(hasD, isNull, reason: 'torn frame at $cut of $end');
        }
        expect(reopened.checkSync().ok, isTrue, reason: 'cut=$cut');
        reopened.closeSync();
      }
    });

    test('a segment written before the manifest commit is ignored', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('v'), doc('v1'));
      engine.flushSync();
      engine.closeSync();

      final ghost = SegmentBuilder()..add(k('z'), doc('ghost'));
      writeFile(
        directory,
        'SEG-000099.seg',
        ghost.finish().asUint8List(),
      );

      final reopened = StorageEngine(directory: directory)..openSync();
      expect(textOf(reopened.get(k('v'))), 'v1');
      expect(reopened.get(k('z')), isNull);

      final report = reopened.checkSync();
      expect(report.ok, isTrue, reason: report.describe());
      expect(
        report.issues.any((issue) => issue.code == 'orphan-segment'),
        isTrue,
      );
      reopened.closeSync();
    });

    test('replaying the pre-truncate WAL after a manifest commit is idempotent',
        () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('v'), doc('v1'));
      final walBeforeFlush = readFile(directory, StorageEngine.walFileName);

      engine.flushSync();
      engine.closeSync();

      // The crash window: manifest committed, segment durable, WAL not yet
      // truncated.
      writeFile(directory, StorageEngine.walFileName, walBeforeFlush);

      var reopened = StorageEngine(directory: directory)..openSync();
      expect(textOf(reopened.get(k('v'))), 'v1');
      expect(reopened.checkSync().ok, isTrue);

      reopened.flushSync();
      reopened.closeSync();

      reopened = StorageEngine(directory: directory)..openSync();
      expect(textOf(reopened.get(k('v'))), 'v1');
      expect(reopened.checkSync().ok, isTrue);
      reopened.closeSync();
    });

    test('a torn newest manifest falls back to the previous generation', () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('v'), doc('v1'));
      engine.flushSync(); // generation 2 -> MANIFEST-0
      engine.putSync(k('v'), doc('v2'));
      engine.flushSync(); // generation 2 -> MANIFEST-0
      engine.closeSync();

      // Torn newest slot; the previous generation must take over.
      final newest = ManifestStore(directory).loadSync()!.generation;
      writeFile(
        directory,
        'MANIFEST-${newest % 2}',
        Uint8List.fromList(<int>[1, 2, 3]),
      );

      final reopened = StorageEngine(directory: directory)..openSync();
      expect(reopened.generation, newest - 1);
      expect(textOf(reopened.get(k('v'))), 'v1');

      final report = reopened.checkSync();
      expect(report.ok, isTrue, reason: report.describe());
      expect(
        report.issues.any((issue) => issue.code == 'orphan-segment'),
        isTrue,
      );
      reopened.closeSync();
    });

    test('a truncated segment referenced by the manifest is typed corruption',
        () {
      final directory = MemoryStorageDirectory();
      final engine = StorageEngine(directory: directory)..openSync();
      engine.putSync(k('v'), doc('v1'));
      engine.flushSync();
      engine.closeSync();

      final segment = directory
          .listSync()
          .firstWhere((name) => name.startsWith(StorageEngine.segmentPrefix));
      final bytes = readFile(directory, segment);
      writeFile(directory, segment, bytes.sublist(0, bytes.length - 8));

      expect(
        () => StorageEngine(directory: directory)..openSync(),
        throwsA(isA<VelxoCorruptException>()),
      );
    });
  });
}
