import 'dart:typed_data';

export 'background_segment_common.dart' show buildSegmentFromBatch;
export 'background_segment_stub.dart'
    if (dart.library.io) 'background_segment_io.dart';

/// Builds a segment from a `WalBatch` payload.
typedef SegmentBuildFunction =
    Future<Uint8List> Function(Uint8List batch, int blockTargetSize);
