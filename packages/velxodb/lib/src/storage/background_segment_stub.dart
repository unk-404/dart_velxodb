import 'dart:typed_data';

import 'background_segment_common.dart';

/// Web fallback: no isolates, so the segment is built inline.
Future<Uint8List> buildSegmentInBackground(
  Uint8List batch,
  int blockTargetSize,
) async => buildSegmentFromBatch(batch, blockTargetSize);
