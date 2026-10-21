import 'package:velxodb/serde.dart';

void main() {
  final payload =
      (DocBuilder(schemaId: 1, schemaVersion: 1)
            ..putString(1, 'conv-42')
            ..putInt(2, 7)
            ..putInt(3, 1750000000000)
            ..putString(4, '在吗？今天下午三点开会'))
          .finish();

  final view = DocView.parse(payload.asUint8List());
  print('encoded ${payload.length} bytes, ${view.fieldCount} fields');
  print('text: ${view.getString(4)}');
  // Zero-copy: no String is created for a projection you never materialise.
  print('text bytes: ${view.getBytes(4)!.length}');
}
