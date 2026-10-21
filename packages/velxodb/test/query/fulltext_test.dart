@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

Uint8List k(String value) => Uint8List.fromList(value.codeUnits);

Bytes doc(String text) => (DocBuilder(schemaId: 1)..putString(1, text)).finish();

List<String> keysOf(List<ScanEntry> entries) =>
    <String>[for (final entry in entries) String.fromCharCodes(entry.key)];

void main() {
  late Directory root;
  late VelxoDatabase db;
  late Collection collection;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_text_');
    db = VelxoDatabase.openSync(root.path);
    collection = db.collection('notes');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('tokenizers', () {
    test('word tokenizer lowercases and splits punctuation', () {
      const tokenizer = WordTokenizer();
      expect(
        tokenizer.tokenize('Hello, WORLD! 你好 world'),
        <String>['hello', 'world', '你好', 'world'],
      );
    });

    test('n-gram tokenizer slides over runes and skips spaces', () {
      const tokenizer = NgramTokenizer(2);
      expect(tokenizer.tokenize('abcd'), <String>['ab', 'bc', 'cd']);
      expect(tokenizer.tokenize('a b'), <String>[]);
      expect(tokenizer.tokenize('今天开会'), <String>['今天', '天开', '开会']);
    });
  });

  group('full-text index', () {
    test('finds documents by word', () {
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('hello world'));
      collection.putSync(k('b'), doc('hello there'));
      collection.putSync(k('c'), doc('goodbye'));

      expect(keysOf(collection.searchTextSync(1, 'hello')), <String>['a', 'b']);
      expect(keysOf(collection.searchTextSync(1, 'there')), <String>['b']);
      expect(collection.searchTextSync(1, 'missing'), isEmpty);
    });

    test('finds Chinese text with bigrams', () {
      collection.createTextIndex(1, tokenizer: const NgramTokenizer(2));
      collection.putSync(k('a'), doc('今天下午三点开会'));
      collection.putSync(k('b'), doc('明天上午讨论方案'));

      expect(keysOf(collection.searchTextSync(1, '开会')), <String>['a']);
      expect(keysOf(collection.searchTextSync(1, '明天')), <String>['b']);
      // "any" matches either shared bigram; "all" requires every query bigram.
      expect(
        keysOf(collection.searchTextSync(1, '开会讨论')),
        <String>['a', 'b'],
      );
      expect(
        collection.searchTextSync(1, '开会讨论', mode: TextQueryMode.all),
        isEmpty,
      );
    });

    test('maintains postings on update and delete', () {
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('alpha beta'));
      expect(keysOf(collection.searchTextSync(1, 'beta')), <String>['a']);

      collection.putSync(k('a'), doc('alpha gamma'));
      expect(collection.searchTextSync(1, 'beta'), isEmpty);
      expect(keysOf(collection.searchTextSync(1, 'gamma')), <String>['a']);

      collection.deleteSync(k('a'));
      expect(collection.searchTextSync(1, 'gamma'), isEmpty);
    });

    test('and / or query modes', () {
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('alpha beta'));
      collection.putSync(k('b'), doc('alpha gamma'));

      expect(
        keysOf(collection.searchTextSync(1, 'alpha beta')),
        <String>['a', 'b'],
      );
      expect(
        keysOf(
          collection.searchTextSync(1, 'alpha beta', mode: TextQueryMode.all),
        ),
        <String>['a'],
      );
      expect(
        keysOf(
          collection.searchTextSync(1, 'beta gamma', mode: TextQueryMode.all),
        ),
        isEmpty,
      );
    });

    test('backfills existing documents', () {
      collection.putSync(k('a'), doc('legacy content'));
      collection.createTextIndex(1);
      expect(keysOf(collection.searchTextSync(1, 'legacy')), <String>['a']);
    });

    test('survives flush and reopen', () async {
      collection.createTextIndex(1);
      collection.putSync(k('a'), doc('persistent text'));
      db.flushSync();
      await db.close();

      db = VelxoDatabase.openSync(root.path);
      collection = db.collection('notes');
      expect(collection.textIndexes.containsKey(1), isTrue);
      expect(
        keysOf(collection.searchTextSync(1, 'persistent')),
        <String>['a'],
      );
    });

    test('limit stops early and results are key-ordered', () {
      collection.createTextIndex(1);
      for (var i = 0; i < 5; i++) {
        collection.putSync(k('k$i'), doc('shared term'));
      }
      final limited = collection.searchTextSync(1, 'shared', limit: 2);
      expect(limited, hasLength(2));
      expect(keysOf(collection.searchTextSync(1, 'shared')),
          <String>['k0', 'k1', 'k2', 'k3', 'k4']);
    });

    test('rejects searching an unindexed field', () {
      expect(
        () => collection.searchTextSync(9, 'x'),
        throwsA(isA<VelxoNotFoundException>()),
      );
    });
  });
}
