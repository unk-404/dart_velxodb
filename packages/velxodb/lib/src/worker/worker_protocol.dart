import '../errors.dart';

/// Encodes an exception for the worker protocol.
String errorCode(Object error) {
  if (error is VelxoLockedException) return 'locked';
  if (error is VelxoCorruptException) return 'corrupt';
  if (error is VelxoClosedException) return 'closed';
  if (error is VelxoConflictException) return 'conflict';
  if (error is VelxoConstraintException) return 'constraint';
  if (error is VelxoNotFoundException) return 'not-found';
  if (error is VelxoReadOnlyException) return 'read-only';
  if (error is VelxoUpgradeRequiredException) return 'upgrade-required';
  if (error is VelxoIncompatibleException) return 'incompatible';
  return 'worker';
}

/// Rebuilds a typed exception from its protocol code.
VelxoException errorFromCode(String code, String message) {
  return switch (code) {
    'locked' => VelxoLockedException(message),
    'corrupt' => VelxoCorruptException(message),
    'closed' => VelxoClosedException(message),
    'conflict' => VelxoConflictException(message),
    'constraint' => VelxoConstraintException(message),
    'not-found' => VelxoNotFoundException(message),
    'read-only' => VelxoReadOnlyException(message),
    'upgrade-required' => VelxoUpgradeRequiredException(message),
    'incompatible' => VelxoIncompatibleException(message),
    _ => VelxoWorkerException(message),
  };
}
