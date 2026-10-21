import 'dart:typed_data';

import 'package:blit/blit.dart';

/// One key/value pair returned by a scan or a cursor.
typedef ScanEntry = ({Uint8List key, Bytes value});

/// A page of results plus the key to start after for the next page.
typedef ScanPage = ({List<ScanEntry> entries, Uint8List? next});
