@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Uint8List doc(String text) =>
    (DocBuilder(schemaId: 1)..putString(1, text)).finish().asUint8List();

String? textOf(Uint8List? bytes) =>
    bytes == null ? null : DocView.parse(bytes).getString(1);

void main() {
  group('worker', () {
    late Directory root;
    late VelxoWorker worker;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('velxo_worker_');
      worker = await VelxoWorker.open(root.path);
    });

    tearDown(() async {
      await worker.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test(
      'put, get, page, delete and check cross the isolate boundary',
      () async {
        for (var i = 0; i < 10; i++) {
          await worker.put('items', k('k$i'), doc('value-$i'));
        }
        expect(textOf(await worker.get('items', k('k3'))), 'value-3');

        final first = await worker.page('items', limit: 4);
        expect(first.entries, hasLength(4));
        expect(first.next, isNotNull);

        final second = await worker.page('items', after: first.next, limit: 10);
        expect(second.entries, hasLength(6));

        await worker.delete('items', k('k0'));
        expect(await worker.get('items', k('k0')), isNull);

        final report = await worker.check();
        expect(report.ok, isTrue);
        expect(report.stats['collections'], greaterThan(0));
      },
    );

    test('concurrent requests are serialized by the worker', () async {
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 200; i++) worker.put('bulk', k('k$i'), doc('v$i')),
      ]);
      final page = await worker.page('bulk', limit: 500);
      expect(page.entries, hasLength(200));
      expect(textOf(await worker.get('bulk', k('k199'))), 'v199');
    });

    test('documents larger than 64 KiB cross the boundary', () async {
      final body = List<String>.filled(70000, 'x').join();
      await worker.put('large', k('big'), doc(body));
      final loaded = await worker.get('large', k('big'));
      expect(textOf(loaded), body);
    });

    test('the worker owns the path and closes cleanly', () async {
      await expectLater(
        VelxoWorker.open(root.path),
        throwsA(isA<VelxoLockedException>()),
      );

      await worker.put('items', k('k'), doc('value'));
      await worker.close(flush: true);

      final reopened = await VelxoWorker.open(root.path);
      expect(textOf(await reopened.get('items', k('k'))), 'value');
      await reopened.close();

      await expectLater(
        worker.get('items', k('k')),
        throwsA(isA<VelxoClosedException>()),
      );
      worker = reopened; // tearDown closes it again harmlessly
    });

    test('a failed open reports a typed error to the client', () async {
      final corrupt = await Directory.systemTemp.createTemp('velxo_bad_');
      File('${corrupt.path}${Platform.pathSeparator}CATALOG')
          .writeAsBytesSync(<int>[0x43, 1, 2, 3]);
      await expectLater(
        VelxoWorker.open(corrupt.path),
        throwsA(isA<VelxoCorruptException>()),
      );
      corrupt.deleteSync(recursive: true);
    });
  });
}
