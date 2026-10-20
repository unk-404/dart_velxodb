/// Storage engine building blocks.
///
/// Layering, from the bottom up:
///
/// * [StorageFile] — the only file abstraction the log needs.
/// * `block` — packs self-delimiting VXS documents into immutable blocks.
/// * `wal` — framed, checksummed, crash-recoverable append log.
///
/// Nothing here imports `dart:io`; the layers are pure byte codecs plus one
/// minimal async file interface.
library;

export 'src/storage/block.dart';
export 'src/storage/file.dart';
export 'src/storage/wal.dart';
