import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'memtable.dart';

/// Append-only byte store for encoded documents.
///
/// Documents are copied into fixed-size chunks; chunks are never moved, so a
/// [Bytes] view handed out by [view] stays valid for the life of the arena.
/// This is what lets the memtable store references instead of document copies
/// and keeps reads zero-copy.
final class DocArena {
  /// Creates an arena with [chunkSize] bytes per chunk.
  DocArena({int chunkSize = 1 << 20})
    : _chunkSize = chunkSize < 64 ? 64 : chunkSize;

  final int _chunkSize;
  final List<Uint8List> _chunks = <Uint8List>[];
  int _current = -1;
  int _used = 0;
  int _total = 0;

  /// Number of allocated chunks.
  int get chunkCount => _chunks.length;

  /// Total bytes appended since creation (including superseded values).
  int get bytesUsed => _total;

  /// Chunk capacity in bytes.
  int get chunkSize => _chunkSize;

  /// Copies [bytes] into the arena and returns a reference to it.
  MemRef append(Uint8List bytes) {
    final length = bytes.length;
    if (length > _chunkSize) {
      // Oversized document: give it its own chunk so it stays contiguous.
      final chunk = Uint8List(length)..setRange(0, length, bytes);
      _chunks.add(chunk);
      _total += length;
      return (chunk: _chunks.length - 1, offset: 0, length: length);
    }
    if (_current < 0 || _used + length > _chunkSize) {
      _chunks.add(Uint8List(_chunkSize));
      _current = _chunks.length - 1;
      _used = 0;
    }
    final chunk = _chunks[_current];
    final offset = _used;
    chunk.setRange(offset, offset + length, bytes);
    _used += length;
    _total += length;
    return (chunk: _current, offset: offset, length: length);
  }

  /// Zero-copy view of a previously appended range.
  Bytes view(int chunk, int offset, int length) =>
      Bytes.view(_chunks[chunk], offset, length);

  /// Raw chunk bytes, for flushing into blocks.
  Uint8List chunkBytes(int index) => _chunks[index];

  /// Bytes written into the current chunk.
  int get currentChunkUsed => _used;
}
