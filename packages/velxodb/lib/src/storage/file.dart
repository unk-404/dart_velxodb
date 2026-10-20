import 'dart:typed_data';

/// Minimal file abstraction used by the write-ahead log.
///
/// Deliberately narrow: the log needs append, positional read, truncate and
/// flush, nothing else. Segments and manifests will use different interfaces,
/// because an append log and an immutable object have different failure modes.
///
/// Implementations must guarantee that [readAt] returns exactly [length] bytes
/// (throwing otherwise) and that [truncate] never extends the file.
abstract interface class StorageFile {
  /// Current logical length in bytes.
  Future<int> get length;

  /// Appends [bytes] at the end of the file.
  Future<void> append(Uint8List bytes);

  /// Reads exactly [length] bytes starting at [offset].
  Future<Uint8List> readAt(int offset, int length);

  /// Cuts the file to [length] bytes. Must not extend.
  Future<void> truncate(int length);

  /// Makes previously appended bytes durable.
  Future<void> flush();

  /// Releases the file. Subsequent operations throw [StateError].
  Future<void> close();
}

/// Synchronous companion used by the local engine core.
///
/// The engine's hot path is synchronous on purpose: awaiting three nested
/// futures per insert costs more than the insert itself. Remote backends
/// (object stores) get a separate async engine instead of pretending to be a
/// local file.
abstract interface class SyncStorageFile {
  /// Current logical length in bytes.
  int get lengthSync;

  /// Appends [bytes] at the end of the file.
  void appendSync(Uint8List bytes);

  /// Reads exactly [length] bytes starting at [offset].
  Uint8List readAtSync(int offset, int length);

  /// Cuts the file to [length] bytes. Must not extend.
  void truncateSync(int length);

  /// Makes previously appended bytes durable.
  void flushSync();
}

/// In-memory file implementing both the sync and async interfaces.
///
/// Used by tests and by the crash matrix: "power cut" is simulated by copying
/// the first N bytes into a fresh instance.
final class MemoryStorageFile implements StorageFile, SyncStorageFile {
  /// Creates a file with room for [capacity] bytes.
  MemoryStorageFile([int capacity = 4096])
    : _data = Uint8List(capacity < 64 ? 64 : capacity);

  Uint8List _data;
  int _length = 0;
  bool _closed = false;

  /// Number of times the file was flushed.
  int flushCount = 0;

  /// Number of append calls.
  int appendCount = 0;

  /// A read-only view of the current contents.
  Uint8List get bytes => Uint8List.sublistView(_data, 0, _length);

  @override
  int get lengthSync {
    _checkOpen();
    return _length;
  }

  @override
  void appendSync(Uint8List bytes) {
    _checkOpen();
    _ensure(_length + bytes.length);
    _data.setRange(_length, _length + bytes.length, bytes);
    _length += bytes.length;
    appendCount++;
  }

  @override
  Uint8List readAtSync(int offset, int length) {
    _checkOpen();
    if (offset < 0 || length < 0 || offset + length > _length) {
      throw RangeError('read [$offset, ${offset + length}) outside 0..$_length');
    }
    return Uint8List.sublistView(_data, offset, offset + length);
  }

  @override
  void truncateSync(int length) {
    _checkOpen();
    if (length < 0 || length > _length) {
      throw RangeError.value(length, 'length', 'must be within 0..$_length');
    }
    _length = length;
  }

  @override
  void flushSync() {
    _checkOpen();
    flushCount++;
  }

  @override
  Future<int> get length async => lengthSync;

  @override
  Future<void> append(Uint8List bytes) async => appendSync(bytes);

  @override
  Future<Uint8List> readAt(int offset, int length) async =>
      readAtSync(offset, length);

  @override
  Future<void> truncate(int length) async => truncateSync(length);

  @override
  Future<void> flush() async => flushSync();

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _ensure(int needed) {
    if (needed <= _data.length) return;
    var capacity = _data.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final next = Uint8List(capacity)..setRange(0, _length, _data);
    _data = next;
  }

  void _checkOpen() {
    if (_closed) throw StateError('file is closed');
  }
}
