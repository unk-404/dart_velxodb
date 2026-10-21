import 'package:isar_community/isar.dart';

part 'model.g.dart';

@collection
class Doc {
  Id id = 0;

  @Index()
  late String sender;

  late int createdAt;
  late String body;
}
