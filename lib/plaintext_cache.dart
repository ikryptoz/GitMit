import 'dart:async';

import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

class PlaintextCache {
  ///
  /// ===============================
  ///  DOKUMENTACE: Šifrování v GitMit
  /// ===============================
  ///
  /// - Všechny privátní zprávy (DM i skupiny) jsou šifrované end-to-end (E2EE) pomocí X25519/Ed25519 a ChaCha20-Poly1305.
  /// - Každý uživatel má unikátní klíčovou identitu (X25519/Ed25519), která je vázaná na jeho Firebase UID.
  /// - Při navázání komunikace se vymění veřejné klíče a vygeneruje se session (double ratchet, Signal-like).
  /// - Každá zpráva má unikátní šifrovací klíč (forward secrecy, perfect forward secrecy).
  /// - Skupiny používají buď sdílený group key (v1), nebo Signal Sender Keys (v2, pokud všichni podporují).
  /// - Klíče a sessiony jsou uloženy v zabezpečeném úložišti na zařízení (flutter_secure_storage).
  /// - Fingerprint klíče je hash veřejného podpisového klíče (Ed25519), zobrazovaný v UI pro ověření identity.
  /// - Pokud se fingerprinty shodují, je to podezřelé (viz varování v UI).
  /// - Vyhledávání v chatu funguje pouze nad dešifrovaným obsahem (plaintext cache), nikdy nad ciphertextem.
  /// - PlaintextCache ukládá dešifrované zprávy pouze lokálně, nikdy se neodesílají na server.
  ///
  /// Pro detailní popis protokolu viz README nebo kontaktuj vývojáře.
  ///
  static bool _initialized = false;
  static String? _activeUid;
  static Box<String>? _box;

  static final Map<String, String> _pending = {};
  static Timer? _flushTimer;

  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _initialized = true;
  }

  static Future<void> setActiveUser(String? uid) async {
    await init();

    if (_activeUid == uid) return;

    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();

    if (_box != null) {
      try {
        await _box!.close();
      } catch (_) {
        // ignore
      }
      _box = null;
    }

    _activeUid = uid;

    if (uid == null || uid.trim().isEmpty) {
      return;
    }

    final safe = uid.trim();
    _box = await Hive.openBox<String>('ptcache_$safe');
  }

  static String _dmKey({required String otherLoginLower, required String messageKey}) {
    return 'dm:$otherLoginLower:$messageKey';
  }

  static String _groupKey({required String groupId, required String messageKey}) {
    return 'g:$groupId:$messageKey';
  }

  static String? tryGetDm({required String otherLoginLower, required String messageKey}) {
    final box = _box;
    if (box == null) return null;
    return box.get(_dmKey(otherLoginLower: otherLoginLower, messageKey: messageKey));
  }

  static String? tryGetGroup({required String groupId, required String messageKey}) {
    final box = _box;
    if (box == null) return null;
    return box.get(_groupKey(groupId: groupId, messageKey: messageKey));
  }

  static void putDm({required String otherLoginLower, required String messageKey, required String plaintext}) {
    final p = plaintext;
    if (p.isEmpty) return;
    _enqueue(_dmKey(otherLoginLower: otherLoginLower, messageKey: messageKey), p);
  }

  static void putGroup({required String groupId, required String messageKey, required String plaintext}) {
    final p = plaintext;
    if (p.isEmpty) return;
    _enqueue(_groupKey(groupId: groupId, messageKey: messageKey), p);
  }

  static void _enqueue(String key, String value) {
    if (_box == null) return;

    _pending[key] = value;
    _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _flushTimer = null;
      _flush();
    });
  }

  static Future<void> _flush() async {
    final box = _box;
    if (box == null) return;
    if (_pending.isEmpty) return;

    final batch = Map<String, String>.from(_pending);
    _pending.clear();

    try {
      await box.putAll(batch);
    } catch (_) {
      // ignore
    }
  }

  static Future<void> clearForActiveUser() async {
    final box = _box;
    if (box == null) return;

    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();

    try {
      await box.clear();
    } catch (_) {
      // ignore
    }
  }
}
