import 'package:isar/isar.dart';

part 'message.g.dart';

@collection
class Message {
  Id id = Isar.autoIncrement;

  late String chatId;
  late String senderId;
  late String content;
  late int timestamp;
  late bool isEncrypted;
  // Add more fields as needed (attachments, status, etc)
}
