import '../errors.dart';

/// Encodes an exception for the worker protocol.
String errorCode(Object error) {
  if (error is VelxoLockedException) return 'locked';
  if (error is VelxoCorruptException) return 'corrupt';
  if (error is VelxoClosedException) return 'closed';
  if (error is VelxoConflictException) return 'conflict';
  if (error is VelxoNotFoundException) return 'not-found';
  return 'worker';
}

/// Rebuilds a typed exception from its protocol code.
VelxoException errorFromCode(String code, String message) {
  return switch (code) {
    'locked' => VelxoLockedException(message),
    'corrupt' => VelxoCorruptException(message),
    'closed' => VelxoClosedException(message),
    'conflict' => VelxoConflictException(message),
    'not-found' => VelxoNotFoundException(message),
    _ => VelxoWorkerException(message),
  };
}
