import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/storage.dart';

Uint8List k(String value) => Uint8List.fromList(utf8.encode(value));

Bytes message(String text) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, text)
          ..putInt(2, text.length))
        .finish();

SegmentBuilder buildSegment(int count, {int blockTargetSize = 512}) {
  final builder = SegmentBuilder(blockTargetSize: blockTargetSize);
  for (var i = 0; i < count; i++) {
    builder.add(k('key-${i.toString().padLeft(5, '0')}'), message('value-$i'));
  }
  return builder;
}

void main() {
  group('BloomFilter', () {
    test('never reports a false negative', () {
      final keys = <Uint8List>[for (var i = 0; i < 200; i++) k('key-$i')];
      final bloom = BloomFilter.build(keys);
      for (final key in keys) {
        expect(bloom.mightContain(key), isTrue);
      }
      var hits = 0;
      for (var i = 0; i < 1000; i++) {
        if (bloom.mightContain(k('missing-$i'))) hits++;
      }
      // 10 bits/key with 7 probes: expect ~1% false positives.
      expect(hits, lessThan(100));
    });

    test('round trips through bytes', () {
      final bloom = BloomFilter.build(<Uint8List>[k('a'), k('b')]);
      final bytes = bloom.toBytes();
      final parsed = BloomFilter.parse(bytes);
      expect(parsed.filter.bitCount, bloom.bitCount);
      expect(parsed.filter.hashCount, bloom.hashCount);
      expect(parsed.filter.mightContain(k('a')), isTrue);
      expect(parsed.filter.mightContain(k('b')), isTrue);
      expect(parsed.next, bytes.length);
    });
  });

  group('Segment', () {
    test('finds every document and rejects absent keys', () {
      final bytes = buildSegment(100).finish();
      final reader = SegmentReader(bytes.asUint8List());
      expect(reader.docCount, 100);
      for (var i = 0; i < 100; i++) {
        final key = 'key-${i.toString().padLeft(5, '0')}';
        final doc = reader.find(k(key));
        expect(doc, isNotNull, reason: key);
        expect(doc!.getString(1), 'value-$i');
      }
      expect(reader.find(k('key-99999')), isNull);
      expect(reader.find(k('nope')), isNull);
    });

    test('iterates every document in block order', () {
      final bytes = buildSegment(50).finish();
      final reader = SegmentReader(bytes.asUint8List());
      final texts = <String>[];
      reader.forEach((doc) => texts.add(doc.getString(1)!));
      expect(texts, hasLength(50));
      expect(texts.first, 'value-0');
      expect(texts.last, 'value-49');
    });

    test('handles an empty segment', () {
      final bytes = SegmentBuilder().finish();
      final reader = SegmentReader(bytes.asUint8List());
      expect(reader.docCount, 0);
      expect(reader.find(k('anything')), isNull);
      var count = 0;
      reader.forEach((_) => count++);
      expect(count, 0);
    });

    test('rejects duplicate keys', () {
      final builder = SegmentBuilder();
      builder.add(k('same'), message('a'));
      builder.add(k('same'), message('b'));
      expect(builder.finish, throwsArgumentError);
    });

    test('sorts keys, including non-ASCII', () {
      final builder = SegmentBuilder();
      for (final key in <String>['b', 'a', '中文', 'aa', 'z']) {
        builder.add(k(key), message(key));
      }
      final bytes = builder.finish();
      final reader = SegmentReader(bytes.asUint8List());
      for (final key in <String>['a', 'aa', 'b', 'z', '中文']) {
        expect(reader.find(k(key))!.getString(1), key);
      }
    });

    test('spans multiple blocks and keeps point lookups working', () {
      final bytes = buildSegment(300, blockTargetSize: 256).finish();
      final reader = SegmentReader(bytes.asUint8List());
      expect(reader.blockCount, greaterThan(1));
      for (final i in <int>[0, 1, 150, 298, 299]) {
        final key = 'key-${i.toString().padLeft(5, '0')}';
        expect(reader.find(k(key))!.getString(1), 'value-$i');
      }
    });

    test('detects metadata corruption', () {
      final bytes = Uint8List.fromList(buildSegment(20).finish().asUint8List());
      // Flip a byte inside the index region.
      bytes[bytes.length - segmentFooterSize - 20] ^= 0xFF;
      expect(() => SegmentReader(bytes), throwsA(isA<VxsFormatException>()));
      // Opting out of verification still parses the header/footer.
      expect(SegmentReader(bytes, verify: false).docCount, 20);
    });

    test('rejects truncated input', () {
      final bytes = buildSegment(10).finish().asUint8List();
      expect(
        () => SegmentReader(bytes, length: bytes.length - 16),
        throwsA(isA<VxsFormatException>()),
      );
      expect(
        () => SegmentReader(Uint8List.fromList(bytes.sublist(0, 24))),
        throwsA(isA<VxsFormatException>()),
      );
    });
  });
}
