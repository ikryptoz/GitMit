import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:gitmit/join_group_via_link_qr_page.dart';

class DeepLinks {
  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static String? _pendingJoinRaw;

  static Future<void> initialize() async {
    _pendingJoinRaw = null;

    // Handle cold-start link.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleUri(initial);
    } catch (_) {
      // ignore
    }

    // Handle links while running.
    _sub = _appLinks.uriLinkStream.listen(
      (uri) => _handleUri(uri),
      onError: (_) {},
    );
  }

  static void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  static void _handleUri(Uri uri) {
    if (uri.scheme != 'gitmit') return;

    // Expected: gitmit://join?g=...&c=...
    final isJoin = uri.host == 'join' || uri.path == '/join' || uri.path == 'join';
    if (!isJoin) return;

    _pendingJoinRaw = uri.toString();
    _maybeNavigateToJoin();
  }

  static void onAuthChanged(User? user) {
    if (user == null) return;
    _maybeNavigateToJoin();
  }

  static void _maybeNavigateToJoin() {
    final raw = _pendingJoinRaw;
    if (raw == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final nav = navigatorKey.currentState;
    if (nav == null) return;

    _pendingJoinRaw = null;
    nav.push(
      MaterialPageRoute(
        builder: (_) => JoinGroupViaLinkQrPage(initialRaw: raw, autoJoin: true),
      ),
    );
  }
}
