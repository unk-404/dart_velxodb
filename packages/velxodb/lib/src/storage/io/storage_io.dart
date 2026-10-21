/// Local-filesystem storage backend.
///
/// On the VM this is backed by `dart:io`; on the web the same API exists but the
/// constructor throws, because a synchronous local engine cannot run there.
library;

export 'storage_io_stub.dart' if (dart.library.io) 'storage_io_io.dart';
