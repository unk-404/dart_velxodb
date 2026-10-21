import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'segment.dart';
import 'wal.dart';

/// Builds a segment from a `WalBatch` payload.
///
/// Runs in the background isolate (or inline on the web); it only touches pure
/// byte codecs, never files or engine state.
Uint8List buildSegmentFromBatch(Uint8List batch, int blockTargetSize) {
  final builder = SegmentBuilder(blockTargetSize: blockTargetSize);
  WalBatch.decode(batch, (kind, key, value) {
    if (kind == WalOpKind.delete) {
      builder.addTombstone(key);
    } else {
      final bytes = value!;
      builder.add(key, Bytes.view(bytes, 0, bytes.length));
    }
  });
  return builder.finish().asUint8List();
}
