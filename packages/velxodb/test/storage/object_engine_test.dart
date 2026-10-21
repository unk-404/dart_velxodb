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

ObjectStoreEngine openEngine(SimulatedObjectStore store) =>
    ObjectStoreEngine(store: store, segmentCacheSize: 2);

void main() {
  group('ObjectStoreEngine', () {
    test('writes, reads and deletes before a flush', () async {
      final store = SimulatedObjectStore();
      final engine = openEngine(store);
      await engine.open();
      await engine.put(k('a'), doc('alpha'));
      await engine.put(k('b'), doc('beta'));
      expect(textOf((await engine.get(k('a')))!), 'alpha');

      await engine.delete(k('a'));
      expect(await engine.get(k('a')), isNull);
      expect(textOf((await engine.get(k('b')))!), 'beta');
      expect(store.stats.puts, 3);
    });

    test('flush writes one segment and one manifest, then drops WAL objects',
        () async {
      final store = SimulatedObjectStore();
      final engine = openEngine(store);
      await engine.open();
      await engine.put(k('a'), doc('alpha'));
      await engine.put(k('b'), doc('beta'));
      final info = await engine.flush();
      expect(info, isNotNull);
      expect(await engine.get(k('a')), isNotNull);

      final keys = store.keys();
      expect(keys, contains('db/MANIFEST'));
      expect(keys, contains('db/SEG-000001.seg'));
      expect(keys.where((key) => key.startsWith('db/wal/')), isEmpty);
      expect(engine.segments, hasLength(1));
    });

    test('reopens from the manifest and fetches segments lazily', () async {
      final store = SimulatedObjectStore();
      final first = openEngine(store);
      await first.open();
      await first.put(k('a'), doc('alpha'));
      await first.flush();
      await first.close();

      final before = store.stats;
      final second = openEngine(store);
      await second.open();
      // Open reads the manifest and lists the WAL prefix, nothing else.
      final opened = store.stats - before;
      expect(opened.gets, 1);
      expect(opened.lists, 1);

      expect(textOf((await second.get(k('a')))!), 'alpha');
      // The first read of the segment fetched it.
      expect((store.stats - before).gets, 2);
    });

    test('replays WAL objects that were never flushed', () async {
      final store = SimulatedObjectStore();
      final first = openEngine(store);
      await first.open();
      await first.put(k('pending'), doc('wal'));
      await first.close(flush: false);

      final second = openEngine(store);
      await second.open();
      expect(textOf((await second.get(k('pending')))!), 'wal');
    });

    test('batches deletes into one WAL request', () async {
      final store = SimulatedObjectStore();
      final engine = openEngine(store);
      await engine.open();
      await engine.putMany(<({Uint8List key, Bytes document})>[
        for (var i = 0; i < 10; i++) (key: k('k$i'), document: doc('v$i')),
      ]);
      final before = store.stats;
      await engine.deleteMany(<Uint8List>[
        for (var i = 0; i < 10; i++) k('k$i'),
      ]);
      expect((store.stats - before).puts, 1);
      expect(await engine.get(k('k3')), isNull);
    });

    test('compaction merges segments and deletes old objects', () async {
      final store = SimulatedObjectStore();
      final engine = openEngine(store);
      await engine.open();
      await engine.put(k('a'), doc('one'));
      await engine.flush();
      await engine.put(k('a'), doc('two'));
      await engine.put(k('b'), doc('beta'));
      await engine.flush();
      expect(engine.segments, hasLength(2));

      expect(await engine.compact(), isTrue);
      expect(engine.segments, hasLength(1));
      expect(textOf((await engine.get(k('a')))!), 'two');
      expect(textOf((await engine.get(k('b')))!), 'beta');

      final segmentKeys = store
          .keys()
          .where((key) => key.contains('SEG-'))
          .toList();
      expect(segmentKeys, hasLength(1));
    });

    test('tracks request and byte counters', () async {
      final store = SimulatedObjectStore();
      final engine = openEngine(store);
      await engine.open();
      await engine.put(k('a'), doc('alpha'));
      await engine.flush();

      // A read is what produces response bytes; writes only send.
      await engine.get(k('a'));
      final stats = store.stats;
      expect(stats.requests, greaterThan(0));
      expect(stats.requestBytes, greaterThan(0));
      expect(stats.responseBytes, greaterThan(0));
      expect(stats.responses, stats.requests);
    });
  });
}
