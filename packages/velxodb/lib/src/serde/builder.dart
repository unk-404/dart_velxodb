import 'dart:typed_data';

import 'package:blit/blit.dart';

import 'sink.dart';

/// Builds one VXS document.
///
/// Fields must be written in strictly ascending id order, which is what makes
/// the encoding canonical: one logical document has exactly one byte form.
///
/// This is the single-document convenience wrapper over [DocSink]. For batches,
/// use [DocSink] directly: it writes many documents into one buffer with no
/// per-document allocation.
final class DocBuilder {
  /// Creates a builder. [capacity] is the initial buffer size, not a limit.
  DocBuilder({this.schemaId = 0, this.schemaVersion = 1, int capacity = 256})
    : _capacity = capacity < 64 ? 64 : capacity,
      _sink = DocSink(capacity: capacity < 64 ? 64 : capacity);

  /// Schema id written into the header.
  int schemaId;

  /// Schema version written into the header.
  int schemaVersion;

  final int _capacity;
  DocSink _sink;
  bool _open = false;
  bool _finished = false;

  /// Bytes written so far, including the reserved header.
  int get length => _sink.length;

  /// Writes a boolean field.
  void putBool(int fieldId, bool value) {
    _ensureOpen();
    _sink.putBool(fieldId, value);
  }

  /// Writes a signed integer field using zigzag varints.
  void putInt(int fieldId, int value) {
    _ensureOpen();
    _sink.putInt(fieldId, value);
  }

  /// Writes an unsigned varint field without zigzag.
  void putUnsigned(int fieldId, int value) {
    _ensureOpen();
    _sink.putUnsigned(fieldId, value);
  }

  /// Writes a float64 field.
  void putFloat64(int fieldId, double value) {
    _ensureOpen();
    _sink.putFloat64(fieldId, value);
  }

  /// Writes a float32 field.
  void putFloat32(int fieldId, double value) {
    _ensureOpen();
    _sink.putFloat32(fieldId, value);
  }

  /// Writes a UTF-8 string field.
  void putString(int fieldId, String value) {
    _ensureOpen();
    _sink.putString(fieldId, value);
  }

  /// Writes an opaque bytes field.
  void putBytes(int fieldId, List<int> value) {
    _ensureOpen();
    _sink.putBytes(fieldId, value);
  }

  /// Writes a `List<String>` field.
  void putStringList(int fieldId, List<String> values) {
    _ensureOpen();
    _sink.putStringList(fieldId, values);
  }

  /// Writes a `List<int>` field.
  void putIntList(int fieldId, List<int> values) {
    _ensureOpen();
    _sink.putIntList(fieldId, values);
  }

  /// Writes an already encoded document (including its header) as a nested doc.
  void putDoc(int fieldId, Bytes doc) {
    _ensureOpen();
    _sink.putDoc(fieldId, doc);
  }

  /// Copies an encoded value verbatim, for forward-compatibility round trips.
  ///
  /// [start] must point at the first byte of the value (just past the key) and
  /// [end] just past it. Wire-type-specific framing is preserved as-is.
  void putRawEntry(
    int fieldId,
    int wireType,
    Uint8List source,
    int start,
    int end,
  ) {
    _ensureOpen();
    _sink.putRawEntry(fieldId, wireType, source, start, end);
  }

  /// Patches the header and returns the finished document.
  ///
  /// The returned view shares the builder's buffer; [reset] starts a new one, so
  /// the view stays valid.
  Bytes finish() {
    if (_finished) {
      throw StateError('finish() has already been called');
    }
    _ensureOpen();
    _finished = true;
    final start = _sink.endDoc();
    return Bytes.view(_sink.buffer, start, _sink.length - start);
  }

  /// Discards the contents while keeping the configured capacity.
  void reset({int? schemaId, int? schemaVersion}) {
    _sink = DocSink(capacity: _capacity);
    _open = false;
    _finished = false;
    if (schemaId != null) this.schemaId = schemaId;
    if (schemaVersion != null) this.schemaVersion = schemaVersion;
  }

  void _ensureOpen() {
    if (_finished) {
      throw StateError('builder already finished; call reset()');
    }
    if (!_open) {
      _sink.beginDoc(schemaId: schemaId, schemaVersion: schemaVersion);
      _open = true;
    }
  }
}
