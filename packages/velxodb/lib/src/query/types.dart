import 'dart:typed_data';

import 'package:blit/blit.dart';

/// One key/value pair returned by a scan or a cursor.
typedef ScanEntry = ({Uint8List key, Bytes value});
