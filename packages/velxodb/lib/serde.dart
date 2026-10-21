/// The VXS binary format: zero-copy documents with stable field ids.
///
/// ```dart
/// final builder = DocBuilder(schemaId: 1, schemaVersion: 1)
///   ..putString(1, 'conv-42')
///   ..putInt(2, 7)
///   ..putString(3, '在吗？');
/// final bytes = builder.finish();
///
/// final view = DocView.parse(bytes.asUint8List());
/// print(view.getString(3));
/// ```
library;

/// `Bytes` is blit's zero-copy buffer type. Re-exporting it keeps the VXS API
/// usable without a second import.
export 'package:blit/blit.dart' show Bytes;

export 'src/serde/builder.dart';
export 'src/serde/crc32c.dart';
export 'src/serde/schema.dart';
export 'src/serde/sink.dart';
export 'src/serde/string_view.dart';
export 'src/serde/view.dart';
export 'src/serde/vxs.dart';
