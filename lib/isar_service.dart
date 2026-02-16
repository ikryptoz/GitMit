import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'message.dart';

late final Isar isar;

Future<void> initIsar() async {
  final dir = await getApplicationDocumentsDirectory();
  isar = await Isar.open(
    [MessageSchema],
    directory: dir.path,
  );
}
