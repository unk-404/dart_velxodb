@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes userDoc(String id) => (DocBuilder(schemaId: 2)
      ..putString(1, id))
    .finish();

Bytes messageDoc(String id, String sender) => (DocBuilder(schemaId: 1)
      ..putString(1, id)
      ..putString(3, sender))
    .finish();

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection users;
  late Collection messages;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_ref_');
    db = VelxoDatabase.openSync(root.path);
    users = db.collection('users');
    messages = db.collection('messages');
    users.putSync(k('u1'), userDoc('u1'));
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('reference binding', () {
    test('creates a reverse index on the reference field', () {
      final definition = messages.createReference(3, 'users');
      expect(definition.targetCollectionId, users.id);
      expect(definition.onDelete, OnDelete.restrict);
      expect(messages.indexes[3]?.type, VxsType.string);
    });

    test('rejects an unknown target collection', () {
      expect(
        () => messages.createReference(3, 'nope'),
        throwsStateError,
      );
    });

    test('restrict refuses to delete a referenced document', () {
      messages.createReference(3, 'users');
      messages.putSync(k('m1'), messageDoc('m1', 'u1'));

      expect(() => users.deleteSync(k('u1')), throwsStateError);
      expect(users.get(k('u1')), isNotNull);

      messages.deleteSync(k('m1'));
      users.deleteSync(k('u1'));
      expect(users.get(k('u1')), isNull);
    });

    test('cascade deletes referring documents and their index entries', () {
      messages.createReference(3, 'users', onDelete: OnDelete.cascade);
      messages.putSync(k('m1'), messageDoc('m1', 'u1'));
      messages.putSync(k('m2'), messageDoc('m2', 'u1'));

      users.deleteSync(k('u1'));

      expect(users.get(k('u1')), isNull);
      expect(messages.get(k('m1')), isNull);
      expect(messages.get(k('m2')), isNull);
      expect(messages.lookupByIndexSync(3, 'u1'), isEmpty);
    });

    test('cascade survives a cycle', () {
      final follows = db.collection('follows');
      follows.createReference(1, 'users', onDelete: OnDelete.cascade);
      follows.createReference(2, 'users', onDelete: OnDelete.cascade);
      users.enforceReferences = true;
      follows.putSync(
        k('f1'),
        (DocBuilder(schemaId: 3)..putString(1, 'u1')..putString(2, 'u2'))
            .finish(),
      );
      users.putSync(k('u2'), userDoc('u2'));

      users.deleteSync(k('u1'));
      expect(follows.get(k('f1')), isNull);
      expect(users.get(k('u2')), isNotNull);
    });

    test('enforcement rejects writes pointing at a missing document', () {
      messages.createReference(3, 'users');
      messages.enforceReferences = true;

      expect(
        () => messages.putSync(k('m1'), messageDoc('m1', 'ghost')),
        throwsStateError,
      );
      messages.putSync(k('m1'), messageDoc('m1', 'u1'));
      expect(messages.get(k('m1')), isNotNull);
    });

    test('bindings and policies survive a reopen', () async {
      messages.createReference(3, 'users');
      messages.putSync(k('m1'), messageDoc('m1', 'u1'));
      await db.close();

      db = VelxoDatabase.openSync(root.path);
      users = db.collection('users');
      messages = db.collection('messages');
      expect(messages.references.containsKey(3), isTrue);
      expect(messages.references[3]?.onDelete, OnDelete.restrict);
      expect(() => users.deleteSync(k('u1')), throwsStateError);
    });
  });
}
