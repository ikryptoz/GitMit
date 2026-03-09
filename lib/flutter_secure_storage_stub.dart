// Web fallback for flutter_secure_storage.
// Uses browser localStorage so E2EE keys/fingerprints can persist per web device.
import 'dart:html' as html;

class FlutterSecureStorage {
  static const String _prefix = 'gitmit.secure.';

  String? _wrap(String? key) {
    final k = (key ?? '').trim();
    if (k.isEmpty) return null;
    return '$_prefix$k';
  }

  Future<String?> read({String? key}) async {
    final k = _wrap(key);
    if (k == null) return null;
    return html.window.localStorage[k];
  }

  Future<void> write({String? key, String? value}) async {
    final k = _wrap(key);
    if (k == null) return;
    if (value == null) {
      html.window.localStorage.remove(k);
      return;
    }
    html.window.localStorage[k] = value;
  }

  Future<void> delete({String? key}) async {
    final k = _wrap(key);
    if (k == null) return;
    html.window.localStorage.remove(k);
  }

  Future<void> deleteAll() async {
    final keys = html.window.localStorage.keys
        .where((k) => k.startsWith(_prefix))
        .toList(growable: false);
    for (final key in keys) {
      html.window.localStorage.remove(key);
    }
  }

  Future<Map<String, String>> readAll() async {
    final out = <String, String>{};
    for (final key in html.window.localStorage.keys) {
      if (!key.startsWith(_prefix)) continue;
      final raw = html.window.localStorage[key];
      if (raw == null) continue;
      out[key.substring(_prefix.length)] = raw;
    }
    return out;
  }
}
