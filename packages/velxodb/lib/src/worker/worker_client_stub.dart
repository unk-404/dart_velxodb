import 'dart:typed_data';

import '../errors.dart';
import '../storage/engine.dart' show Durability;
import 'worker_types.dart';

/// Web stub: isolates are not available, so the worker facade is unsupported.
final class VelxoWorker {
  static Future<VelxoWorker> open(
    String path, {
    Durability durability = Durability.batched,
    bool backgroundFlush = false,
  }) async {
    throw const VelxoWorkerException(
      'worker isolates are not available on the web',
    );
  }

  Future<Uint8List?> get(String collection, Uint8List key) =>
      Future<Uint8List?>.error(_unsupported);

  Future<void> put(String collection, Uint8List key, Uint8List value) =>
      Future<void>.error(_unsupported);

  Future<void> delete(String collection, Uint8List key) =>
      Future<void>.error(_unsupported);

  Future<WorkerPage> page(
    String collection, {
    Uint8List? prefix,
    Uint8List? after,
    int limit = 100,
  }) => Future<WorkerPage>.error(_unsupported);

  Future<void> flush() => Future<void>.error(_unsupported);

  Future<void> waitForMaintenance() => Future<void>.error(_unsupported);

  Future<WorkerCheck> check() => Future<WorkerCheck>.error(_unsupported);

  Future<void> close({bool flush = false}) => Future<void>.error(_unsupported);

  static const VelxoWorkerException _unsupported = VelxoWorkerException(
    'worker isolates are not available on the web',
  );
}
