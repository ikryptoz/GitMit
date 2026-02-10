import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gitmit/rtdb.dart';

class AppNotifications {
  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

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
        final key = _tokenKey(token);
        await rtdb().ref('fcmTokens/${user.uid}/$key').set({
          'token': token,
          'platform': Platform.operatingSystem,
          'updatedAt': ServerValue.timestamp,
        });
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        if (newToken.isEmpty) return;
        final key = _tokenKey(newToken);
        await rtdb().ref('fcmTokens/${user.uid}/$key').set({
          'token': newToken,
          'platform': Platform.operatingSystem,
          'updatedAt': ServerValue.timestamp,
        });
      });
    } catch (_) {
      // Ignore token errors; app should still work.
    }
  }
}
