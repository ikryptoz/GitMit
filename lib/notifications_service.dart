import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitmit/rtdb.dart';

class AppNotifications {
  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const String _onlineNotifyBackendUrl = String.fromEnvironment('GITMIT_NOTIFY_BACKEND_URL', defaultValue: '');
  static const String _onlineNotifyBackendToken = String.fromEnvironment('GITMIT_NOTIFY_BACKEND_TOKEN', defaultValue: '');

  static const _storage = FlutterSecureStorage();
  static const _fcmLastTokenPrefix = 'fcm_last_token_v1_';

  static StreamSubscription<DatabaseEvent>? _settingsSub;
  static bool _notificationsEnabled = true;
  static bool _vibrationEnabled = true;
  static bool _soundsEnabled = true;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'messages',
    'Zprávy',
    description: 'Upozornění na nové zprávy',
    importance: Importance.high,
  );

  static String _tokenKey(String token) {
    // RTDB key-safe encoding.
    return base64Url.encode(utf8.encode(token));
  }

  static Future<String?> _readLastToken(String uid) async {
    try {
      return _storage.read(key: '$_fcmLastTokenPrefix$uid');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeLastToken(String uid, String token) async {
    try {
      await _storage.write(key: '$_fcmLastTokenPrefix$uid', value: token);
    } catch (_) {
      // ignore
    }
  }

  static Future<void> _storeTokenForUser(String uid, String token) async {
    final prev = await _readLastToken(uid);
    if (prev != null && prev.isNotEmpty && prev != token) {
      final prevKey = _tokenKey(prev);
      await rtdb().ref('fcmTokens/$uid/$prevKey').remove();
    }

    final key = _tokenKey(token);
    await rtdb().ref('fcmTokens/$uid/$key').set({
      'token': token,
      'platform': Platform.operatingSystem,
      'updatedAt': ServerValue.timestamp,
    });
    await _writeLastToken(uid, token);
  }

  static Future<void> initialize() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);

    await _local.initialize(initSettings);

    if (Platform.isAndroid) {
      final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_channel);
    }

    // Ask permissions (iOS + Android 13+).
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((message) async {
      if (!_notificationsEnabled) return;

      final title = message.notification?.title ?? 'GitMit';
      final body = message.notification?.body ?? '';
      if (body.trim().isEmpty) return;

      final androidDetails = AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.max,
        priority: Priority.high,
        playSound: _soundsEnabled,
        enableVibration: _vibrationEnabled,
      );

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: _soundsEnabled,
      );

      final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _local.show(DateTime.now().millisecondsSinceEpoch ~/ 1000, title, body, details);
    });

    _initialized = true;
  }

  static Future<void> setUser(User? user) async {
    await _settingsSub?.cancel();
    _settingsSub = null;

    if (user == null) return;

    // Keep prefs updated from RTDB settings.
    final settingsRef = rtdb().ref('settings/${user.uid}');
    _settingsSub = settingsRef.onValue.listen((event) {
      final v = event.snapshot.value;
      final m = (v is Map) ? v : null;
      _notificationsEnabled = m?['notificationsEnabled'] != false;
      _vibrationEnabled = m?['vibrationEnabled'] != false;
      _soundsEnabled = m?['soundsEnabled'] != false;
    });

    // Store token(s) for server-side sending (Cloud Functions, etc.).
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await _storeTokenForUser(user.uid, token);
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        if (newToken.isEmpty) return;
        await _storeTokenForUser(user.uid, newToken);
      });
    } catch (_) {
      // Ignore token errors; app should still work.
    }
  }

  static Future<bool> notifyOnlinePresence({
    required String toUid,
    required String fromUid,
    required String fromLogin,
  }) async {
    final baseUrl = _onlineNotifyBackendUrl.trim();
    if (baseUrl.isEmpty) {
      if (!kReleaseMode) {
        debugPrint('[NotifyOnline] Missing GITMIT_NOTIFY_BACKEND_URL. Notification skipped.');
      }
      return false;
    }

    final uri = Uri.parse(baseUrl.endsWith('/') ? '${baseUrl}notify-online' : '$baseUrl/notify-online');

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_onlineNotifyBackendToken.trim().isNotEmpty) {
      headers['x-api-key'] = _onlineNotifyBackendToken.trim();
    }

    try {
      final res = await http
          .post(
        uri,
        headers: headers,
        body: jsonEncode({
          'toUid': toUid,
          'fromUid': fromUid,
          'fromLogin': fromLogin,
        }),
      )
          .timeout(const Duration(seconds: 8));
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      if (!ok && !kReleaseMode) {
        debugPrint('[NotifyOnline] Backend ${res.statusCode}: ${res.body}');
      }
      return ok;
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('[NotifyOnline] Request failed: $e');
      }
      // best-effort
      return false;
    }
  }
}
