import 'dart:isolate';
import 'dart:typed_data';

import 'background_segment_common.dart';

/// Builds a segment on a fresh background isolate.
///
/// The batch is transferred (no copy); the segment bytes are transferred back.
Future<Uint8List> buildSegmentInBackground(
  Uint8List batch,
  int blockTargetSize,
) async {
  final transferable = TransferableTypedData.fromList(<Uint8List>[batch]);
  final result = await Isolate.run(() {
    final data = transferable.materialize().asUint8List();
    return TransferableTypedData.fromList(<Uint8List>[
      buildSegmentFromBatch(data, blockTargetSize),
    ]);
  });
  return result.materialize().asUint8List();
}
