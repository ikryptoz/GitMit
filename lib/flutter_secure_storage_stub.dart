// Stub for flutter_secure_storage on web
class FlutterSecureStorage {
  Future<String?> read({String? key}) async => null;
  Future<void> write({String? key, String? value}) async {}
  Future<void> delete({String? key}) async {}
  Future<void> deleteAll() async {}
  Future<Map<String, String>> readAll() async => <String, String>{};
}
