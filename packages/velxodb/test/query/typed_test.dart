@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';
import 'package:velxodb/velxodb.dart';

import 'generated/chat_message.g.dart';

void main() {
  late Directory root;
  late VelxoDatabase db;
  late TypedCollection<ChatMessage> messages;

  setUp(() {
    root = Directory.systemTemp.createTempSync('velxo_typed_');
    db = VelxoDatabase.openSync(root.path);
    messages = ChatMessage.open(db);
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ChatMessage message({
    required String id,
    String conversation = 'c1',
    String sender = 'u1',
    int createdAt = 100,
    String body = 'hello',
    bool? edited,
  }) => ChatMessage(
    id: id,
    conversationId: conversation,
    senderId: sender,
    createdAt: createdAt,
    body: body,
    edited: edited,
  );

  group('generated model', () {
    test('round trips through the typed collection', () {
      final value = message(id: 'm1', body: '在吗？');
      messages.putSync(ChatMessage.keyOf(value), value);

      final loaded = messages.getSync(ChatMessage.keyOf(value))!;
      expect(loaded.id, 'm1');
      expect(loaded.body, '在吗？');
      expect(loaded.createdAt, 100);
      expect(loaded.edited, isNull);
    });

    test('declares indexes from the spec', () {
      expect(messages.collection.indexes.keys, containsAll(<int>[2, 3, 4]));
      expect(messages.collection.indexes[2]?.type, VxsType.string);
      expect(messages.collection.indexes[4]?.type, VxsType.int64);
    });

    test('finds by an indexed field through the planner', () {
      for (var i = 0; i < 5; i++) {
        messages.putSync(
          ChatMessage.keyOf(message(id: 'm$i')),
          message(id: 'm$i', sender: i.isEven ? 'u1' : 'u2', createdAt: i * 10),
        );
      }
      final query = Query(where: Predicate.eq(3, 'u1'));
      expect(messages.collection.explainSync(query), 'index:eq field=3');
      expect(
        messages.findSync(query).map((m) => m.id).toSet(),
        <String>{'m0', 'm2', 'm4'},
      );
    });

    test('finds by an indexed range', () {
      for (var i = 0; i < 5; i++) {
        messages.putSync(
          ChatMessage.keyOf(message(id: 'm$i')),
          message(id: 'm$i', createdAt: i * 10),
        );
      }
      final found = messages.findSync(
        Query(where: Predicate.between(4, from: 10, to: 30)),
      );
      expect(found.map((m) => m.id).toList(), <String>['m1', 'm2']);
    });

    test('nullable fields are omitted and decoded as null', () {
      final edited = message(id: 'm1', edited: true);
      messages.putSync(ChatMessage.keyOf(edited), edited);
      expect(messages.getSync(ChatMessage.keyOf(edited))!.edited, isTrue);

      final plain = message(id: 'm2');
      messages.putSync(ChatMessage.keyOf(plain), plain);
      expect(messages.getSync(ChatMessage.keyOf(plain))!.edited, isNull);
    });

    test('survives a flush and reopen', () async {
      messages.putSync(ChatMessage.keyOf(message(id: 'm1')), message(id: 'm1'));
      db.flushSync();
      await db.close();

      db = VelxoDatabase.openSync(root.path);
      messages = ChatMessage.open(db);
      expect(messages.getSync(ChatMessage.keyOf(message(id: 'm1')))?.id, 'm1');
      expect(messages.collection.indexes.keys, containsAll(<int>[2, 3, 4]));
    });
  });
}
