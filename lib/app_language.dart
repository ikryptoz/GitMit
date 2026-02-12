import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:gitmit/rtdb.dart';

class AppLanguage {
  static final ValueNotifier<String> code = ValueNotifier<String>('cs');
  static StreamSubscription<DatabaseEvent>? _sub;
  static String? _uid;

  static Locale get locale => Locale(code.value == 'en' ? 'en' : 'cs');

  static bool isEnglish(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'en';

  static String tr(BuildContext context, String cs, String en) {
    return isEnglish(context) ? en : cs;
  }

  static void setLanguage(String value) {
    final normalized = value.trim().toLowerCase();
    code.value = normalized == 'en' ? 'en' : 'cs';
  }

  static Future<void> bindUser(String? uid) async {
    final cleanUid = (uid ?? '').trim();
    if (_uid == cleanUid) return;

    await _sub?.cancel();
    _sub = null;
    _uid = cleanUid.isEmpty ? null : cleanUid;

    if (_uid == null) {
      setLanguage('cs');
      return;
    }

    final ref = rtdb().ref('settings/${_uid!}/language');

    try {
      final snap = await ref.get();
      final v = snap.value?.toString() ?? 'cs';
      setLanguage(v);
    } catch (_) {
      setLanguage('cs');
    }

    _sub = ref.onValue.listen((event) {
      final v = event.snapshot.value?.toString() ?? 'cs';
      setLanguage(v);
    });
  }

  static Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _uid = null;
  }
}
