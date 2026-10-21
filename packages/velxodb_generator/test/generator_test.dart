import 'package:test/test.dart';
import 'package:velxodb_generator/velxodb_generator.dart';

const spec = ModelSpec(
  className: 'Message',
  collectionName: 'messages',
  keyField: 'id',
  fields: <FieldSpec>[
    FieldSpec('id', 1, FieldKind.string),
    FieldSpec('senderId', 2, FieldKind.string, indexed: true, target: 'users'),
    FieldSpec('createdAt', 3, FieldKind.int64, indexed: true),
    FieldSpec('edited', 4, FieldKind.boolean, nullable: true),
  ],
);

void main() {
  group('generateModel', () {
    test('emits direct codecs instead of schema objects', () {
      final source = generateModel(spec);
      expect(source, contains('static void encodeInto('));
      expect(source, contains('static Message decodeFrom(DocView view)'));
      expect(source, contains('static void ensureIndexes(Collection collection)'));
      expect(source, contains('TypedCollection<Message>'));
      expect(source, contains('encodeInto,'));
      expect(source, contains('decodeFrom,'));
      expect(source, isNot(contains('DocumentSchema')));
      expect(source, isNot(contains('Field.')));
    });

    test('makes nullable fields optional and non-null fields required', () {
      final source = generateModel(spec);
      expect(source, contains('required this.id'));
      expect(source, contains('this.edited,'));
      expect(source, isNot(contains('required this.edited')));
    });

    test('declares index creation with wire ids', () {
      final source = generateModel(spec);
      expect(source, contains('createIndex(_senderIdId, VxsType.string)'));
      expect(source, contains('createIndex(_createdAtId, VxsType.int64)'));
    });

    test('emits reference bindings for target fields', () {
      final source = generateModel(spec);
      expect(
        source,
        contains(
          "createReference(_senderIdId, 'users', onDelete: OnDelete.restrict)",
        ),
      );
    });

    test('rejects a non-string key field', () {
      const bad = ModelSpec(
        className: 'Bad',
        collectionName: 'bad',
        keyField: 'id',
        fields: <FieldSpec>[FieldSpec('id', 1, FieldKind.int64)],
      );
      expect(() => generateModel(bad), throwsArgumentError);
    });
  });
}
