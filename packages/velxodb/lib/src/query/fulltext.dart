import 'dart:typed_data';

import 'index.dart';

/// Splits text into search terms.
///
/// Tokenization is a client-side decision: the database stores whatever terms
/// the tokenizer produces and never interprets them.
abstract interface class Tokenizer {
  /// Produces the terms of [text].
  List<String> tokenize(String text);

  /// Stable catalog code.
  int get kindCode;

  /// N-gram width, or `0` for word tokenizers.
  int get ngramSize;
}

/// Unicode word tokenizer: letters and digits, lowercased.
final class WordTokenizer implements Tokenizer {
  /// Creates a word tokenizer.
  const WordTokenizer();

  static final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  @override
  List<String> tokenize(String text) => <String>[
    for (final match in _word.allMatches(text.toLowerCase())) match[0]!,
  ];

  @override
  int get kindCode => 0;

  @override
  int get ngramSize => 0;
}

/// Sliding n-gram tokenizer, useful for CJK text without word boundaries.
final class NgramTokenizer implements Tokenizer {
  /// Creates an n-gram tokenizer of width [size].
  const NgramTokenizer([this.size = 2]) : assert(size > 0);

  /// Window width in runes.
  final int size;

  @override
  List<String> tokenize(String text) {
    final runes = text.toLowerCase().runes.toList(growable: false);
    final out = <String>[];
    for (var i = 0; i + size <= runes.length; i++) {
      var keep = true;
      for (var j = 0; j < size; j++) {
        final rune = runes[i + j];
        if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
          keep = false;
          break;
        }
      }
      if (keep) out.add(String.fromCharCodes(runes, i, i + size));
    }
    return out;
  }

  @override
  int get kindCode => 1;

  @override
  int get ngramSize => size;
}

/// Rebuilds a tokenizer from catalog metadata.
Tokenizer tokenizerFrom(int kind, int ngram) => switch (kind) {
  0 => const WordTokenizer(),
  1 => NgramTokenizer(ngram <= 0 ? 2 : ngram),
  _ => throw StateError('unknown tokenizer kind $kind'),
};

/// One full-text index on a collection field.
final class TextIndexDefinition {
  /// Creates a definition.
  const TextIndexDefinition({
    required this.collectionId,
    required this.fieldId,
    required this.indexId,
    required this.tokenizer,
    this.ready = true,
  });

  /// Owning collection.
  final int collectionId;

  /// Indexed field holding the text.
  final int fieldId;

  /// Two-byte namespace in the engine.
  final int indexId;

  /// Term splitter.
  final Tokenizer tokenizer;

  /// Whether every existing document has been backfilled into this index.
  final bool ready;

  /// Returns a copy with [ready] changed.
  TextIndexDefinition withReady(bool value) => TextIndexDefinition(
    collectionId: collectionId,
    fieldId: fieldId,
    indexId: indexId,
    tokenizer: tokenizer,
    ready: value,
  );

  /// Tokenizes [text] with this index's tokenizer.
  List<String> tokenize(String text) => tokenizer.tokenize(text);

  /// Namespace prefix of this index.
  Uint8List namespace() =>
      Uint8List.fromList(<int>[(indexId >> 8) & 0xFF, indexId & 0xFF]);

  /// Prefix shared by all postings of [term] (terminator included).
  Uint8List termPrefix(String term) {
    final encoded = encodeOrderedString(term);
    final out = Uint8List(2 + encoded.length);
    out[0] = (indexId >> 8) & 0xFF;
    out[1] = indexId & 0xFF;
    out.setRange(2, out.length, encoded);
    return out;
  }

  /// Full posting key for [term] and [primaryKey].
  Uint8List entryKey(String term, Uint8List primaryKey) {
    final prefix = termPrefix(term);
    final out = Uint8List(prefix.length + primaryKey.length);
    out
      ..setRange(0, prefix.length, prefix)
      ..setRange(prefix.length, out.length, primaryKey);
    return out;
  }

  /// Length of the encoded term prefix, used to slice the primary key.
  static int termPrefixLength(String term) => encodeOrderedString(term).length;
}

/// How multiple query terms combine.
enum TextQueryMode {
  /// Any term matches (union).
  any,

  /// Every term must match (intersection).
  all,
}
