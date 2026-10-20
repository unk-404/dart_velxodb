import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

void main() {
  group('DocSink', () {
    test('packs many documents into one buffer, across growth', () {
      // Start deliberately small so the buffer has to grow while documents are
      // being appended; offsets must stay valid because they are absolute.
      final sink = DocSink(capacity: 64, collectOffsets: true);
      for (var i = 0; i < 50; i++) {
        sink.beginDoc(schemaId: 1, schemaVersion: 3);
        sink.putInt(1, i);
        sink.putString(2, 'document-$i-${'x' * (i % 7)}');
        sink.endDoc();
      }

      expect(sink.docCount, 50);
      expect(sink.offsets, hasLength(50));
      for (var i = 0; i < 50; i++) {
        final view = DocView.parse(sink.buffer, sink.offsets[i]);
        expect(view.getInt(1), i);
        expect(view.getString(2), 'document-$i-${'x' * (i % 7)}');
        expect(view.schemaVersion, 3);
      }
    });

    test('reset reuses the buffer', () {
      final sink = DocSink(capacity: 128, collectOffsets: true)
        ..beginDoc(schemaId: 2)
        ..putInt(1, 42)
        ..endDoc();
      expect(sink.docCount, 1);

      sink.reset();
      expect(sink.docCount, 0);
      expect(sink.length, 0);

      sink
        ..beginDoc(schemaId: 2)
        ..putString(1, 'after reset')
        ..endDoc();
      final view = DocView.parse(sink.buffer, sink.offsets.first);
      expect(view.getString(1), 'after reset');
    });

    test('rejects misuse', () {
      final sink = DocSink();
      expect(() => sink.putInt(1, 1), throwsStateError);
      expect(sink.endDoc, throwsStateError);
      sink.beginDoc();
      expect(sink.beginDoc, throwsStateError);
      sink.putInt(1, 1);
      expect(() => sink.putInt(1, 2), throwsArgumentError);
      sink.endDoc();
    });

    test('handles a document larger than 64 KiB', () {
      final sink = DocSink(capacity: 128, collectOffsets: true);
      final big = 'y' * 70000;
      sink
        ..beginDoc()
        ..putString(1, big)
        ..endDoc();
      final view = DocView.parse(sink.buffer, sink.offsets.first);
      expect(view.flags & vxsFlagLength32, isNot(0));
      expect(view.getString(1), big);
    });
  });
}
