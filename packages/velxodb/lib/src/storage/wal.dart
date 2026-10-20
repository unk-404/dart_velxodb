import 'dart:typed_data';

import '../serde/crc32c.dart';
import '../serde/vxs.dart';
import 'file.dart';

/// Size of a WAL frame header: payload length + checksum.
const int walHeaderSize = 8;

/// Encodes and decodes WAL frames.
///
/// A frame is `[u32 payloadLength][u32 crc32c][payload]`. The length comes
/// first so recovery can detect a torn tail without reading past the file.
abstract final class WalFrame {
  /// Encodes [payload] as a frame. Allocates; the [Wal] writer uses a scratch
  /// buffer instead on the hot path.
  static Uint8List encode(Uint8List payload) {
    final out = Uint8List(walHeaderSize + payload.length);
    VxsLe.w32(out, 0, payload.length);
    VxsLe.w32(out, 4, VxsCrc32c.compute(payload));
    out.setRange(walHeaderSize, out.length, payload);
    return out;
  }
}

/// Operation kinds stored in a WAL batch.
enum WalOpKind {
  /// Insert or replace a value.
  put(1),

  /// Remove a key.
  delete(2);

  const WalOpKind(this.code);

  /// Byte stored on disk.
  final int code;

  /// Decodes the on-disk byte.
  static WalOpKind fromCode(int code) => switch (code) {
    1 => WalOpKind.put,
    2 => WalOpKind.delete,
    _ => throw VxsFormatException('unknown WAL op code $code'),
  };
}

/// One operation inside a WAL batch.
final class WalOp {
  /// Inserts or replaces [key] with [value].
  WalOp.put(this.key, this.value) : kind = WalOpKind.put;

  /// Removes [key].
  WalOp.delete(this.key) : kind = WalOpKind.delete, value = null;

  /// Operation kind.
  final WalOpKind kind;

  /// Key bytes.
  final Uint8List key;

  /// Value bytes for [WalOpKind.put], otherwise `null`.
  final Uint8List? value;
}

/// Encodes and decodes the payload of one WAL frame: a batch of operations.
///
/// ```text
/// varint opCount
/// repeat: u8 kind, varint keyLen, key, varint valueLen, value
/// ```
abstract final class WalBatch {
  /// Encodes [ops] into a frame payload.
  static Uint8List encode(List<WalOp> ops) {
    final out = Uint8List(encodedSize(ops));
    encodeInto(out, 0, ops);
    return out;
  }

  /// Bytes needed to encode [ops].
  static int encodedSize(List<WalOp> ops) {
    var size = _varintSize(ops.length);
    for (final op in ops) {
      size += 1 + _varintSize(op.key.length) + op.key.length;
      final value = op.value;
      final length = value?.length ?? 0;
      size += _varintSize(length) + length;
    }
    return size;
  }

  /// Encodes [ops] into [out] starting at [offset]; returns the end offset.
  static int encodeInto(Uint8List out, int offset, List<WalOp> ops) {
    var pos = _writeVarint(out, offset, ops.length);
    for (final op in ops) {
      out[pos++] = op.kind.code;
      pos = _writeVarint(out, pos, op.key.length);
      out.setRange(pos, pos + op.key.length, op.key);
      pos += op.key.length;
      final value = op.value;
      if (value == null) {
        pos = _writeVarint(out, pos, 0);
      } else {
        pos = _writeVarint(out, pos, value.length);
        out.setRange(pos, pos + value.length, value);
        pos += value.length;
      }
    }
    return pos;
  }

  /// Decodes a frame payload, visiting operations in order.
  ///
  /// Key and value slices point into [payload]; do not mutate it while using
  /// them. Throws [VxsFormatException] on malformed input.
  static void decode(
    Uint8List payload,
    void Function(WalOpKind kind, Uint8List key, Uint8List? value) visit,
  ) {
    final count = VxsVarint.decode(payload, 0, payload.length);
    var pos = count.next;
    for (var i = 0; i < count.value; i++) {
      if (pos >= payload.length) {
        throw VxsFormatException('truncated WAL batch', offset: pos);
      }
      final kind = WalOpKind.fromCode(payload[pos++]);
      final keyLength = VxsVarint.decode(payload, pos, payload.length);
      pos = keyLength.next;
      final keyEnd = pos + keyLength.value;
      if (keyEnd > payload.length) {
        throw VxsFormatException('WAL key overruns the batch', offset: pos);
      }
      final key = Uint8List.sublistView(payload, pos, keyEnd);
      pos = keyEnd;
      final valueLength = VxsVarint.decode(payload, pos, payload.length);
      pos = valueLength.next;
      Uint8List? value;
      if (kind == WalOpKind.put) {
        final valueEnd = pos + valueLength.value;
        if (valueEnd > payload.length) {
          throw VxsFormatException('WAL value overruns the batch', offset: pos);
        }
        value = Uint8List.sublistView(payload, pos, valueEnd);
        pos = valueEnd;
      } else if (valueLength.value != 0) {
        throw VxsFormatException(
          'delete op carries ${valueLength.value} value bytes',
          offset: pos,
        );
      }
      visit(kind, key, value);
    }
    if (pos != payload.length) {
      throw VxsFormatException(
        '${payload.length - pos} trailing bytes in WAL batch',
        offset: pos,
      );
    }
  }

  static int _varintSize(int value) {
    var size = 1;
    var remaining = value ~/ 0x80;
    while (remaining != 0) {
      size++;
      remaining ~/= 0x80;
    }
    return size;
  }

  /// Bytes needed for one operation, excluding the batch count.
  static int opSize(Uint8List key, Uint8List? value) {
    final valueLength = value?.length ?? 0;
    return 1 +
        _varintSize(key.length) +
        key.length +
        _varintSize(valueLength) +
        valueLength;
  }

  /// Writes one operation and returns the end offset.
  static int writeOp(
    Uint8List out,
    int offset,
    WalOpKind kind,
    Uint8List key,
    Uint8List? value,
  ) {
    var pos = offset;
    out[pos++] = kind.code;
    pos = _writeVarint(out, pos, key.length);
    out.setRange(pos, pos + key.length, key);
    pos += key.length;
    if (value == null) {
      return _writeVarint(out, pos, 0);
    }
    pos = _writeVarint(out, pos, value.length);
    out.setRange(pos, pos + value.length, value);
    return pos + value.length;
  }

  static int _writeVarint(Uint8List out, int offset, int value) {
    var pos = offset;
    var remaining = value;
    while (remaining >= 0x80) {
      out[pos++] = (remaining % 0x80) | 0x80;
      remaining ~/= 0x80;
    }
    out[pos++] = remaining;
    return pos;
  }
}

/// Append-only write-ahead log over a [SyncStorageFile].
///
/// The log knows nothing about memtables or segments: [replaySync] hands raw
/// frame payloads to a callback and truncates any torn tail it finds.
///
/// The core is synchronous because the engine's hot path is: three nested
/// `await`s per insert used to cost more than the insert itself. Async wrappers
/// exist for callers that already live in a `Future` world.
final class Wal {
  /// Wraps [file] as a write-ahead log.
  Wal(this.file);

  /// Backing file.
  final SyncStorageFile file;

  Uint8List _scratch = Uint8List(1024);

  /// Appends one frame. The frame is not durable until [sync].
  void appendSync(Uint8List payload) {
    _ensureScratch(walHeaderSize + payload.length);
    _scratch.setRange(walHeaderSize, walHeaderSize + payload.length, payload);
    _commitSync(walHeaderSize + payload.length);
  }

  /// Appends [ops] as one batch frame.
  ///
  /// Encodes straight into the frame scratch: one allocation-free batch, one
  /// checksum pass and one file append.
  void appendBatchSync(List<WalOp> ops) {
    final payloadSize = WalBatch.encodedSize(ops);
    _ensureScratch(walHeaderSize + payloadSize);
    final end = WalBatch.encodeInto(_scratch, walHeaderSize, ops);
    _commitSync(end);
  }

  /// Async facade over [appendSync].
  Future<void> append(Uint8List payload) async => appendSync(payload);

  /// Async facade over [appendBatchSync].
  Future<void> appendBatch(List<WalOp> ops) async => appendBatchSync(ops);

  /// Appends a single put without building a `WalOp` or a list.
  void appendPutSync(Uint8List key, Uint8List value) =>
      _appendSingleSync(WalOpKind.put, key, value);

  /// Appends a single delete without building a `WalOp` or a list.
  void appendDeleteSync(Uint8List key) =>
      _appendSingleSync(WalOpKind.delete, key, null);

  void _appendSingleSync(WalOpKind kind, Uint8List key, Uint8List? value) {
    final payloadSize = 1 + WalBatch.opSize(key, value);
    _ensureScratch(walHeaderSize + payloadSize);
    _scratch[walHeaderSize] = 1; // one operation
    WalBatch.writeOp(_scratch, walHeaderSize + 1, kind, key, value);
    _commitSync(walHeaderSize + payloadSize);
  }

  /// Makes every appended frame durable.
  void syncNow() => file.flushSync();

  /// Async facade over [syncNow].
  Future<void> sync() async => syncNow();

  void _commitSync(int end) {
    VxsLe.w32(_scratch, 0, end - walHeaderSize);
    VxsLe.w32(_scratch, 4, VxsCrc32c.compute(_scratch, walHeaderSize, end));
    file.appendSync(Uint8List.sublistView(_scratch, 0, end));
  }

  void _ensureScratch(int needed) {
    if (_scratch.length >= needed) return;
    var capacity = _scratch.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _scratch = Uint8List(capacity);
  }

  /// Replays every intact frame and truncates a torn tail.
  ///
  /// Returns the offset of the first invalid byte (the new file length). Frames
  /// after a damaged one are discarded: a torn write means everything after it
  /// is untrustworthy.
  int replaySync(void Function(Uint8List payload) apply) {
    final length = file.lengthSync;
    var offset = 0;
    var validEnd = 0;
    while (offset + walHeaderSize <= length) {
      final header = file.readAtSync(offset, walHeaderSize);
      final payloadLength = VxsLe.u32(header, 0);
      final checksum = VxsLe.u32(header, 4);
      if (offset + walHeaderSize + payloadLength > length) break;
      final payload = file.readAtSync(offset + walHeaderSize, payloadLength);
      if (VxsCrc32c.compute(payload) != checksum) break;
      apply(payload);
      offset += walHeaderSize + payloadLength;
      validEnd = offset;
    }
    if (validEnd < length) {
      file.truncateSync(validEnd);
    }
    return validEnd;
  }

  /// Async facade over [replaySync].
  Future<int> replay(void Function(Uint8List payload) apply) async =>
      replaySync(apply);
}
