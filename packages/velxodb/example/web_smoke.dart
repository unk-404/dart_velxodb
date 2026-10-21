// Compile-time smoke test for the web build.
//
// CI compiles this file with `dart compile js` and `dart compile wasm`. It
// imports the full public surface (including the OPFS database) so a `dart:io`
// leak or a web-incompatible import fails the build instead of the user's app.
import 'dart:typed_data';

import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Future<void> main() async {
  final payload =
      (DocBuilder(schemaId: 1)
            ..putString(1, 'web')
            ..putInt(2, 1))
          .finish();
  final document = DocView.parse(payload.asUint8List());

  final db = await VelxoWebDatabase.open(root: 'velxodb-smoke');
  final collection = await db.collection('messages');
  await collection.put(Uint8List.fromList(<int>[1]), payload);
  final read = await collection.get(Uint8List.fromList(<int>[1]));
  await db.close();

  print('web smoke: ${document.fieldCount} fields, ${read?.length ?? 0} bytes');
}
