// A complete walk through the local engine. Run it on the Dart VM:
//
//   dart run example/database.dart
//
// It creates a temporary database, writes documents, declares a secondary
// index and a reference binding, runs an atomic transaction, and prints the
// results. Every file it creates is removed at the end.
import 'dart:io';
import 'dart:typed_data';

import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List key(String value) => Uint8List.fromList(value.codeUnits);

Bytes message(String id, String sender, String body) =>
    (DocBuilder(schemaId: 1)
          ..putString(1, id)
          ..putString(2, sender)
          ..putString(3, body))
        .finish();

Bytes user(String id, String name) =>
    (DocBuilder(schemaId: 2)
          ..putString(1, id)
          ..putString(2, name))
        .finish();

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('velxodb_example_');
  final db = VelxoDatabase.openSync(root.path);
  try {
    final users = db.collection('users');
    final messages = db.collection('messages');

    users.putSync(key('u1'), user('u1', 'Ada'));
    users.putSync(key('u2'), user('u2', 'Grace'));

    // A reference binding creates the reverse index used by restrict/cascade.
    messages.createReference(2, 'users');
    messages.createIndex(2, VxsType.string);

    db.transactionSync(() {
      messages.putSync(key('m1'), message('m1', 'u1', 'hello'));
      messages.putSync(key('m2'), message('m2', 'u2', 'hi'));
    });

    final fromAda = messages.lookupByIndexSync(2, 'u1');
    print('messages from u1: ${fromAda.length}');

    final view = DocView.parse(messages.get(key('m1'))!.asUint8List());
    print('body: ${view.getString(3)}');

    try {
      users.deleteSync(key('u1'));
    } on VelxoConstraintException catch (error) {
      print('restrict: ${error.message}');
    }

    final page = messages.pageSync(limit: 1);
    print('first page: ${page.entries.length}, next: ${page.next?.length}');

    print('check: ${db.checkSync(deep: true).describe()}');
    await db.close(flush: true);

    // Reopen from disk: the manifest, not a WAL replay, serves the data.
    final reopened = VelxoDatabase.openSync(root.path);
    print(
      'after reopen: ${reopened.collection('messages').lookupByIndexSync(2, 'u2').length} '
      'message(s) from u2',
    );
    await reopened.close();
  } finally {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
