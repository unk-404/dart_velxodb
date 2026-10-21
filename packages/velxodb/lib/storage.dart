/// Storage engine building blocks.
///
/// Layering, from the bottom up:
///
/// * [StorageFile] — the only file abstraction the log needs.
/// * `block` — packs self-delimiting VXS documents into immutable blocks.
/// * `wal` — framed, checksummed, crash-recoverable append log.
/// * `memtable` — open-addressed in-memory table of key → value reference.
/// * `arena` — append-only chunked document store with stable views.
/// * `engine` — composes WAL, arena and memtable into the write path.
///
/// Nothing here imports `dart:io`; the layers are pure byte codecs plus one
/// minimal async file interface.
library;

export 'src/storage/arena.dart';
export 'src/storage/block.dart';
export 'src/storage/bloom.dart';
export 'src/storage/directory.dart';
export 'src/storage/engine.dart';
export 'src/storage/file.dart';
export 'src/storage/manifest.dart';
export 'src/storage/memtable.dart';
export 'src/storage/segment.dart';
export 'src/storage/wal.dart';
