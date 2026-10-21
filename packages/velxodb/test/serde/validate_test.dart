import 'dart:convert';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

final VxsSchema schema = VxsSchema(
  id: 1,
  version: 1,
  fields: const <VxsField>[
    VxsField(1, 'conversationId', VxsType.string),
    VxsField(2, 'senderId', VxsType.int64),
    VxsField(3, 'createdAt', VxsType.int64),
    VxsField(4, 'text', VxsType.string),
    VxsField(5, 'tags', VxsType.stringList),
    VxsField(6, 'scores', VxsType.intList),
    VxsField(7, 'meta', VxsType.doc),
  ],
);

DocBuilder sample() => DocBuilder(schemaId: 1)
  ..putString(1, 'conv-42')
  ..putInt(2, 7)
  ..putInt(3, 1750000000000)
  ..putString(4, '在吗？今天下午三点开会')
  ..putStringList(5, <String>['a', '中文'])
  ..putIntList(6, <int>[1, -2, 300]);

void main() {
  group('validate', () {
    test('accepts a well-formed document', () {
      final view = DocView.parse(sample().finish().asUint8List());
      expect(view.validate(schema), isEmpty);
    });

    test('accepts unknown fields by default and rejects them on request', () {
      final bytes = (sample()..putString(99, 'future')).finish();
      final view = DocView.parse(bytes.asUint8List());
      expect(view.validate(schema), isEmpty);
      final issues = view.validate(schema, allowUnknown: false);
      expect(issues, hasLength(1));
      expect(issues.single.fieldId, 99);
      expect(issues.single.message, contains('unknown field'));
    });

    test('reports a wire type mismatch', () {
      // Field 1 is declared as a string but written as an int.
      final bytes = (DocBuilder()..putInt(1, 5)).finish();
      final view = DocView.parse(bytes.asUint8List());
      final issues = view.validate(schema);
      expect(issues.single.fieldId, 1);
      expect(issues.single.message, contains('wire type'));
      expect(
        () => view.validateOrThrow(schema),
        throwsA(isA<VxsFormatException>()),
      );
    });

    test('validates nested documents', () {
      final inner =
          (DocBuilder()
                ..putString(1, 'inner')
                ..putInt(2, 1))
              .finish();
      final outer = (DocBuilder()..putDoc(7, inner)).finish();
      expect(DocView.parse(outer.asUint8List()).validate(schema), isEmpty);

      // A nested doc with a wrong wire type is reported against field 7.
      final badInner = (DocBuilder()..putInt(1, 1)).finish();
      final badOuter = (DocBuilder()..putDoc(7, badInner)).finish();
      final issues = DocView.parse(badOuter.asUint8List()).validate(schema);
      expect(issues, isNotEmpty);
      expect(issues.first.fieldId, 1);
    });

    test('reports list framing problems', () {
      // Hand-build a string list whose element length overruns the field.
      final builder = DocBuilder();
      builder.putStringList(5, <String>['abc']);
      final bytes = builder.finish().asUint8List();
      // Find the list payload and corrupt the count to a huge value.
      final view = DocView.parse(bytes);
      final cursor = view.cursor();
      var listOffset = -1;
      while (cursor.next()) {
        if (cursor.fieldId == 5) listOffset = cursor.valueOffset;
      }
      expect(listOffset, greaterThan(0));
      bytes[listOffset] = 200; // count = 200 with only one element present
      final issues = DocView.parse(bytes).validate(schema);
      expect(issues, isNotEmpty);
    });
  });

  group('project', () {
    test('reads several fields in one pass', () {
      final view = DocView.parse(sample().finish().asUint8List());
      final values = view.project(schema, <int>[2, 1, 4, 99]);
      expect(values[0], 7);
      expect((values[1]! as StringView).toString(), 'conv-42');
      expect((values[2]! as StringView).equalsString('在吗？今天下午三点开会'), isTrue);
      expect(values[3], isNull);
    });

    test('returns zero-copy string views', () {
      final view = DocView.parse(sample().finish().asUint8List());
      final values = view.project(schema, <int>[4]);
      expect(values.single, isA<StringView>());
      expect(
        utf8.encode((values.single! as StringView).toString()),
        isNotEmpty,
      );
    });

    test('handles an empty request', () {
      final view = DocView.parse(sample().finish().asUint8List());
      expect(view.project(schema, <int>[]), isEmpty);
    });
  });
}
