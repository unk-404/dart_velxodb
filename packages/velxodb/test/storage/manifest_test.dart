import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Manifest sample({int generation = 3}) => Manifest(
  generation: generation,
  segments: const <SegmentInfo>[
    SegmentInfo(name: 'SEG-000001.seg', entryCount: 10, byteLength: 2048),
    SegmentInfo(name: 'SEG-000002.seg', entryCount: 20, byteLength: 4096),
  ],
);

void main() {
  group('Manifest', () {
    test('round trips', () {
      final bytes = sample().encode();
      final decoded = Manifest.decode(bytes);
      expect(decoded.generation, 3);
      expect(decoded.segments, hasLength(2));
      expect(decoded.segments.first.name, 'SEG-000001.seg');
      expect(decoded.segments.last.entryCount, 20);
      expect(decoded.segments.last.byteLength, 4096);
    });

    test('rejects truncation and corruption', () {
      final bytes = sample().encode();
      expect(
        () =>
            Manifest.decode(Uint8List.sublistView(bytes, 0, bytes.length - 3)),
        throwsA(isA<VxsFormatException>()),
      );
      final corrupted = Uint8List.fromList(bytes);
      corrupted[14] ^= 0xFF;
      expect(
        () => Manifest.decode(corrupted),
        throwsA(isA<VxsFormatException>()),
      );
    });
  });

  group('ManifestStore', () {
    test('alternates slots and increases the generation', () {
      final directory = MemoryStorageDirectory();
      final store = ManifestStore(directory);

      final first = store.saveSync(<SegmentInfo>[]);
      expect(first.generation, 1);
      expect(directory.existsSync('MANIFEST-1'), isTrue);

      final second = store.saveSync(const <SegmentInfo>[
        SegmentInfo(name: 'SEG-000001.seg', entryCount: 1, byteLength: 10),
      ]);
      expect(second.generation, 2);
      expect(directory.existsSync('MANIFEST-0'), isTrue);

      final loaded = store.loadSync()!;
      expect(loaded.generation, 2);
      expect(loaded.segments, hasLength(1));
    });

    test('falls back to the valid slot when the newest is torn', () {
      final directory = MemoryStorageDirectory();
      final store = ManifestStore(directory);
      store.saveSync(<SegmentInfo>[]);
      store.saveSync(const <SegmentInfo>[
        SegmentInfo(name: 'SEG-000001.seg', entryCount: 1, byteLength: 10),
      ]);

      // Generation 2 is in slot 0.
      final slot = directory.openSync('MANIFEST-0') as MemoryStorageFile;
      final bytes = Uint8List.fromList(slot.bytes);
      bytes[bytes.length - 2] ^= 0xFF;
      slot.writeAllSync(bytes);

      final loaded = store.loadSync()!;
      expect(loaded.generation, 1);
      expect(loaded.segments, isEmpty);
    });

    test('returns null for an empty directory', () {
      expect(ManifestStore(MemoryStorageDirectory()).loadSync(), isNull);
    });
  });
}
