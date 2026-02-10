import 'dart:math';

import 'package:flutter/foundation.dart';

class ParsedGroupInvite {
  const ParsedGroupInvite(this.groupId, this.code);

  final String groupId;
  final String code;
}

String generateInviteCode({int length = 12}) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rnd = Random.secure();
  return String.fromCharCodes(
    Iterable.generate(length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
  );
}

String buildGroupInviteLink({required String groupId, required String code}) {
  return 'gitmit://join?g=$groupId&c=$code';
}

/// QR payload optimized for scanning by the system camera on Android.
///
/// - If the app is installed, Android resolves the intent and opens GitMit.
/// - If not installed, the scanner/browser can fall back to Play Store.
///
/// On iOS (and other platforms), returns the plain `gitmit://` link.
String buildGroupInviteQrPayload({required String groupId, required String code}) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    // Keep this in sync with android/app/build.gradle.kts -> applicationId.
    const androidPackage = 'com.nothix.gitmit';
    final fallback = 'https://play.google.com/store/apps/details?id=$androidPackage';
    return 'intent://join?g=$groupId&c=$code'
        '#Intent;scheme=gitmit;package=$androidPackage;'
        'S.browser_fallback_url=${Uri.encodeComponent(fallback)};end';
  }
  return buildGroupInviteLink(groupId: groupId, code: code);
}

ParsedGroupInvite? parseGroupInvite(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  final uri = Uri.tryParse(s);
  if (uri != null) {
    final qp = uri.queryParameters;
    final g = (qp['g'] ?? qp['groupId'] ?? '').trim();
    final c = (qp['c'] ?? qp['code'] ?? '').trim();
    if (g.isNotEmpty && c.isNotEmpty) return ParsedGroupInvite(g, c);
  }

  // Accept a compact format for manual paste, e.g. groupId~code
  final m = RegExp(r'^([A-Za-z0-9_-]{6,})[~:|]([A-Za-z0-9]{6,})$').firstMatch(s);
  if (m != null) {
    return ParsedGroupInvite(m.group(1)!, m.group(2)!);
  }
  return null;
}
