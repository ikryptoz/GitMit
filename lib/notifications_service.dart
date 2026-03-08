import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// ignore: uri_does_not_exist
import 'flutter_secure_storage_stub.dart' if (dart.library.io) 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitmit/rtdb.dart';

class AppNotifications {
  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const String _onlineNotifyBackendUrl = String.fromEnvironment(
    'GITMIT_NOTIFY_BACKEND_URL',
    defaultValue: 'https://us-central1-githubmessenger-7d2c6.cloudfunctions.net/notifyOnlinePresence',
  );
  static const String _onlineNotifyBackendToken = String.fromEnvironment('GITMIT_NOTIFY_BACKEND_TOKEN', defaultValue: '');
  static const String _webPushVapidKey = String.fromEnvironment('GITMIT_WEB_PUSH_VAPID_KEY', defaultValue: '');

  static final _storage = FlutterSecureStorage();
  static const _fcmLastTokenPrefix = 'fcm_last_token_v1_';

  static StreamSubscription<DatabaseEvent>? _settingsSub;
  static bool _notificationsEnabled = true;
  static bool _vibrationEnabled = true;
  static bool _soundsEnabled = true;
  static Map<String, String>? _pendingOpenTarget;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'New message notifications',
    importance: Importance.high,
  );

  static void _captureOpenTargetFromRemoteMessage(RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] ?? '').toString().trim();
    if (type == 'dm_message') {
      final chatLogin = (data['chatLogin'] ?? data['fromLogin'] ?? '')
          .toString()
          .trim();
      if (chatLogin.isEmpty) return;
      _pendingOpenTarget = {
        'type': 'dm',
        'chatLogin': chatLogin,
      };
      return;
    }

    if (type == 'group_message') {
      final groupId = (data['groupId'] ?? '').toString().trim();
      if (groupId.isEmpty) return;
      _pendingOpenTarget = {
        'type': 'group',
        'groupId': groupId,
      };
    }
  }

  static Map<String, String>? consumePendingOpenTarget() {
    final target = _pendingOpenTarget;
    _pendingOpenTarget = null;
    return target;
  }

  static Future<void> _showLocalNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized || !_notificationsEnabled) return;

    final cleanTitle = title.trim().isEmpty ? 'GitMit' : title.trim();
    final cleanBody = body.trim();
    if (cleanBody.isEmpty) return;

    if (kIsWeb) {
      if (!kReleaseMode) {
        debugPrint('[NotifyOnline][Web] $cleanTitle: $cleanBody');
      }
      return;
    }

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
    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: cleanTitle,
      body: cleanBody,
      notificationDetails: details,
      payload: payload,
    );
  }

  static void _captureOpenTargetFromLocalPayload(String? payload) {
    final raw = (payload ?? '').trim();
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final m = Map<String, dynamic>.from(decoded);
      final type = (m['type'] ?? '').toString().trim();
      if (type == 'dm') {
        final chatLogin = (m['chatLogin'] ?? '').toString().trim();
        if (chatLogin.isEmpty) return;
        _pendingOpenTarget = {
          'type': 'dm',
          'chatLogin': chatLogin,
        };
        return;
      }
      if (type == 'group') {
        final groupId = (m['groupId'] ?? '').toString().trim();
        if (groupId.isEmpty) return;
        _pendingOpenTarget = {
          'type': 'group',
          'groupId': groupId,
        };
      }
    } catch (_) {
      // ignore
    }
  }

  static Future<void> showIncomingMessageNotification({
    required String sender,
    required String preview,
    String title = 'GitMit',
    Map<String, String>? openTarget,
  }) async {
    final senderText = sender.trim();
    final previewText = preview.trim();
    final body = senderText.isEmpty ? previewText : '$senderText: $previewText';
    await _showLocalNotification(
      title: title,
      body: body,
      payload: (openTarget == null || openTarget.isEmpty)
          ? null
          : jsonEncode(openTarget),
    );
  }

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
      'platform': kIsWeb ? 'web' : Platform.operatingSystem,
      'updatedAt': ServerValue.timestamp,
    });
    await _writeLastToken(uid, token);
  }

  static Future<void> initialize() async {
    if (_initialized) return;

    if (!kIsWeb) {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings();
      const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);

      await _local.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (response) {
          _captureOpenTargetFromLocalPayload(response.payload);
        },
      );

      if (Platform.isAndroid) {
        final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        await android?.createNotificationChannel(_channel);
        await android?.requestNotificationsPermission();
      }
    }

    // Ask permissions (iOS + Android 13+).
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((message) async {
      if (!_notificationsEnabled) return;

      final pushType = (message.data['type'] ?? '').toString().trim();
      if (pushType == 'dm_message' || pushType == 'group_message') {
        // Chat push should be visible only when app is background/terminated.
        return;
      }

      final title = message.notification?.title ?? 'GitMit';
      final body = message.notification?.body ?? '';
      await _showLocalNotification(title: title, body: body);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _captureOpenTargetFromRemoteMessage(message);
    });

    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        _captureOpenTargetFromRemoteMessage(initial);
      }
    } catch (_) {
      // ignore
    }

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
      final token = kIsWeb
          ? await FirebaseMessaging.instance.getToken(
              vapidKey: _webPushVapidKey.trim().isEmpty ? null : _webPushVapidKey.trim(),
            )
          : await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await _storeTokenForUser(user.uid, token);
      } else if (kIsWeb && !kReleaseMode) {
        debugPrint('[NotifyOnline][Web] FCM token is empty. Set --dart-define=GITMIT_WEB_PUSH_VAPID_KEY=...');
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

  static Future<void> sendLoginNotification(String userId, String userName) async {
    try {
      final response = await http.post(
        Uri.parse(_onlineNotifyBackendUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_onlineNotifyBackendToken',
        },
        body: jsonEncode({
          'userId': userId,
          'userName': userName,
          'event': 'login',
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('Login notification sent successfully.');
      } else {
        debugPrint('Failed to send login notification: \\${response.statusCode} - \\${response.body}');
      }
    } catch (e) {
      debugPrint('Error sending login notification: \\${e.toString()}');
    }
  }
}
