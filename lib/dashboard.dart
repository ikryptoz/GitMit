import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/services.dart';
import 'package:gitmit/e2ee.dart';
import 'package:gitmit/app_language.dart';
import 'package:gitmit/group_invites.dart';
import 'package:gitmit/github_api.dart';
import 'package:gitmit/join_group_via_link_qr_page.dart';
import 'package:gitmit/plaintext_cache.dart';
import 'package:gitmit/rtdb.dart';
import 'package:gitmit/data_usage.dart';
import 'package:gitmit/notifications_service.dart';
import 'package:image_editor_plus/image_editor_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' as highlight;
import 'package:http/http.dart' as http;

const String _githubDmFallbackUrl = String.fromEnvironment(
  'GITMIT_GITHUB_NOTIFY_URL',
  defaultValue: 'https://us-central1-githubmessenger-7d2c6.cloudfunctions.net/notifyOnlinePresence',
);
const String _githubDmFallbackTokenPrimary = String.fromEnvironment('GITMIT_GITHUB_NOTIFY_TOKEN', defaultValue: '');
const String _githubDmFallbackTokenCompat = String.fromEnvironment('GITMIT_NOTIFY_BACKEND_TOKEN', defaultValue: '');
String get _githubDmFallbackToken =>
    _githubDmFallbackTokenPrimary.trim().isNotEmpty ? _githubDmFallbackTokenPrimary : _githubDmFallbackTokenCompat;

class _InviteSendResult {
  const _InviteSendResult({required this.ok, this.error, this.manualFallbackUsed = false});

  final bool ok;
  final String? error;
  final bool manualFallbackUsed;
}

Uri _manualGithubInviteUri({
  required String targetLogin,
  required String fromLogin,
  required String preview,
}) {
  final repoFull = const String.fromEnvironment(
    'GITMIT_GITHUB_NOTIFY_REPO',
    defaultValue: 'ikryptoz/GitMit',
  ).trim();
  final appUrl = const String.fromEnvironment(
    'GITMIT_APP_URL',
    defaultValue: 'https://github.com/ikryptoz/GitMit',
  ).trim();

  final safeRepo = repoFull.contains('/') ? repoFull : 'ikryptoz/GitMit';
  final body = [
    '@$targetLogin',
    'You have a new GitMit invite from @$fromLogin.',
    preview.trim().isNotEmpty ? preview.trim() : 'Please install GitMit to continue the conversation.',
    if (appUrl.isNotEmpty) 'Download GitMit: $appUrl',
  ].join('\n\n');

  return Uri.https(
    'github.com',
    '/$safeRepo/issues/new',
    {
      'title': 'GitMit invite for @$targetLogin',
      'body': body,
    },
  );
}

Future<bool> _openManualGithubInvite({
  required String targetLogin,
  required String fromLogin,
  required String preview,
}) async {
  final uri = _manualGithubInviteUri(
    targetLogin: targetLogin,
    fromLogin: fromLogin,
    preview: preview,
  );
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return true;
  }
  return false;
}

String _inviteErrorFromHttp({required int statusCode, required Uri uri, required String body}) {
  final compactBody = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  final shortBody = compactBody.length > 220 ? '${compactBody.substring(0, 220)}…' : compactBody;

  if (statusCode == 401) {
    return '401 Unauthorized – zkontroluj BACKEND_API_KEY / GITMIT_NOTIFY_BACKEND_TOKEN.';
  }
  if (statusCode == 404) {
    return '404 Not Found – endpoint/funkce není dostupná: $uri (zkus `firebase deploy --only functions` ve správném projektu).';
  }
  if (statusCode >= 500) {
    return 'Server error $statusCode – $shortBody';
  }
  return 'HTTP $statusCode – $shortBody';
}

List<Uri> _inviteBackendUris(String endpoint) {
  final raw = endpoint.trim();
  if (raw.isEmpty) return const <Uri>[];

  Uri? parsed;
  try {
    parsed = Uri.parse(raw);
  } catch (_) {
    return const <Uri>[];
  }

  final candidates = <String>{raw};
  final path = parsed.path;
  final looksLikeFunctionsHost = parsed.host.contains('cloudfunctions.net');

  final origin = '${parsed.scheme}://${parsed.host}';
  final normalizedPath = path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  String basePath = normalizedPath;
  const knownSuffixes = <String>[
    '/notifyOnlinePresence',
    '/notify-online',
    '/api/notifyOnlinePresence',
    '/api/notify-online',
  ];
  for (final suffix in knownSuffixes) {
    if (basePath.endsWith(suffix)) {
      basePath = basePath.substring(0, basePath.length - suffix.length);
      break;
    }
  }

  final base = '$origin$basePath';
  final baseWithSlash = base.endsWith('/') ? base : '$base/';

  candidates.add('${baseWithSlash}notifyOnlinePresence');
  candidates.add('${baseWithSlash}notify-online');
  candidates.add('${baseWithSlash}api/notifyOnlinePresence');
  candidates.add('${baseWithSlash}api/notify-online');

  if (looksLikeFunctionsHost) {
    candidates.add('$origin/notifyOnlinePresence');
    candidates.add('$origin/notify-online');
  }

  final uris = <Uri>[];
  for (final candidate in candidates) {
    try {
      uris.add(Uri.parse(candidate));
    } catch (_) {
      // ignore invalid candidate
    }
  }
  return uris;
}

Future<String> _uploadGroupLogo({required String groupId, required Uint8List bytes}) async {
  String normalizeBucket(String b) {
    var bucket = b.trim();
    if (bucket.startsWith('gs://')) bucket = bucket.substring(5);
    return bucket;
  }

  final configured = normalizeBucket(Firebase.app().options.storageBucket ?? '');
  final candidates = <String>[];
  if (configured.isNotEmpty) candidates.add(configured);

  if (configured.endsWith('.firebasestorage.app')) {
    candidates.add(configured.replaceAll('.firebasestorage.app', '.appspot.com'));
  } else if (configured.endsWith('.appspot.com')) {
    candidates.add(configured.replaceAll('.appspot.com', '.firebasestorage.app'));
  }

  if (candidates.isEmpty) candidates.add('');

  FirebaseException? lastFirebaseError;
  Object? lastError;

  for (final bucket in candidates.toSet()) {
    try {
      final storage = bucket.isEmpty
          ? FirebaseStorage.instance
          : FirebaseStorage.instanceFor(bucket: bucket.startsWith('gs://') ? bucket : 'gs://$bucket');

      final ref = storage.ref().child('groupLogos').child('$groupId.jpg');
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      await DataUsageTracker.recordUpload(bytes.length, category: 'media');

      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          return await ref.getDownloadURL();
        } on FirebaseException catch (e) {
          lastFirebaseError = e;
          if (e.code != 'object-not-found' || attempt == 4) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
      }
    } on FirebaseException catch (e) {
      lastFirebaseError = e;
      continue;
    } catch (e) {
      lastError = e;
      continue;
    }
  }

  if (lastFirebaseError != null) throw lastFirebaseError;
  throw Exception('Logo upload failed: ${lastError ?? 'unknown error'}');
}

class _AttachmentPayload {
  const _AttachmentPayload({
    required this.type,
    required this.path,
    required this.nonceB64,
    required this.keyB64,
    required this.size,
    required this.mime,
    required this.ext,
  });

  final String type;
  final String path;
  final String nonceB64;
  final String keyB64;
  final int size;
  final String mime;
  final String ext;

  Map<String, dynamic> toJson() => {
        'type': type,
        'path': path,
        'nonce': nonceB64,
        'key': keyB64,
        'size': size,
        'mime': mime,
        'ext': ext,
      };

  static _AttachmentPayload? tryParse(String text) {
    if (!text.trim().startsWith('{')) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      if ((m['type'] ?? '').toString() != 'image') return null;
      final path = (m['path'] ?? '').toString();
      final nonce = (m['nonce'] ?? '').toString();
      final key = (m['key'] ?? '').toString();
      final size = (m['size'] is int) ? m['size'] as int : int.tryParse((m['size'] ?? '').toString()) ?? 0;
      final mime = (m['mime'] ?? '').toString();
      final ext = (m['ext'] ?? '').toString();
      if (path.isEmpty || nonce.isEmpty || key.isEmpty || ext.isEmpty) return null;
      return _AttachmentPayload(
        type: 'image',
        path: path,
        nonceB64: nonce,
        keyB64: key,
        size: size,
        mime: mime.isEmpty ? 'image/jpeg' : mime,
        ext: ext,
      );
    } catch (_) {
      return null;
    }
  }
}

class _CodeMessagePayload {
  const _CodeMessagePayload({
    required this.title,
    required this.language,
    required this.code,
  });

  final String title;
  final String language;
  final String code;

  Map<String, dynamic> toJson() => {
        'type': 'code',
        'title': title,
        'language': language,
        'code': code,
      };

  String previewLabel() {
    final t = title.trim();
    final l = language.trim();
    if (t.isNotEmpty) return '<> kód ($t)';
    if (l.isNotEmpty) return '<> kód ($l)';
    return '<> kód';
  }

  static _CodeMessagePayload? tryParse(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      if ((m['type'] ?? '').toString() != 'code') return null;
      final code = (m['code'] ?? '').toString();
      if (code.trim().isEmpty) return null;
      final title = (m['title'] ?? '').toString();
      final language = (m['language'] ?? '').toString();
      return _CodeMessagePayload(title: title, language: language, code: code);
    } catch (_) {
      return null;
    }
  }
}

final _attachmentAead = Chacha20.poly1305Aead();
final _attachmentRng = Random.secure();

List<int> _randomBytes(int length) =>
    List<int>.generate(length, (_) => _attachmentRng.nextInt(256), growable: false);

String _b64(List<int> bytes) => base64UrlEncode(bytes);
List<int> _unb64(String s) => base64Url.decode(s);

String? _localDeviceIdCache;

Future<String> _getOrCreateLocalDeviceId() async {
  if (_localDeviceIdCache != null && _localDeviceIdCache!.isNotEmpty) {
    return _localDeviceIdCache!;
  }

  if (kIsWeb) {
    _localDeviceIdCache = 'web-default';
    return _localDeviceIdCache!;
  }

  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/.gitmit_device_id');
  if (await file.exists()) {
    final saved = (await file.readAsString()).trim();
    if (saved.isNotEmpty) {
      _localDeviceIdCache = saved;
      return saved;
    }
  }

  final randomBytes = _randomBytes(12);
  final id = randomBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  await file.writeAsString(id, flush: true);
  _localDeviceIdCache = id;
  return id;
}

String _devicePlatformLabel() {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return Platform.operatingSystem;
}

String _deviceNameLabel() {
  if (kIsWeb) return 'Web zařízení';
  if (Platform.isAndroid) return 'Android zařízení';
  if (Platform.isIOS) return 'iPhone / iPad';
  if (Platform.isMacOS) return 'Mac';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isLinux) return 'Linux';
  return 'Zařízení';
}

class _GitmitSyntaxHighlighter extends SyntaxHighlighter {
  _GitmitSyntaxHighlighter(this._baseStyle);

  final TextStyle _baseStyle;

  TextStyle _styleForClass(String? className) {
    final c = (className ?? '').toLowerCase();
    if (c.contains('keyword') || c.contains('built_in') || c.contains('builtin')) {
      return _baseStyle.copyWith(color: const Color(0xFFC792EA), fontWeight: FontWeight.w600);
    }
    if (c.contains('string')) {
      return _baseStyle.copyWith(color: const Color(0xFFC3E88D));
    }
    if (c.contains('number') || c.contains('literal')) {
      return _baseStyle.copyWith(color: const Color(0xFFF78C6C));
    }
    if (c.contains('comment')) {
      return _baseStyle.copyWith(color: const Color(0xFF8A9199), fontStyle: FontStyle.italic);
    }
    if (c.contains('type') || c.contains('class') || c.contains('title')) {
      return _baseStyle.copyWith(color: const Color(0xFF82AAFF));
    }
    if (c.contains('function')) {
      return _baseStyle.copyWith(color: const Color(0xFFFFCB6B));
    }
    if (c.contains('meta') || c.contains('attr')) {
      return _baseStyle.copyWith(color: const Color(0xFF89DDFF));
    }
    return _baseStyle;
  }

  TextSpan _convert(List<dynamic>? nodes, TextStyle style) {
    if (nodes == null || nodes.isEmpty) {
      return TextSpan(text: '', style: style);
    }

    return TextSpan(
      style: style,
      children: nodes.map<TextSpan>((dynamic node) {
        final nodeStyle = _styleForClass((node as dynamic).className?.toString());
        final value = (node as dynamic).value?.toString();
        if (value != null) {
          return TextSpan(text: value, style: nodeStyle);
        }
        final children = (node as dynamic).nodes as List<dynamic>?;
        return _convert(children, nodeStyle);
      }).toList(growable: false),
    );
  }

  @override
  TextSpan format(String source) {
    try {
      final parsed = highlight.highlight.parse(source);
      return _convert(parsed.nodes, _baseStyle);
    } catch (_) {
      return TextSpan(text: source, style: _baseStyle);
    }
  }
}

class _RichMessageText extends StatelessWidget {
  const _RichMessageText({
    required this.text,
    required this.fontSize,
    required this.textColor,
  });

  final String text;
  final double fontSize;
  final Color textColor;

  Future<void> _openExternal(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, color: textColor);
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      syntaxHighlighter: _GitmitSyntaxHighlighter(
        base.copyWith(fontFamily: 'monospace'),
      ),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: base,
        a: base.copyWith(
          color: Theme.of(context).colorScheme.secondary,
          decoration: TextDecoration.underline,
        ),
        code: base.copyWith(fontFamily: 'monospace', backgroundColor: Colors.white10),
        codeblockPadding: const EdgeInsets.all(10),
        codeblockDecoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        blockquote: base.copyWith(color: textColor.withOpacity(0.8)),
        listBullet: base,
      ),
      onTapLink: (text, href, title) {
        if (href != null && href.trim().isNotEmpty) {
          _openExternal(href);
        }
      },
    );
  }
}

Future<({List<int> cipher, String nonceB64, String keyB64})> _encryptAttachmentBytes(List<int> clearBytes) async {
  final key = _randomBytes(32);
  final nonce = _randomBytes(12);
  final box = await _attachmentAead.encrypt(
    clearBytes,
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  return (cipher: box.cipherText + box.mac.bytes, nonceB64: _b64(nonce), keyB64: _b64(key));
}

Future<List<int>> _decryptAttachmentBytes({
  required List<int> cipher,
  required String nonceB64,
  required String keyB64,
}) async {
  if (cipher.length < 16) return const [];
  final nonce = _unb64(nonceB64);
  final key = _unb64(keyB64);
  final macBytes = cipher.sublist(cipher.length - 16);
  final ct = cipher.sublist(0, cipher.length - 16);
  final box = SecretBox(ct, nonce: nonce, mac: Mac(macBytes));
  final clear = await _attachmentAead.decrypt(box, secretKey: SecretKey(key));
  return clear;
}

Future<String?> _myGithubUsernameFromRtdb(String myUid) async {
  final snap = await rtdb().ref('users/$myUid/githubUsername').get();
  final v = snap.value;
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

Future<String?> _lookupUidForLoginLower(String loginLower) async {
  final snap = await rtdb().ref('usernames/$loginLower').get();
  final v = snap.value;
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

Future<void> _sendDmRequestCore({
  required String myUid,
  required String myLogin,
  required String otherUid,
  required String otherLogin,
  String? myAvatarUrl,
  String? otherAvatarUrl,
  String? messageText,
}) async {
  final myLoginLower = myLogin.trim().toLowerCase();
  final otherLoginLower = otherLogin.trim().toLowerCase();
  if (myLoginLower.isEmpty || otherLoginLower.isEmpty) return;

  // Publish my public bundle before sending an invite, so the other side can
  // immediately fetch my keys/fingerprint and establish encrypted comms.
  try {
    await E2ee.publishMyPublicKey(uid: myUid);
  } catch (_) {
    // best-effort
  }

  Map<String, Object?>? encrypted;
  final pt = (messageText ?? '').trim();
  if (pt.isNotEmpty) {
    try {
      encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: pt);
    } catch (_) {
      encrypted = null;
    }
  }

  final updates = <String, Object?>{
    'dmRequests/$otherUid/$myLoginLower': {
      'fromUid': myUid,
      'fromLogin': myLogin,
      if (myAvatarUrl != null && myAvatarUrl.trim().isNotEmpty) 'fromAvatarUrl': myAvatarUrl.trim(),
      'createdAt': ServerValue.timestamp,
      if (encrypted != null) ...encrypted,
    },
    'savedChats/$myUid/$otherLogin': {
      'login': otherLogin,
      if (otherAvatarUrl != null && otherAvatarUrl.trim().isNotEmpty) 'avatarUrl': otherAvatarUrl.trim(),
      'status': 'pending_out',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    },
    'savedChats/$otherUid/$myLogin': {
      'login': myLogin,
      if (myAvatarUrl != null && myAvatarUrl.trim().isNotEmpty) 'avatarUrl': myAvatarUrl.trim(),
      'status': 'pending_in',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    },
  };

  await rtdb().ref().update(updates);
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}
    
class _UserProfilePage extends StatefulWidget {
  const _UserProfilePage({
    required this.login,
    required this.avatarUrl,
    this.githubDataFuture,
  });

  final String login;
  final String avatarUrl;
  final Future<Map<String, dynamic>?>? githubDataFuture;

  @override
  State<_UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<_UserProfilePage> {
  late final Future<Map<String, dynamic>?> _githubDataFuture;

  @override
  void initState() {
    super.initState();
    _githubDataFuture = widget.githubDataFuture ?? _fetchGithubProfileData(widget.login);
  }

  String _loginLower() => widget.login.trim().toLowerCase();

  List<String> _parseBadges(Object? raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList(growable: false);
    }
    if (raw is Map) {
      return raw.entries
          .where((e) => e.value == true || e.value == 1)
          .map((e) => e.key.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Future<_GitmitStats?> _loadGitmitStats(String uid) async {
    try {
      final savedSnap = await rtdb().ref('savedChats/$uid').get();
      final savedVal = savedSnap.value;
      final savedMap = (savedVal is Map) ? Map<String, dynamic>.from(savedVal) : <String, dynamic>{};
      final privateChats = savedMap.length;

      final groupsSnap = await rtdb().ref('groupMembers').get();
      final groupsVal = groupsSnap.value;
      var groups = 0;
      if (groupsVal is Map) {
        for (final entry in groupsVal.entries) {
          final members = entry.value;
          if (members is Map) {
            final mm = Map<String, dynamic>.from(members);
            final v = mm[uid];
            if (v is Map || v == true) {
              groups++;
            }
          }
        }
      }

      final msgsSnap = await rtdb().ref('messages/$uid').get();
      final msgsVal = msgsSnap.value;
      var sent = 0;
      if (msgsVal is Map) {
        for (final entry in msgsVal.entries) {
          final thread = entry.value;
          if (thread is! Map) continue;
          for (final msgEntry in thread.entries) {
            final msg = msgEntry.value;
            if (msg is! Map) continue;
            final fromUid = (msg['fromUid'] ?? '').toString();
            if (fromUid == uid) sent++;
          }
        }
      }

      return _GitmitStats(privateChats: privateChats, groups: groups, messagesSent: sent);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _myGithubUsername(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/githubUsername').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<String?> _myAvatarUrl(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/avatarUrl').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<String?> _lookupUidForLogin(String loginLower) async {
    final snap = await rtdb().ref('usernames/$loginLower').get();
    final v = snap.value;
    if (v == null) return null;
    return v.toString();
  }

  Future<void> _requestKeySharing({required String myUid, required String otherUid}) async {
    final myLogin = await _myGithubUsername(myUid);
    if (myLogin == null || myLogin.trim().isEmpty) {
      throw Exception('Nepodařilo se zjistit tvůj GitHub username.');
    }

    final myAvatar = await _myAvatarUrl(myUid);
    await _sendDmRequestCore(
      myUid: myUid,
      myLogin: myLogin,
      otherUid: otherUid,
      otherLogin: widget.login,
      myAvatarUrl: myAvatar,
      otherAvatarUrl: widget.avatarUrl,
      messageText: '🔐 Prosím povol sdílení E2EE klíče, ať se naváže šifrovaná komunikace.',
    );
  }

  Future<void> _toggleBlock({required String myUid, required bool currentlyBlocked}) async {
    final key = _loginLower();
    final ref = rtdb().ref('blocked/$myUid/$key');
    if (currentlyBlocked) {
      await ref.remove();
    } else {
      await ref.set(true);
    }
  }

  Future<void> _deleteChatForMe({required String myUid}) async {
    final login = widget.login;
    await rtdb().ref('messages/$myUid/$login').remove();
    await rtdb().ref('savedChats/$myUid/$login').remove();
  }

  Future<void> _deleteChatForBoth({required String myUid}) async {
    final otherUid = await _lookupUidForLogin(_loginLower());
    if (otherUid == null) {
      throw Exception('Uživatel nemá propojený účet v databázi.');
    }

    final myLogin = await _myGithubUsername(myUid);
    if (myLogin == null) {
      throw Exception('Nepodařilo se zjistit tvůj GitHub username.');
    }

    await _deleteChatForMe(myUid: myUid);
    await rtdb().ref('messages/$otherUid/$myLogin').remove();
    await rtdb().ref('savedChats/$otherUid/$myLogin').remove();
  }

  Future<void> _confirmAndRun({
    required String title,
    required String message,
    required Future<void> Function() action,
  }) async {
    final t = AppLanguage.tr;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t(context, 'Zrušit', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t(context, 'Pokračovat', 'Continue'))),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(context, 'Hotovo.', 'Done.'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t(context, 'Chyba', 'Error')}: $e')));
      }
    }
  }

  Future<void> _confirmAndRunThenPop({
    required String title,
    required String message,
    required Future<void> Function() action,
    required String popResult,
  }) async {
    final t = AppLanguage.tr;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t(context, 'Zrušit', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t(context, 'Pokračovat', 'Continue'))),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await action();
      if (mounted) {
        Navigator.of(context).pop(popResult);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t(context, 'Chyba', 'Error')}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return Scaffold(body: Center(child: Text(AppLanguage.tr(context, 'Nejsi přihlášen.', 'You are not signed in.'))));
    }

    final myUid = current.uid;
    final loginLower = _loginLower();
    final blockedRef = rtdb().ref('blocked/$myUid/$loginLower');
    final otherUidRef = rtdb().ref('usernames/$loginLower');
    final otherUserRef = rtdb().ref('users');

    return Scaffold(
      appBar: AppBar(title: Text('@${widget.login}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StreamBuilder<DatabaseEvent>(
            stream: otherUidRef.onValue,
            builder: (context, uidSnap) {
              final otherUid = uidSnap.data?.snapshot.value?.toString();
              final hasOtherUid = otherUid != null && otherUid.isNotEmpty;

              return FutureBuilder<Map<String, dynamic>?>
                  (
                future: _githubDataFuture,
                builder: (context, ghSnap) {
                  final gh = ghSnap.data;
                  final fetchedAvatar = gh?['avatarUrl'] as String?;
                  final topRepos = gh?['topRepos'] as List<Map<String, dynamic>>?;

                  final avatar = (widget.avatarUrl.trim().isNotEmpty)
                      ? widget.avatarUrl.trim()
                      : (fetchedAvatar ?? '');

                  Widget avatarWidget;
                  if (hasOtherUid) {
                    avatarWidget = _AvatarWithPresenceDot(
                      uid: otherUid,
                      avatarUrl: avatar.isEmpty ? null : avatar,
                      radius: 48,
                    );
                  } else {
                    avatarWidget = CircleAvatar(
                      radius: 48,
                      backgroundImage: avatar.isEmpty ? null : NetworkImage(avatar),
                      child: avatar.isEmpty ? const Icon(Icons.person, size: 40) : null,
                    );
                  }

                    final otherUserStream = hasOtherUid ? otherUserRef.child(otherUid).onValue : null;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(child: avatarWidget),
                      const SizedBox(height: 16),
                      StreamBuilder<DatabaseEvent>(
                        stream: otherUserStream,
                        builder: (context, userSnap) {
                          final v = userSnap.data?.snapshot.value;
                          final m = (v is Map) ? v : null;
                          final verified = m?['verified'] == true;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('@${widget.login}',
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 8),
                              if (verified) const Icon(Icons.verified, color: Colors.grey, size: 28),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _openRepoUrl(context, 'https://github.com/${widget.login}'),
                        icon: const Icon(Icons.open_in_new),
                        label: Text(AppLanguage.tr(context, 'Zobrazit na GitHubu', 'View on GitHub')),
                      ),
                      if (hasOtherUid) ...[
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: () => _confirmAndRun(
                            title: AppLanguage.tr(context, 'Poslat žádost o sdílení klíče?', 'Request key sharing?'),
                            message: AppLanguage.tr(
                              context,
                              'Protistraně se pošle upozornění do Chatů. Po přijetí se naváže E2EE komunikace (klíče/fingerprint).',
                              'A notification is sent to the peer in Chats. After acceptance, E2EE communication is established (keys/fingerprint).',
                            ),
                            action: () => _requestKeySharing(myUid: myUid, otherUid: otherUid),
                          ),
                          icon: const Icon(Icons.key_outlined),
                          label: Text(AppLanguage.tr(context, 'Poprosit sdílet klíč', 'Ask to share key')),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (!hasOtherUid) Text(AppLanguage.tr(context, 'Účet není propojený v databázi.', 'Account is not linked in database.')),

                      if (hasOtherUid)
                        FutureBuilder<String?>(
                          future: E2ee.fingerprintForUserSigningKey(uid: otherUid, bytes: 8),
                          builder: (context, peerFpSnap) {
                            return FutureBuilder<String>(
                              future: E2ee.fingerprintForMySigningKey(bytes: 8),
                              builder: (context, myFpSnap) {
                                final peerFp = peerFpSnap.data;
                                final myFp = myFpSnap.data;
                                if ((peerFp == null || peerFp.isEmpty) && (myFp == null || myFp.isEmpty)) {
                                  return const SizedBox.shrink();
                                }

                                return Padding(
                                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                                  child: Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(AppLanguage.tr(context, 'E2EE Fingerprint (anti-MITM)', 'E2EE Fingerprint (anti-MITM)'), style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 8),
                                          if (peerFp != null && peerFp.isNotEmpty)
                                            ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title: Text(AppLanguage.tr(context, 'Fingerprint protějšku', 'Peer fingerprint')),
                                              subtitle: SelectableText(peerFp),
                                              trailing: IconButton(
                                                icon: const Icon(Icons.copy),
                                                onPressed: () => Clipboard.setData(ClipboardData(text: peerFp)),
                                              ),
                                            )
                                          else
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(AppLanguage.tr(context, 'Fingerprint protějšku není dostupný (uživatel ještě nezveřejnil klíč).', 'Peer fingerprint is unavailable (the user has not published a key yet).')),
                                              ],
                                            ),
                                          if (myFp != null && myFp.isNotEmpty)
                                            ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title: Text(AppLanguage.tr(context, 'Můj fingerprint', 'My fingerprint')),
                                              subtitle: SelectableText(myFp),
                                              trailing: IconButton(
                                                icon: const Icon(Icons.copy),
                                                onPressed: () => Clipboard.setData(ClipboardData(text: myFp)),
                                              ),
                                            ),
                                          if (peerFp != null && peerFp.isNotEmpty && myFp != null && myFp.isNotEmpty && peerFp == myFp)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 4),
                                              child: Text(
                                                AppLanguage.tr(
                                                  context,
                                                  'Pozor: fingerprinty jsou shodné. To je neobvyklé (může jít o sdílené zařízení nebo záměnu účtů).',
                                                  'Warning: fingerprints are identical. This is unusual (it may indicate a shared device or account mix-up).',
                                                ),
                                                style: TextStyle(color: Theme.of(context).colorScheme.error),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),

                      const Divider(height: 32),
                      const SizedBox(height: 8),
                      Text(
                        AppLanguage.tr(context, 'Top repozitáře', 'Top repositories'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      if (topRepos != null && topRepos.isNotEmpty)
                        Column(
                          children: topRepos.take(3).map((repo) {
                            final name = (repo['name'] ?? '').toString();
                            final desc = (repo['description'] ?? '').toString();
                            final stars = repo['stargazers_count'] ?? 0;
                            final url = (repo['html_url'] ?? '').toString();
                            return ListTile(
                              leading: const Icon(Icons.book),
                              title: Text(name),
                              subtitle: desc.isNotEmpty ? Text(desc) : null,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star, size: 16, color: Colors.amber),
                                  Text(' $stars'),
                                ],
                              ),
                              onTap: () => _openRepoUrl(context, url),
                            );
                          }).toList(growable: false),
                        )
                      else
                        Text(AppLanguage.tr(context, 'Načítání repozitářů...', 'Loading repositories...')),
                      const SizedBox(height: 24),

                      if (hasOtherUid) ...[
                        _ProfileSectionCard(
                          title: AppLanguage.tr(context, 'Achievementy na GitMitu', 'GitMit achievements'),
                          icon: Icons.emoji_events_outlined,
                          child: FutureBuilder<DataSnapshot>(
                            future: otherUserRef.child(otherUid).get(),
                            builder: (context, otherSnap) {
                              final vv = otherSnap.data?.value;
                              final mm = (vv is Map) ? vv : null;
                              final badges = _parseBadges(mm?['badges']);
                              return badges.isEmpty
                                  ? Text(AppLanguage.tr(context, 'Zatím žádné achievementy.', 'No achievements yet.'))
                                  : Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: badges
                                          .map(
                                            (b) => Chip(
                                              label: Text(b),
                                              avatar: const Icon(Icons.workspace_premium_outlined, size: 18),
                                            ),
                                          )
                                          .toList(growable: false),
                                    );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        _ProfileSectionCard(
                          title: AppLanguage.tr(context, 'Aktivita v GitMitu', 'GitMit activity'),
                          icon: Icons.insights_outlined,
                          child: FutureBuilder<_GitmitStats?>(
                            future: _loadGitmitStats(otherUid),
                            builder: (context, statsSnap) {
                              final stats = statsSnap.data;
                              if (stats == null) {
                                return Text(AppLanguage.tr(context, 'Načítání aktivity...', 'Loading activity...'));
                              }
                              return Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _ProfileMetricTile(
                                    label: AppLanguage.tr(context, 'Priváty', 'DMs'),
                                    value: '${stats.privateChats}',
                                  ),
                                  _ProfileMetricTile(
                                    label: AppLanguage.tr(context, 'Skupiny', 'Groups'),
                                    value: '${stats.groups}',
                                  ),
                                  _ProfileMetricTile(
                                    label: AppLanguage.tr(context, 'Odeslané', 'Sent'),
                                    value: '${stats.messagesSent}',
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ],
                  );
                },
              );
            },
          ),

          StreamBuilder<DatabaseEvent>(
            stream: blockedRef.onValue,
            builder: (context, bSnap) {
              final blocked = bSnap.data?.snapshot.value == true;
              return FilledButton.tonal(
                onPressed: () => _confirmAndRun(
                  title: blocked
                      ? AppLanguage.tr(context, 'Odblokovat uživatele?', 'Unblock user?')
                      : AppLanguage.tr(context, 'Zablokovat uživatele?', 'Block user?'),
                  message: blocked
                      ? AppLanguage.tr(context, 'Znovu povolíš zprávy a zobrazování chatu.', 'You will allow messages and chat visibility again.')
                      : AppLanguage.tr(context, 'Zabráníš odesílání zpráv a chat se skryje v přehledu.', 'You will block messaging and hide this chat from the list.'),
                  action: () => _toggleBlock(myUid: myUid, currentlyBlocked: blocked),
                ),
                child: Text(blocked
                    ? AppLanguage.tr(context, 'Odblokovat', 'Unblock')
                    : AppLanguage.tr(context, 'Zablokovat', 'Block')),
              );
            },
          ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: () => _confirmAndRunThenPop(
              title: AppLanguage.tr(context, 'Smazat chat u mě?', 'Delete chat for me?'),
              message: AppLanguage.tr(context, 'Smaže zprávy a přehled konverzace jen u tebe.', 'This removes chat messages and conversation entry only for you.'),
              action: () => _deleteChatForMe(myUid: myUid),
              popResult: 'deleted_chat_for_me',
            ),
            child: Text(AppLanguage.tr(context, 'Smazat chat u mě', 'Delete chat for me')),
          ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: () => _confirmAndRunThenPop(
              title: AppLanguage.tr(context, 'Smazat chat u obou?', 'Delete chat for both?'),
              message: AppLanguage.tr(
                context,
                'Pokusí se smazat konverzaci u obou uživatelů. Funguje jen pokud je druhá strana propojená v databázi.',
                'Tries to delete conversation for both users. Works only if the other side is linked in database.',
              ),
              action: () => _deleteChatForBoth(myUid: myUid),
              popResult: 'deleted_chat_for_both',
            ),
            child: Text(AppLanguage.tr(context, 'Smazat chat u obou', 'Delete chat for both')),
          ),
        ],
      ),
    );
  }
}

class _CreateGroupPage extends StatefulWidget {
  const _CreateGroupPage({required this.myGithubUsername});

  final String myGithubUsername;

  @override
  State<_CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<_CreateGroupPage> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _logoUrl = TextEditingController();
  final _members = TextEditingController();

  Timer? _membersDebounce;
  String _membersLastQuery = '';
  bool _membersLoading = false;
  String? _membersError;
  List<GithubUser> _membersSuggestions = const [];

  bool _sendMessages = true;
  bool _allowMembersToAdd = true;
  bool _inviteLinkEnabled = false;

  bool _saving = false;

  Uint8List? _pickedLogoBytes;
  bool _pickingLogo = false;

  @override
  void initState() {
    super.initState();
    _members.addListener(_onMembersChanged);
  }

  @override
  void dispose() {
    _members.removeListener(_onMembersChanged);
    _membersDebounce?.cancel();
    _title.dispose();
    _description.dispose();
    _logoUrl.dispose();
    _members.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    if (_pickingLogo) return;
    setState(() => _pickingLogo = true);
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pickedLogoBytes = bytes;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
    } finally {
      if (mounted) setState(() => _pickingLogo = false);
    }
  }

  static final _memberDelim = RegExp(r'[\s,;]+');

  String? _currentMentionQuery() {
    final text = _members.text;
    var cursor = _members.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;

    final before = text.substring(0, cursor);
    final lastDelim = before.lastIndexOf(_memberDelim);
    final tokenStart = (lastDelim == -1) ? 0 : lastDelim + 1;
    final token = before.substring(tokenStart).trimLeft();
    if (!token.startsWith('@')) return null;
    final q = token.substring(1).trim();
    if (q.isEmpty) return null;
    return q;
  }

  void _onMembersChanged() {
    _membersDebounce?.cancel();
    _membersDebounce = Timer(const Duration(milliseconds: 350), () async {
      final q = _currentMentionQuery();
      if (q == null) {
        if (mounted) {
          setState(() {
            _membersSuggestions = const [];
            _membersLoading = false;
            _membersError = null;
          });
        }
        _membersLastQuery = '';
        return;
      }

      try {
        if (q == _membersLastQuery) return;
        _membersLastQuery = q;

        if (mounted) {
          setState(() {
            _membersLoading = true;
            _membersError = null;
          });
        }

        final users = await searchGithubUsers(q);
        if (!mounted) return;
        setState(() {
          _membersSuggestions = users.take(8).toList(growable: false);
          _membersLoading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _membersSuggestions = const [];
          _membersLoading = false;
          _membersError = e.toString();
        });
      }
    });
  }

  void _applyMemberSuggestion(String login) {
    final text = _members.text;
    var cursor = _members.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;

    int start = cursor;
    while (start > 0 && !_memberDelim.hasMatch(text.substring(start - 1, start))) {
      start--;
    }

    int end = cursor;
    while (end < text.length && !_memberDelim.hasMatch(text.substring(end, end + 1))) {
      end++;
    }

    final replacement = '@$login';
    final nextText = text.replaceRange(start, end, replacement);
    final withComma = (end >= text.length) ? '$nextText, ' : nextText;

    _members.value = TextEditingValue(
      text: withComma,
      selection: TextSelection.collapsed(offset: (start + replacement.length) + ((end >= text.length) ? 2 : 0)),
    );

    setState(() {
      _membersSuggestions = const [];
      _membersLoading = false;
      _membersError = null;
    });
  }

  List<String> _parseUsernames(String raw) {
    final tokens = raw
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('@') ? e.substring(1) : e)
        .toList();
    final out = <String>[];
    final seen = <String>{};
    for (final t in tokens) {
      final lower = t.toLowerCase();
      if (seen.add(lower)) out.add(t);
    }
    return out;
  }

  Future<void> _create() async {
    final t = AppLanguage.tr;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final title = _title.text.trim();
    final desc = _description.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(context, 'Vyplň název skupiny.', 'Fill in group title.'))));
      return;
    }

    setState(() => _saving = true);
    try {
      final groupPush = rtdb().ref('groups').push();
      final groupId = groupPush.key;
      if (groupId == null) throw Exception('Nelze vytvořit groupId');

      final inviteCode = _inviteLinkEnabled ? generateInviteCode() : '';

      String? logoUrl;
      final manualLogoUrl = _logoUrl.text.trim();
      if (_pickedLogoBytes != null) {
        try {
          logoUrl = await _uploadGroupLogo(groupId: groupId, bytes: _pickedLogoBytes!);
        } catch (e) {
          // Don't fail group creation just because logo upload failed.
          logoUrl = null;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${t(context, 'Logo se nepodařilo nahrát (skupina se vytvoří i tak)', 'Logo upload failed (group will still be created)')}: $e')),
            );
          }
        }
      } else if (manualLogoUrl.isNotEmpty) {
        logoUrl = manualLogoUrl;
      }

      await groupPush.set({
        'title': title,
        'description': desc,
        if (logoUrl != null && logoUrl.isNotEmpty) 'logoUrl': logoUrl,
        if (inviteCode.isNotEmpty) 'inviteCode': inviteCode,
        'createdByUid': current.uid,
        'createdByGithub': widget.myGithubUsername,
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'permissions': {
          'sendMessages': _sendMessages,
          'allowMembersToAdd': _allowMembersToAdd,
          'inviteLinkEnabled': _inviteLinkEnabled,
        },
      });

      await rtdb().ref('groupMembers/$groupId/${current.uid}').set({
        'role': 'admin',
        'joinedAt': ServerValue.timestamp,
      });
      await rtdb().ref('userGroups/${current.uid}/$groupId').set(true);

      final usernames = _parseUsernames(_members.text);
      final missing = <String>[];
      for (final u in usernames) {
        final lower = u.toLowerCase();
        final snap = await rtdb().ref('usernames/$lower').get();
        final uid = snap.value?.toString();
        if (uid == null || uid.isEmpty) {
          missing.add(u);
          continue;
        }
        if (uid == current.uid) continue;

        await rtdb().ref('groupInvites/$uid/$groupId').set({
          'groupId': groupId,
          'groupTitle': title,
          if (logoUrl != null && logoUrl.isNotEmpty) 'groupLogoUrl': logoUrl,
          'invitedByUid': current.uid,
          'invitedByGithub': widget.myGithubUsername,
          'createdAt': ServerValue.timestamp,
        });
      }

      if (!mounted) return;
      if (missing.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${t(context, 'Nenalezeno v aplikaci', 'Not found in app')}: ${missing.map((e) => '@$e').join(', ')}')),
        );
      }

      Navigator.of(context).pop(groupId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t(context, 'Chyba', 'Error')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;

    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'Vytvořit skupinu', 'Create group'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: InputDecoration(labelText: t(context, 'Název', 'Title')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: InputDecoration(labelText: t(context, 'Popis', 'Description')),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _logoUrl,
            decoration: InputDecoration(labelText: t(context, 'Logo URL (volitelné)', 'Logo URL (optional)')),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: (_saving || _pickingLogo) ? null : _pickLogo,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(_pickedLogoBytes == null
                      ? t(context, 'Vybrat logo z galerie', 'Pick logo from gallery')
                      : t(context, 'Změnit logo', 'Change logo')),
                ),
              ),
              const SizedBox(width: 12),
              if (_pickedLogoBytes != null)
                OutlinedButton(
                  onPressed: _saving ? null : () => setState(() => _pickedLogoBytes = null),
                  child: Text(t(context, 'Odebrat', 'Remove')),
                ),
            ],
          ),
          if (_pickedLogoBytes != null) ...[
            const SizedBox(height: 12),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  _pickedLogoBytes!,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(t(context, 'Oprávnění', 'Permissions'), style: const TextStyle(fontWeight: FontWeight.bold)),
          SwitchListTile(
            value: _sendMessages,
            onChanged: (v) => setState(() => _sendMessages = v),
            title: Text(t(context, 'Posílat nové zprávy', 'Send new messages')),
          ),
          SwitchListTile(
            value: _allowMembersToAdd,
            onChanged: (v) => setState(() => _allowMembersToAdd = v),
            title: Text(t(context, 'Přidávat uživatele', 'Allow adding users')),
          ),
          SwitchListTile(
            value: _inviteLinkEnabled,
            onChanged: (v) => setState(() => _inviteLinkEnabled = v),
            title: Text(t(context, 'Pozvánka přes link / QR', 'Invite via link / QR')),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _members,
            decoration: InputDecoration(
              labelText: t(context, 'Přidat lidi podle username', 'Add users by username'),
              hintText: t(context, '@user1, @user2', '@user1, @user2'),
            ),
            maxLines: 3,
          ),
          if (_membersLoading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (_membersError != null) ...[
            const SizedBox(height: 8),
            Text(_membersError!, style: const TextStyle(color: Colors.redAccent)),
          ],
          if (_membersSuggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _membersSuggestions.map((u) {
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundImage: u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
                      child: u.avatarUrl.isEmpty ? const Icon(Icons.person, size: 16) : null,
                    ),
                    title: Text('@${u.login}'),
                    onTap: () => _applyMemberSuggestion(u.login),
                  );
                }).toList(growable: false),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _create,
            child: _saving
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator())
                : Text(t(context, 'Vytvořit', 'Create')),
          ),
        ],
      ),
    );
  }
}

class _GroupInfoPage extends StatefulWidget {
  const _GroupInfoPage({required this.groupId});

  final String groupId;

  @override
  State<_GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<_GroupInfoPage> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _logoUrl = TextEditingController();

  bool _inited = false;
  Future<String?>? _inviteCodeFuture;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _logoUrl.dispose();
    super.dispose();
  }

  Future<void> _update(String groupId, Map<String, Object?> patch) async {
    await rtdb().ref('groups/$groupId').update({...patch, 'updatedAt': ServerValue.timestamp});
  }

  Future<void> _leaveGroupAsMember({required String groupId, required String uid}) async {
    await rtdb().ref('groupMembers/$groupId/$uid').remove();
    await rtdb().ref('userGroups/$uid/$groupId').remove();
  }

  Future<void> _transferAdminAndLeave({
    required String groupId,
    required String uid,
    required String newAdminUid,
  }) async {
    await rtdb().ref('groupMembers/$groupId/$newAdminUid').update({'role': 'admin'});
    await _leaveGroupAsMember(groupId: groupId, uid: uid);
  }

  Future<void> _deleteGroupAsAdmin({required String groupId}) async {
    final membersSnap = await rtdb().ref('groupMembers/$groupId').get();
    final mv = membersSnap.value;
    final mm = (mv is Map) ? mv : null;

    final updates = <String, Object?>{};
    updates['groups/$groupId'] = null;
    updates['groupMembers/$groupId'] = null;
    updates['groupMessages/$groupId'] = null;
    updates['groupJoinRequests/$groupId'] = null;

    if (mm != null) {
      for (final e in mm.entries) {
        final memberUid = e.key.toString();
        updates['userGroups/$memberUid/$groupId'] = null;
        // also remove pending invite if it exists
        updates['groupInvites/$memberUid/$groupId'] = null;
      }
    }

    await rtdb().ref().update(updates);
  }

  Future<String?> _loadOrEnsureInviteCode({
    required String groupId,
    required String existingCode,
    required bool isAdmin,
    required bool enabled,
  }) async {
    if (!enabled) return null;
    if (existingCode.trim().isNotEmpty) return existingCode.trim();
    if (!isAdmin) return null;

    final newCode = generateInviteCode();
    await rtdb().ref('groups/$groupId/inviteCode').set(newCode);
    return newCode;
  }

  Future<void> _regenerateInviteCode({required String groupId}) async {
    final newCode = generateInviteCode();
    await rtdb().ref('groups/$groupId/inviteCode').set(newCode);
    if (mounted) {
      setState(() {
        _inviteCodeFuture = Future.value(newCode);
      });
    }
  }

  Future<void> _requestAddMember({
    required String groupId,
    required String targetLogin,
    required String requestedByGithub,
  }) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final targetLower = targetLogin.trim().toLowerCase();
    final snap = await rtdb().ref('usernames/$targetLower').get();
    final targetUid = snap.value?.toString();
    if (targetUid == null || targetUid.isEmpty) {
      throw Exception('Uživatel není registrovaný v GitMitu.');
    }
    if (targetUid == current.uid) return;

    // Create pending request under group.
    await rtdb().ref('groupJoinRequests/$groupId/$targetLower').set({
      'targetLogin': targetLogin,
      'targetUid': targetUid,
      'requestedByUid': current.uid,
      'requestedByGithub': requestedByGithub,
      'createdAt': ServerValue.timestamp,
    });

    // Fan-out inbox pointers to all admins.
    final membersSnap = await rtdb().ref('groupMembers/$groupId').get();
    final mv = membersSnap.value;
    final m = (mv is Map) ? mv : null;
    if (m != null) {
      for (final e in m.entries) {
        if (e.value is! Map) continue;
        final mm = Map<String, dynamic>.from(e.value as Map);
        final role = (mm['role'] ?? 'member').toString();
        if (role != 'admin') continue;
        final adminUid = e.key.toString();
        await rtdb().ref('groupAdminInbox/$adminUid/${groupId}~$targetLower').set({
          'groupId': groupId,
          'targetLower': targetLower,
          'targetLogin': targetLogin,
          'requestedByUid': current.uid,
          'requestedByGithub': requestedByGithub,
          'createdAt': ServerValue.timestamp,
        });
      }
    }
  }

  Future<void> _pickAndUploadLogo({required String groupId}) async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();
      final url = await _uploadGroupLogo(groupId: groupId, bytes: bytes);
      await _update(groupId, {'logoUrl': url});
      if (mounted) {
        setState(() {
          _logoUrl.text = url;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${AppLanguage.tr(context, 'Logo se nepodařilo nahrát', 'Failed to upload logo')}: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;

    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return Scaffold(body: Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.'))));
    }

    final groupRef = rtdb().ref('groups/${widget.groupId}');
    final memberRef = rtdb().ref('groupMembers/${widget.groupId}/${current.uid}');
    final myUserRef = rtdb().ref('users/${current.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: groupRef.onValue,
      builder: (context, gSnap) {
        final gv = gSnap.data?.snapshot.value;
        final gm = (gv is Map) ? gv : null;
        if (gm == null) {
          return const Scaffold(body: SizedBox.shrink());
        }

        final title = (gm['title'] ?? '').toString();
        final desc = (gm['description'] ?? '').toString();
        final logo = (gm['logoUrl'] ?? '').toString();
        final inviteCode = (gm['inviteCode'] ?? '').toString();
        final perms = (gm['permissions'] is Map) ? (gm['permissions'] as Map) : null;
        final sendMessages = perms?['sendMessages'] != false;
        final allowMembersToAdd = perms?['allowMembersToAdd'] != false;
        final inviteLinkEnabled = perms?['inviteLinkEnabled'] == true;

        if (!_inited) {
          _title.text = title;
          _description.text = desc;
          _logoUrl.text = logo;
          _inited = true;
        }

        return StreamBuilder<DatabaseEvent>(
          stream: memberRef.onValue,
          builder: (context, mSnap) {
            final mv = mSnap.data?.snapshot.value;
            final mm = (mv is Map) ? mv : null;
            final role = (mm?['role'] ?? 'member').toString();
            final isAdmin = role == 'admin';

            if (!inviteLinkEnabled) {
              _inviteCodeFuture = null;
            } else {
              _inviteCodeFuture ??= _loadOrEnsureInviteCode(
                groupId: widget.groupId,
                existingCode: inviteCode,
                isAdmin: isAdmin,
                enabled: inviteLinkEnabled,
              );
            }

            return StreamBuilder<DatabaseEvent>(
              stream: myUserRef.onValue,
              builder: (context, uSnap) {
                final uv = uSnap.data?.snapshot.value;
                final um = (uv is Map) ? uv : null;
                final myGithub = (um?['githubUsername'] ?? '').toString();

                return Scaffold(
                  appBar: AppBar(title: Text(t(context, 'Skupina', 'Group'))),
                  body: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundImage: logo.isNotEmpty ? NetworkImage(logo) : null,
                            child: logo.isEmpty ? const Icon(Icons.group) : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: Theme.of(context).textTheme.titleMedium),
                                Text(isAdmin ? t(context, 'Admin', 'Admin') : t(context, 'Člen', 'Member'), style: Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      if (isAdmin) ...[
                        TextField(controller: _title, decoration: InputDecoration(labelText: t(context, 'Název', 'Title'))),
                        const SizedBox(height: 12),
                        TextField(controller: _description, decoration: InputDecoration(labelText: t(context, 'Popis', 'Description')), maxLines: 3),
                        const SizedBox(height: 12),
                        TextField(controller: _logoUrl, decoration: InputDecoration(labelText: t(context, 'Logo URL', 'Logo URL'))),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: () => _pickAndUploadLogo(groupId: widget.groupId),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: Text(t(context, 'Vybrat logo z galerie', 'Pick logo from gallery')),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _update(widget.groupId, {
                            'title': _title.text.trim(),
                            'description': _description.text.trim(),
                            'logoUrl': _logoUrl.text.trim(),
                          }),
                          child: Text(t(context, 'Uložit', 'Save')),
                        ),
                        const Divider(height: 32),
                        Text(t(context, 'Oprávnění', 'Permissions'), style: const TextStyle(fontWeight: FontWeight.bold)),
                        SwitchListTile(
                          value: sendMessages,
                          onChanged: (v) => _update(widget.groupId, {
                            'permissions/sendMessages': v,
                          }),
                          title: Text(t(context, 'Posílat nové zprávy', 'Send new messages')),
                        ),
                        SwitchListTile(
                          value: allowMembersToAdd,
                          onChanged: (v) => _update(widget.groupId, {
                            'permissions/allowMembersToAdd': v,
                          }),
                          title: Text(t(context, 'Přidávat uživatele', 'Allow adding users')),
                        ),
                        SwitchListTile(
                          value: inviteLinkEnabled,
                          onChanged: (v) async {
                            await _update(widget.groupId, {
                              'permissions/inviteLinkEnabled': v,
                            });
                            if (!mounted) return;
                            if (v) {
                              setState(() {
                                _inviteCodeFuture = _loadOrEnsureInviteCode(
                                  groupId: widget.groupId,
                                  existingCode: inviteCode,
                                  isAdmin: true,
                                  enabled: true,
                                );
                              });
                            } else {
                              setState(() {
                                _inviteCodeFuture = null;
                              });
                            }
                          },
                          title: Text(t(context, 'Pozvánka přes link / QR', 'Invite via link / QR')),
                        ),
                      ] else ...[
                        ListTile(title: Text(title), subtitle: desc.isNotEmpty ? Text(desc) : null),
                        const Divider(height: 32),
                      ],

                      if (inviteLinkEnabled) ...[
                        Text(t(context, 'Pozvánka: link / QR', 'Invite link / QR'), style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        FutureBuilder<String?>(
                          future: _inviteCodeFuture,
                          builder: (context, codeSnap) {
                            final code = (codeSnap.data ?? '').trim();
                            if (code.isEmpty) {
                              return ListTile(
                                leading: Icon(Icons.link),
                                title: Text(t(context, 'Link není dostupný', 'Link is unavailable')),
                                subtitle: Text(t(context, 'Zkus to za chvilku znovu.', 'Try again in a moment.')),
                              );
                            }
                            final link = buildGroupInviteLink(groupId: widget.groupId, code: code);
                            final qrPayload = buildGroupInviteQrPayload(groupId: widget.groupId, code: code);

                            return Column(
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.link),
                                  title: Text(t(context, 'Pozvánka', 'Invite')),
                                  subtitle: Text(link, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.copy),
                                    onPressed: () async {
                                      await Clipboard.setData(ClipboardData(text: link));
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text(t(context, 'Link zkopírován.', 'Link copied.'))),
                                        );
                                      }
                                    },
                                  ),
                                ),
                                Center(
                                  child: Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: QrImageView(
                                      data: qrPayload,
                                      size: 220,
                                    ),
                                  ),
                                ),
                                if (isAdmin) ...[
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    onPressed: () => _regenerateInviteCode(groupId: widget.groupId),
                                    icon: const Icon(Icons.refresh),
                                    label: Text(t(context, 'Regenerovat pozvánku', 'Regenerate invite')),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                        const Divider(height: 32),
                      ],

                      ListTile(
                        leading: const Icon(Icons.person_add_alt_1),
                        title: Text(t(context, 'Přidat uživatele', 'Add user')),
                        subtitle: Text(
                          allowMembersToAdd
                              ? t(context, 'Pošle se žádost adminům (pokud nejsi admin).', 'A request will be sent to admins (if you are not admin).')
                              : t(context, 'Může jen admin.', 'Only admin can do this.'),
                        ),
                        onTap: (!allowMembersToAdd && !isAdmin)
                            ? null
                            : () async {
                                final picked = await showModalBottomSheet<GithubUser>(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (context) => _GithubUserSearchSheet(title: t(context, 'Přidat uživatele', 'Add user')),
                                );
                                final normalized = (picked?.login ?? '').trim();
                                if (normalized.isEmpty) return;

                                try {
                                  if (isAdmin) {
                                    final lower = normalized.toLowerCase();
                                    final snap = await rtdb().ref('usernames/$lower').get();
                                    final uid = snap.value?.toString();
                                    if (uid == null || uid.isEmpty) throw Exception('Uživatel není registrovaný v GitMitu.');
                                    await rtdb().ref('groupInvites/$uid/${widget.groupId}').set({
                                      'groupId': widget.groupId,
                                      'groupTitle': title,
                                      if (logo.isNotEmpty) 'groupLogoUrl': logo,
                                      'invitedByUid': current.uid,
                                      'invitedByGithub': myGithub,
                                      'createdAt': ServerValue.timestamp,
                                    });
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(t(context, 'Pozvánka odeslána.', 'Invite sent.'))),
                                      );
                                    }
                                  } else {
                                    await _requestAddMember(
                                      groupId: widget.groupId,
                                      targetLogin: normalized,
                                      requestedByGithub: myGithub,
                                    );
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(t(context, 'Žádost odeslána adminům.', 'Request sent to admins.'))),
                                      );
                                    }
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('${t(context, 'Chyba', 'Error')}: $e')),
                                    );
                                  }
                                }
                              },
                      ),

                      const Divider(height: 32),
                      if (!isAdmin)
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text(t(context, 'Odejít ze skupiny?', 'Leave group?')),
                                content: Text(t(context, 'Skupinu opustíš a zmizí ti ze seznamu.', 'You will leave the group and it will disappear from your list.')),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t(context, 'Zrušit', 'Cancel'))),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t(context, 'Odejít', 'Leave'))),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            await _leaveGroupAsMember(groupId: widget.groupId, uid: current.uid);
                            if (!mounted) return;
                            Navigator.of(context).pop('left');
                          },
                          icon: const Icon(Icons.logout),
                          label: Text(t(context, 'Odejít ze skupiny', 'Leave group')),
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () async {
                                // Admin must transfer admin or delete group.
                                final action = await showDialog<String>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text(t(context, 'Jsi admin', 'You are admin')),
                                    content: Text(t(context, 'Před odchodem musíš předat admina, nebo smazat celou skupinu.', 'Before leaving, transfer admin role or delete the entire group.')),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(context), child: Text(t(context, 'Zrušit', 'Cancel'))),
                                      TextButton(onPressed: () => Navigator.pop(context, 'transfer'), child: Text(t(context, 'Předat admina', 'Transfer admin'))),
                                      FilledButton(onPressed: () => Navigator.pop(context, 'delete'), child: Text(t(context, 'Smazat skupinu', 'Delete group'))),
                                    ],
                                  ),
                                );
                                if (action == null) return;
                                if (action == 'delete') {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(t(context, 'Smazat skupinu?', 'Delete group?')),
                                      content: Text(t(context, 'Tohle smaže skupinu pro všechny.', 'This will delete the group for everyone.')),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t(context, 'Zrušit', 'Cancel'))),
                                        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t(context, 'Smazat', 'Delete'))),
                                      ],
                                    ),
                                  );
                                  if (ok != true) return;
                                  await _deleteGroupAsAdmin(groupId: widget.groupId);
                                  if (!mounted) return;
                                  Navigator.of(context).pop('deleted');
                                  return;
                                }

                                final membersSnap = await rtdb().ref('groupMembers/${widget.groupId}').get();
                                final mv = membersSnap.value;
                                final m = (mv is Map) ? mv : null;
                                final candidates = <String>[];
                                if (m != null) {
                                  for (final e in m.entries) {
                                    final uid = e.key.toString();
                                    if (uid == current.uid) continue;
                                    candidates.add(uid);
                                  }
                                }
                                if (candidates.isEmpty) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(t(context, 'Ve skupině není nikdo další. Můžeš ji jen smazat.', 'There is no one else in the group. You can only delete it.'))),
                                  );
                                  return;
                                }

                                final pickedUid = await showModalBottomSheet<String>(
                                  context: context,
                                  builder: (context) {
                                    return SafeArea(
                                      child: ListView(
                                        shrinkWrap: true,
                                        children: [
                                          ListTile(
                                            title: Text(t(context, 'Vyber nového admina', 'Pick new admin'), style: const TextStyle(fontWeight: FontWeight.w700)),
                                          ),
                                          const Divider(height: 1),
                                          ...candidates.map((uid) {
                                            return FutureBuilder<DataSnapshot>(
                                              future: rtdb().ref('users/$uid/githubUsername').get(),
                                              builder: (context, snap) {
                                                final gh = snap.data?.value?.toString() ?? uid;
                                                return ListTile(
                                                  leading: const Icon(Icons.admin_panel_settings_outlined),
                                                  title: Text(gh.startsWith('@') ? gh : '@$gh'),
                                                  subtitle: Text(uid, maxLines: 1, overflow: TextOverflow.ellipsis),
                                                  onTap: () => Navigator.of(context).pop(uid),
                                                );
                                              },
                                            );
                                          }),
                                        ],
                                      ),
                                    );
                                  },
                                );
                                if (pickedUid == null || pickedUid.isEmpty) return;
                                await _transferAdminAndLeave(groupId: widget.groupId, uid: current.uid, newAdminUid: pickedUid);
                                if (!mounted) return;
                                Navigator.of(context).pop('left');
                              },
                              icon: const Icon(Icons.logout),
                              label: Text(t(context, 'Odejít / smazat', 'Leave / delete')),
                            ),
                          ],
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _DashboardPageState extends State<DashboardPage> {
  int _index = 0;
  String? _openChatLogin;
  String? _openChatAvatarUrl;
  int _openChatToken = 0;
  int _chatsOverviewToken = 0;

  StreamSubscription<DatabaseEvent>? _connectedSub;
  StreamSubscription<DatabaseEvent>? _presenceEnabledSub;
  bool _presenceInitialized = false;
  bool _presenceEnabled = true;
  String _presenceStatus = 'online';
  bool _onlinePresenceNotifySent = false;
  String? _presenceSessionId;
  String? _currentDeviceId;
  int _currentDeviceLoginAt = 0;
  StreamSubscription<DatabaseEvent>? _deviceSessionSub;
  static const Duration _presenceSessionTtl = Duration(days: 3);
  late final _AppLifecycleObserver _lifecycleObserver;

  final GlobalKey<_ChatsTabState> _chatsKey = GlobalKey<_ChatsTabState>();

  String _titleForIndex(BuildContext context, int index) {
    switch (index) {
      case 0:
        return 'Jobs';
      case 1:
        return AppLanguage.tr(context, 'Chaty', 'Chats');
      case 2:
        return AppLanguage.tr(context, 'Kontakty', 'Contacts');
      case 3:
        return AppLanguage.tr(context, 'Nastavení', 'Settings');
      case 4:
        return AppLanguage.tr(context, 'Profil', 'Profile');
      default:
        return 'GitMit';
    }
  }

  Future<bool> _onWillPop() async {
    // Never exit the app from a nested step; step back instead.
    if (_index != 1) {
      setState(() {
        // Back from other tabs goes to Chaty overview.
        _openChatLogin = null;
        _openChatAvatarUrl = null;
        _chatsOverviewToken++;
        _index = 1;
      });
      return false;
    }

    final handled = _chatsKey.currentState?.handleBack() == true;
    if (handled) return false;
    return true;
  }

  PreferredSizeWidget _pillAppBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _titleForIndex(context, _index);
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _pillBottomNav(BuildContext context, {required bool vibrationEnabled}) {
    final cs = Theme.of(context).colorScheme;
    final items = <({IconData icon, String label})>[
      (icon: Icons.dashboard, label: 'Jobs'),
      (icon: Icons.chat_bubble_outline, label: AppLanguage.tr(context, 'Chaty', 'Chats')),
      (icon: Icons.people_outline, label: AppLanguage.tr(context, 'Kontakty', 'Contacts')),
      (icon: Icons.settings_outlined, label: AppLanguage.tr(context, 'Nastavení', 'Settings')),
      (icon: Icons.person_outline, label: AppLanguage.tr(context, 'Profil', 'Profile')),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final itemW = w / items.length;
            const h = 64.0;
            const inset = 4.0;

            return SizedBox(
              height: h,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    left: _index * itemW + inset,
                    top: inset,
                    width: itemW - inset * 2,
                    height: h - inset * 2,
                    child: Container(
                      decoration: BoxDecoration(
                        color: cs.secondary,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () {
                              if (i != _index) {
                                if (vibrationEnabled) {
                                  HapticFeedback.selectionClick();
                                }
                              }
                              setState(() {
                                if (i == 1 && _index != 1) {
                                  // Ruční přepnutí na Chaty vždy otevře přehled.
                                  _openChatLogin = null;
                                  _openChatAvatarUrl = null;
                                  _chatsOverviewToken++;
                                }
                                _index = i;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    items[i].icon,
                                    size: 22,
                                    color: (i == _index) ? cs.onSecondary : cs.onSurface,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    items[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: (i == _index) ? cs.onSecondary : cs.onSurface,
                                          fontWeight: (i == _index) ? FontWeight.w700 : FontWeight.w500,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _leftSideNav(BuildContext context, {required bool vibrationEnabled}) {
    final destinations = <({IconData icon, String label})>[
      (icon: Icons.dashboard, label: 'Jobs'),
      (icon: Icons.chat_bubble_outline, label: AppLanguage.tr(context, 'Chaty', 'Chats')),
      (icon: Icons.people_outline, label: AppLanguage.tr(context, 'Kontakty', 'Contacts')),
      (icon: Icons.settings_outlined, label: AppLanguage.tr(context, 'Nastavení', 'Settings')),
      (icon: Icons.person_outline, label: AppLanguage.tr(context, 'Profil', 'Profile')),
    ];

    return NavigationRail(
      selectedIndex: _index,
      labelType: NavigationRailLabelType.all,
      onDestinationSelected: (i) {
        if (i != _index && vibrationEnabled) {
          HapticFeedback.selectionClick();
        }
        setState(() {
          if (i == 1 && _index != 1) {
            _openChatLogin = null;
            _openChatAvatarUrl = null;
            _chatsOverviewToken++;
          }
          _index = i;
        });
      },
      destinations: [
        for (final d in destinations)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.icon),
            label: Text(d.label),
          ),
      ],
    );
  }

  Future<void> _logout() async {
    // Reset E2EE scope immediately so any late async tasks won't read/write
    // keys/sessions under the wrong user after logout.
    E2ee.setActiveUser(null);
    DataUsageTracker.setActiveUser(null);
    final current = FirebaseAuth.instance.currentUser;
    if (current != null) {
      final sessionRef = _presenceSessionRef(current.uid);
      sessionRef?.remove();
      if (_currentDeviceId != null && _currentDeviceId!.isNotEmpty) {
        await rtdb().ref('deviceSessions/${current.uid}/${_currentDeviceId!}').remove();
      }
    }
    () async {
      try {
        await PlaintextCache.setActiveUser(null);
      } catch (_) {
        // ignore
      }
    }();
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  DatabaseReference _dmContactRef({required String myUid, required String otherLoginLower}) {
    return rtdb().ref('dmContacts/$myUid/$otherLoginLower');
  }

  Future<bool> _isDmAccepted({required String myUid, required String otherLoginLower}) async {
    final snap = await _dmContactRef(myUid: myUid, otherLoginLower: otherLoginLower).get();
    if (!snap.exists) return false;
    final v = snap.value;
    if (v is bool) return v;
    return true;
  }

  Future<String?> _myAvatarUrl(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/avatarUrl').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _sendDmRequestCore({
    required String myUid,
    required String myLogin,
    required String otherUid,
    required String otherLogin,
    String? myAvatarUrl,
    String? otherAvatarUrl,
    String? messageText,
  }) async {
    final myLoginLower = myLogin.trim().toLowerCase();
    final otherLoginLower = otherLogin.trim().toLowerCase();
    if (myLoginLower.isEmpty || otherLoginLower.isEmpty) return;

    // Publish my public bundle before sending an invite, so the other side can
    // immediately fetch my keys/fingerprint and establish encrypted comms.
    try {
      await E2ee.publishMyPublicKey(uid: myUid);
    } catch (_) {
      // best-effort
    }

    Map<String, Object?>? encrypted;
    final pt = (messageText ?? '').trim();
    if (pt.isNotEmpty) {
      try {
        encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: pt);
      } catch (_) {
        encrypted = null;
      }
    }

    final updates = <String, Object?>{
      'dmRequests/$otherUid/$myLoginLower': {
        'fromUid': myUid,
        'fromLogin': myLogin,
        if (myAvatarUrl != null && myAvatarUrl.trim().isNotEmpty) 'fromAvatarUrl': myAvatarUrl.trim(),
        'createdAt': ServerValue.timestamp,
        if (encrypted != null) ...encrypted,
      },
      'savedChats/$myUid/$otherLogin': {
        'login': otherLogin,
        if (otherAvatarUrl != null && otherAvatarUrl.trim().isNotEmpty) 'avatarUrl': otherAvatarUrl.trim(),
        'status': 'pending_out',
        'lastMessageText': '🔒',
        'lastMessageAt': ServerValue.timestamp,
        'savedAt': ServerValue.timestamp,
      },
      'savedChats/$otherUid/$myLogin': {
        'login': myLogin,
        if (myAvatarUrl != null) 'avatarUrl': myAvatarUrl,
        'status': 'pending_in',
        'lastMessageText': '🔒',
        'lastMessageAt': ServerValue.timestamp,
        'savedAt': ServerValue.timestamp,
      },
    };

    await rtdb().ref().update(updates);
  }

  Future<void> _sendDmRequest({
    required String myUid,
    required String myLogin,
    required String otherUid,
    required String otherLogin,
    String? messageText,
    String? otherAvatarUrl,
  }) async {
    final myAvatar = await _myAvatarUrl(myUid);
    await _sendDmRequestCore(
      myUid: myUid,
      myLogin: myLogin,
      myAvatarUrl: myAvatar,
      otherUid: otherUid,
      otherLogin: otherLogin,
      otherAvatarUrl: otherAvatarUrl,
      messageText: messageText,
    );
  }

  Future<_InviteSendResult> _notifyGithubInviteForNonGitmit({
    required String targetLogin,
    required String fromLogin,
  }) async {
    final endpoint = _githubDmFallbackUrl.trim();
    if (endpoint.isEmpty) {
      debugPrint('[GitMitInvite] Missing GITMIT_GITHUB_NOTIFY_URL');
      return const _InviteSendResult(ok: false, error: 'Missing GITMIT_GITHUB_NOTIFY_URL');
    }

    final uris = _inviteBackendUris(endpoint);
    if (uris.isEmpty) {
      debugPrint('[GitMitInvite] Invalid invite URL: $endpoint');
      return _InviteSendResult(ok: false, error: 'Invalid invite URL: $endpoint');
    }

    final preview = 'Message from GitMit app: @$fromLogin wants to chat. You do not have GitMit yet—download it and continue the conversation.';
    final payload = jsonEncode({
      'targetLogin': targetLogin,
      'fromLogin': fromLogin,
      'preview': preview,
      'source': 'gitmit-contact-invite',
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_githubDmFallbackToken.trim().isNotEmpty) 'Authorization': 'Bearer ${_githubDmFallbackToken.trim()}',
    };

    String? lastError;
    for (final uri in uris) {
      try {
        final response = await http.post(uri, headers: headers, body: payload);
        final ok = response.statusCode >= 200 && response.statusCode < 300;
        if (ok) return const _InviteSendResult(ok: true);
        lastError = _inviteErrorFromHttp(statusCode: response.statusCode, uri: uri, body: response.body);
        debugPrint('[GitMitInvite] Backend ${response.statusCode} at $uri: ${response.body}');
      } catch (e) {
        lastError = 'Request failed at $uri: $e';
        debugPrint('[GitMitInvite] Request failed at $uri: $e');
      }
    }

    final manualOpened = await _openManualGithubInvite(
      targetLogin: targetLogin,
      fromLogin: fromLogin,
      preview: '@$fromLogin sent you a message in GitMit.',
    );
    if (manualOpened) {
      return _InviteSendResult(
        ok: true,
        error: lastError,
        manualFallbackUsed: true,
      );
    }

    return _InviteSendResult(ok: false, error: lastError ?? 'Unknown invite error');
  }

  void _openChat({required String login, required String avatarUrl}) {
    final key = login.trim().toLowerCase();
    if (key.isEmpty) return;

    () async {
      final current = FirebaseAuth.instance.currentUser;
      if (current == null) return;

      final snap = await rtdb().ref('usernames/$key').get();
      final v = snap.value;
      final uid = (v == null) ? '' : v.toString().trim();
      if (!mounted) return;

      if (uid.isEmpty) {
        final myLogin = await _myGithubUsernameFromRtdb(current.uid);
        _InviteSendResult inviteResult = const _InviteSendResult(ok: false);
        if (myLogin != null && myLogin.trim().isNotEmpty) {
          try {
            inviteResult = await _notifyGithubInviteForNonGitmit(
              targetLogin: login,
              fromLogin: myLogin.trim(),
            );
          } catch (_) {
            inviteResult = const _InviteSendResult(ok: false, error: 'Request threw exception');
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              inviteResult.ok
                  ? (inviteResult.manualFallbackUsed
                        ? AppLanguage.tr(
                            context,
                            'Backend invite není dostupný. Otevřel se GitHub formulář s předvyplněnou pozvánkou pro @$login.',
                            'Backend invite is unavailable. A prefilled GitHub invite form for @$login was opened.',
                          )
                        : AppLanguage.tr(context, 'Uživatel @$login není v GitMitu. Poslal se mu GitHub invite od @$myLogin.', 'User @$login is not on GitMit. A GitHub invite from @$myLogin was sent.'))
                  : '${AppLanguage.tr(context, 'Pozvánku se nepodařilo odeslat', 'Failed to send invite')}: ${inviteResult.error ?? AppLanguage.tr(context, 'neznámá chyba', 'unknown error')}',
            ),
          ),
        );
        return;
      }

      final myLogin = await _myGithubUsernameFromRtdb(current.uid);
      if (myLogin == null || myLogin.trim().isEmpty) return;

      final accepted = await _isDmAccepted(myUid: current.uid, otherLoginLower: key);
      if (!accepted) {
        try {
          await _sendDmRequest(
            myUid: current.uid,
            myLogin: myLogin,
            otherUid: uid,
            otherLogin: login,
            messageText: '', // Send invite without message
            otherAvatarUrl: avatarUrl,
          );
        } catch (_) {
          // Ignore errors when sending invite
        }
      }

      setState(() {
        _index = 1; // Chaty tab
        _openChatLogin = login;
        _openChatAvatarUrl = avatarUrl;
        _openChatToken++;
      });
    }();
  }

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = _AppLifecycleObserver(onChanged: _onLifecycle);
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _listenPresenceSettings();
    unawaited(_initDeviceSession());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _connectedSub?.cancel();
    _presenceEnabledSub?.cancel();
    _deviceSessionSub?.cancel();
    super.dispose();
  }

  Future<void> _initDeviceSession() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final deviceId = await _getOrCreateLocalDeviceId();
    if (!mounted) return;

    _currentDeviceId = deviceId;
    _currentDeviceLoginAt = DateTime.now().millisecondsSinceEpoch;

    final online = _presenceEnabled ? (_presenceStatus != 'hidden') : false;
    final ref = rtdb().ref('deviceSessions/${current.uid}/$deviceId');
    await ref.update({
      'deviceId': deviceId,
      'platform': _devicePlatformLabel(),
      'deviceName': _deviceNameLabel(),
      'online': online,
      'status': _presenceStatus,
      'loginAt': _currentDeviceLoginAt,
      'lastSeenAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });

    try {
      await ref.onDisconnect().update({
        'online': false,
        'lastSeenAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {}

    _deviceSessionSub?.cancel();
    _deviceSessionSub = ref.onValue.listen((event) async {
      final v = event.snapshot.value;
      if (v is! Map) return;
      final m = Map<String, dynamic>.from(v);
      final forceLogoutAt = (m['forceLogoutAt'] is int)
          ? m['forceLogoutAt'] as int
          : int.tryParse((m['forceLogoutAt'] ?? '').toString()) ?? 0;

      if (forceLogoutAt <= 0) return;
      if (forceLogoutAt <= _currentDeviceLoginAt) return;

      await _logout();
    });
  }

  Future<void> _updateDeviceSessionOnline(bool online) async {
    final current = FirebaseAuth.instance.currentUser;
    final deviceId = _currentDeviceId;
    if (current == null || deviceId == null || deviceId.isEmpty) return;

    await rtdb().ref('deviceSessions/${current.uid}/$deviceId').update({
      'online': online,
      'status': _presenceStatus,
      'lastSeenAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });
  }

  void _onLifecycle(AppLifecycleState state) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final shouldBeOnline = state == AppLifecycleState.resumed && _presenceEnabled && _presenceStatus != 'hidden';
    unawaited(_updateDeviceSessionOnline(shouldBeOnline));
    if (!_presenceEnabled) return;
    final presenceRef = rtdb().ref('presence/${current.uid}');
    _ensurePresenceSessionId();
    final sessionRef = _presenceSessionRef(current.uid);

    if (state == AppLifecycleState.resumed) {
      final online = _presenceStatus != 'hidden';
      presenceRef.update({'enabled': true, 'status': _presenceStatus, 'online': online, 'lastChangedAt': ServerValue.timestamp});
      sessionRef?.update({'online': online, 'status': _presenceStatus, 'lastSeenAt': ServerValue.timestamp});
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      presenceRef.update({'enabled': true, 'status': _presenceStatus, 'online': false, 'lastChangedAt': ServerValue.timestamp});
      sessionRef?.update({'online': false, 'status': _presenceStatus, 'lastSeenAt': ServerValue.timestamp});
    }
  }

  String _ensurePresenceSessionId() {
    if (_presenceSessionId != null && _presenceSessionId!.isNotEmpty) return _presenceSessionId!;
    final id = rtdb().ref().push().key ?? DateTime.now().microsecondsSinceEpoch.toString();
    _presenceSessionId = id;
    return id;
  }

  DatabaseReference? _presenceSessionRef(String uid) {
    if (_presenceSessionId == null || _presenceSessionId!.isEmpty) return null;
    return rtdb().ref('presenceSessions/$uid/${_presenceSessionId!}');
  }

  Future<void> _cleanupStalePresenceSessions(String uid) async {
    final snap = await rtdb().ref('presenceSessions/$uid').get();
    final v = snap.value;
    final m = (v is Map) ? Map<String, dynamic>.from(v) : null;
    if (m == null || m.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - _presenceSessionTtl.inMilliseconds;
    final updates = <String, Object?>{};

    for (final entry in m.entries) {
      final key = entry.key.toString();
      final val = entry.value;
      if (val is! Map) {
        updates['presenceSessions/$uid/$key'] = null;
        continue;
      }
      final mm = Map<String, dynamic>.from(val);
      final lastSeen = (mm['lastSeenAt'] is int) ? mm['lastSeenAt'] as int : int.tryParse((mm['lastSeenAt'] ?? '').toString()) ?? 0;
      if (lastSeen > 0 && lastSeen < cutoff) {
        updates['presenceSessions/$uid/$key'] = null;
      }
    }

    if (updates.isNotEmpty) {
      await rtdb().ref().update(updates);
    }
  }

  void _listenPresenceSettings() {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final settingsRef = rtdb().ref('settings/${current.uid}');

    _presenceEnabledSub = settingsRef.onValue.listen((event) {
      final v = event.snapshot.value;
      final m = (v is Map) ? v : null;
      final presenceEnabledValue = (m == null) ? null : m['presenceEnabled'];
      final enabled = (presenceEnabledValue is bool) ? presenceEnabledValue : true;
      final status = ((m == null) ? 'online' : (m['presenceStatus'] ?? 'online')).toString();

      _presenceEnabled = enabled;
      _presenceStatus = (status == 'dnd' || status == 'hidden') ? status : 'online';

      if (!_presenceEnabled) {
        _connectedSub?.cancel();
        _connectedSub = null;
        _presenceInitialized = false;
        _onlinePresenceNotifySent = false;
        rtdb().ref('presence/${current.uid}').set({
          'enabled': false,
          'status': _presenceStatus,
          'online': false,
          'lastChangedAt': ServerValue.timestamp,
        });
        final sessionRef = _presenceSessionRef(current.uid);
        sessionRef?.remove();
      } else {
        _initPresence();
        _updatePresenceNow(current.uid);
      }
    });
  }

  void _updatePresenceNow(String uid) {
    if (!_presenceEnabled) return;
    final presenceRef = rtdb().ref('presence/$uid');
    _ensurePresenceSessionId();
    final sessionRef = _presenceSessionRef(uid);
    final online = _presenceStatus != 'hidden';
    unawaited(_updateDeviceSessionOnline(online));
    presenceRef.update({
      'enabled': true,
      'status': _presenceStatus,
      'online': online,
      'lastChangedAt': ServerValue.timestamp,
    });
    sessionRef?.update({
      'online': online,
      'status': _presenceStatus,
      'lastSeenAt': ServerValue.timestamp,
    });

    // Send online notification to all DM contacts if just went online
    if (!online) {
      _onlinePresenceNotifySent = false;
      return;
    }

    if (!_onlinePresenceNotifySent) {
      _onlinePresenceNotifySent = true;
      unawaited(_notifyContactsOnline(uid));
    }
  }

  Future<void> _notifyContactsOnline(String myUid) async {
    var myLogin = await _myGithubUsernameFromRtdb(myUid) ?? '';
    if (myLogin.isEmpty) {
      final current = FirebaseAuth.instance.currentUser;
      myLogin = (current?.displayName ?? '').trim();
    }
    if (myLogin.isEmpty) {
      myLogin = myUid.substring(0, myUid.length < 8 ? myUid.length : 8);
    }
    // Find all DM contacts
    final snap = await rtdb().ref('savedChats/$myUid').get();
    final v = snap.value;
    if (v is! Map) return;
    for (final entry in v.entries) {
      final contact = entry.value;
      if (contact is! Map) continue;
      final login = (contact['login'] ?? '').toString();
      if (login.isEmpty) continue;
      final contactUid = await _lookupUidForLoginLower(login.trim().toLowerCase());
      if (contactUid == null || contactUid == myUid) continue;
      await AppNotifications.notifyOnlinePresence(toUid: contactUid, fromUid: myUid, fromLogin: myLogin);
    }
  }

  void _initPresence() {
    if (_presenceInitialized) return;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    if (!_presenceEnabled) return;
    _presenceInitialized = true;

    final connectedRef = rtdb().ref('.info/connected');
    final presenceRef = rtdb().ref('presence/${current.uid}');
    _ensurePresenceSessionId();
    final sessionRef = _presenceSessionRef(current.uid);

    _connectedSub = connectedRef.onValue.listen((event) async {
      final connected = event.snapshot.value == true;
      if (!connected) {
        _onlinePresenceNotifySent = false;
        return;
      }

      final online = _presenceStatus != 'hidden';
      unawaited(_updateDeviceSessionOnline(online));

      await _cleanupStalePresenceSessions(current.uid);

      await presenceRef.onDisconnect().set({
        'enabled': true,
        'status': _presenceStatus,
        'online': false,
        'lastChangedAt': ServerValue.timestamp,
      });
      await presenceRef.set({
        'enabled': true,
        'status': _presenceStatus,
        'online': online,
        'lastChangedAt': ServerValue.timestamp,
      });

      if (sessionRef != null) {
        await sessionRef.onDisconnect().remove();
        await sessionRef.set({
          'online': online,
          'status': _presenceStatus,
          'platform': _devicePlatformLabel(),
          'lastSeenAt': ServerValue.timestamp,
        });
      }

      if (online && !_onlinePresenceNotifySent) {
        _onlinePresenceNotifySent = true;
        await _notifyContactsOnline(current.uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    final settingsRef = (current == null) ? null : rtdb().ref('settings/${current.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef?.onValue,
      builder: (context, snapshot) {
        final settings = UserSettings.fromSnapshot(snapshot.data?.snapshot.value);

        final pages = <Widget>[
          const _JobsTab(),
          _ChatsTab(
            key: _chatsKey,
            initialOpenLogin: _openChatLogin,
            initialOpenAvatarUrl: _openChatAvatarUrl,
            settings: settings,
            openChatToken: _openChatToken,
            overviewToken: _chatsOverviewToken,
          ),
          _ContactsTab(onStartChat: _openChat, vibrationEnabled: settings.vibrationEnabled),
          _SettingsTab(onLogout: _logout, settings: settings),
          _ProfileTab(vibrationEnabled: settings.vibrationEnabled),
        ];

        final useLeftMenu = kIsWeb && MediaQuery.of(context).size.width >= 1000;

        return WillPopScope(
          onWillPop: _onWillPop,
          child: useLeftMenu
              ? Scaffold(
                  body: SafeArea(
                    child: Row(
                      children: [
                        _leftSideNav(context, vibrationEnabled: settings.vibrationEnabled),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            children: [
                              _pillAppBar(context),
                              Expanded(child: pages[_index]),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : Scaffold(
                  appBar: _pillAppBar(context),
                  body: pages[_index],
                  bottomNavigationBar: _pillBottomNav(context, vibrationEnabled: settings.vibrationEnabled),
                ),
        );
      },
    );
  }
}

class _GithubUserSearchSheet extends StatefulWidget {
  const _GithubUserSearchSheet({required this.title});

  final String title;

  @override
  State<_GithubUserSearchSheet> createState() => _GithubUserSearchSheetState();
}

class _GithubUserSearchSheetState extends State<_GithubUserSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<GithubUser> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final query = value.trim();
      if (query.isEmpty) {
        if (!mounted) return;
        setState(() {
          _results = const [];
          _error = null;
          _loading = false;
        });
        return;
      }

      setState(() {
        _loading = true;
        _error = null;
      });

      try {
        final users = await searchGithubUsers(query);
        if (!mounted) return;
        setState(() {
          _results = users;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  controller: _controller,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    labelText: AppLanguage.tr(context, 'Hledat na GitHubu', 'Search on GitHub'),
                    prefixText: '@',
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final u = _results[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
                      ),
                      title: Text('@${u.login}'),
                      onTap: () => Navigator.of(context).pop(u),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UserSettings {
  const UserSettings({
    required this.chatTextSize,
    required this.bubbleRadius,
    required this.bubbleIncoming,
    required this.bubbleOutgoing,
    required this.wallpaperUrl,
    required this.reactionsEnabled,
    required this.stickersEnabled,
    required this.autoDeleteSeconds,
    required this.presenceEnabled,
    required this.presenceStatus,
    required this.giftsVisible,
    required this.vibrationEnabled,
    required this.soundsEnabled,
    required this.notificationsEnabled,
    required this.dataAllowWifi,
    required this.dataAllowMobile,
    required this.dataAllowRoaming,
    required this.dataSaverEnabled,
    required this.savePrivatePhotos,
    required this.savePrivateVideos,
    required this.saveGroupPhotos,
    required this.saveGroupVideos,
    required this.language,
  });

  final double chatTextSize;
  final double bubbleRadius;
  final String bubbleIncoming;
  final String bubbleOutgoing;
  final String wallpaperUrl;
  final bool reactionsEnabled;
  final bool stickersEnabled;
  final int autoDeleteSeconds;
  final bool presenceEnabled;
  final String presenceStatus; // online | dnd | hidden
  final bool giftsVisible;
  final bool vibrationEnabled;
  final bool soundsEnabled;
  final bool notificationsEnabled;
  final bool dataAllowWifi;
  final bool dataAllowMobile;
  final bool dataAllowRoaming;
  final bool dataSaverEnabled;
  final bool savePrivatePhotos;
  final bool savePrivateVideos;
  final bool saveGroupPhotos;
  final bool saveGroupVideos;
  final String language;

  static UserSettings fromSnapshot(Object? value) {
    final m = (value is Map) ? value : null;
    double readDouble(String k, double d) {
      final v = m?[k];
      if (v is num) return v.toDouble();
      return d;
    }

    int readInt(String k, int d) {
      final v = m?[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return d;
    }

    bool readBool(String k, bool d) {
      final v = m?[k];
      if (v is bool) return v;
      return d;
    }

    String readString(String k, String d) {
      final v = m?[k];
      if (v == null) return d;
      return v.toString();
    }

    final status = readString('presenceStatus', 'online');
    final normalizedStatus = (status == 'dnd' || status == 'hidden') ? status : 'online';

    return UserSettings(
      chatTextSize: readDouble('chatTextSize', 16),
      bubbleRadius: readDouble('bubbleRadius', 12),
      bubbleIncoming: readString('bubbleIncoming', 'surface'),
      bubbleOutgoing: readString('bubbleOutgoing', 'secondaryContainer'),
      wallpaperUrl: readString('wallpaperUrl', ''),
      reactionsEnabled: readBool('reactionsEnabled', true),
      stickersEnabled: readBool('stickersEnabled', false),
      autoDeleteSeconds: readInt('autoDeleteSeconds', 0),
      presenceEnabled: readBool('presenceEnabled', true),
      presenceStatus: normalizedStatus,
      giftsVisible: readBool('giftsVisible', true),
      vibrationEnabled: readBool('vibrationEnabled', true),
      soundsEnabled: readBool('soundsEnabled', true),
      notificationsEnabled: readBool('notificationsEnabled', true),
      dataAllowWifi: readBool('dataAllowWifi', true),
      dataAllowMobile: readBool('dataAllowMobile', true),
      dataAllowRoaming: readBool('dataAllowRoaming', false),
      dataSaverEnabled: readBool('dataSaverEnabled', false),
      savePrivatePhotos: readBool('savePrivatePhotos', false),
      savePrivateVideos: readBool('savePrivateVideos', false),
      saveGroupPhotos: readBool('saveGroupPhotos', false),
      saveGroupVideos: readBool('saveGroupVideos', false),
      language: readString('language', 'cs'),
    );
  }
}

Color _resolveBubbleColor(BuildContext context, String key) {
  const custom = <String, Color>{
    'custom_01': Color(0xFFEF5350),
    'custom_02': Color(0xFFEC407A),
    'custom_03': Color(0xFFAB47BC),
    'custom_04': Color(0xFF7E57C2),
    'custom_05': Color(0xFF5C6BC0),
    'custom_06': Color(0xFF42A5F5),
    'custom_07': Color(0xFF26C6DA),
    'custom_08': Color(0xFF26A69A),
    'custom_09': Color(0xFF66BB6A),
    'custom_10': Color(0xFF9CCC65),
    'custom_11': Color(0xFFD4E157),
    'custom_12': Color(0xFFFFCA28),
    'custom_13': Color(0xFFFFA726),
    'custom_14': Color(0xFF8D6E63),
    'custom_15': Color(0xFF90A4AE),
  };
  if (custom.containsKey(key)) return custom[key]!;

  final cs = Theme.of(context).colorScheme;
  switch (key) {
    case 'primary':
      return cs.primary;
    case 'secondary':
      return cs.secondary;
    case 'tertiary':
      return cs.tertiary;
    case 'error':
      return cs.error;
    case 'surfaceVariant':
      return cs.surfaceVariant;
    case 'primaryContainer':
      return cs.primaryContainer;
    case 'secondaryContainer':
      return cs.secondaryContainer;
    case 'tertiaryContainer':
      return cs.tertiaryContainer;
    case 'inverseSurface':
      return cs.inverseSurface;
    case 'surfaceTint':
      return cs.surfaceTint;
    case 'surface':
    default:
      return cs.surface;
  }
}

Color _resolveBubbleTextColor(BuildContext context, String key) {
  const custom = <String, Color>{
    'custom_01': Color(0xFFEF5350),
    'custom_02': Color(0xFFEC407A),
    'custom_03': Color(0xFFAB47BC),
    'custom_04': Color(0xFF7E57C2),
    'custom_05': Color(0xFF5C6BC0),
    'custom_06': Color(0xFF42A5F5),
    'custom_07': Color(0xFF26C6DA),
    'custom_08': Color(0xFF26A69A),
    'custom_09': Color(0xFF66BB6A),
    'custom_10': Color(0xFF9CCC65),
    'custom_11': Color(0xFFD4E157),
    'custom_12': Color(0xFFFFCA28),
    'custom_13': Color(0xFFFFA726),
    'custom_14': Color(0xFF8D6E63),
    'custom_15': Color(0xFF90A4AE),
  };
  if (custom.containsKey(key)) {
    final c = custom[key]!;
    return c.computeLuminance() > 0.56 ? Colors.black : Colors.white;
  }

  final cs = Theme.of(context).colorScheme;
  switch (key) {
    case 'primary':
      return cs.onPrimary;
    case 'secondary':
      return cs.onSecondary;
    case 'tertiary':
      return cs.onTertiary;
    case 'error':
      return cs.onError;
    case 'surfaceVariant':
      return cs.onSurfaceVariant;
    case 'primaryContainer':
      return cs.onPrimaryContainer;
    case 'secondaryContainer':
      return cs.onSecondaryContainer;
    case 'tertiaryContainer':
      return cs.onTertiaryContainer;
    case 'inverseSurface':
      return cs.onInverseSurface;
    case 'surfaceTint':
      return cs.onSurface;
    case 'surface':
    default:
      return cs.onSurface;
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver({required this.onChanged});

  final void Function(AppLifecycleState state) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChanged(state);
  }
}

class _AvatarWithPresenceDot extends StatelessWidget {
  const _AvatarWithPresenceDot({required this.uid, required this.avatarUrl, required this.radius});

  final String uid;
  final String? avatarUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final baseAvatar = (avatarUrl != null && avatarUrl!.isNotEmpty)
        ? CircleAvatar(radius: radius, backgroundImage: NetworkImage(avatarUrl!))
        : CircleAvatar(radius: radius, child: Icon(Icons.person, size: radius));

    final presenceRef = rtdb().ref('presence/$uid');

    return StreamBuilder<DatabaseEvent>(
      stream: presenceRef.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        final m = (v is Map) ? v : null;
        final enabled = m?['enabled'] != false;
        final status = (m?['status'] ?? 'online').toString();
        final online = enabled && (m?['online'] == true);

        final Color dotColor;
        if (!enabled) {
          dotColor = Colors.white;
        } else if (status == 'dnd') {
          dotColor = Colors.redAccent;
        } else if (status == 'hidden') {
          dotColor = Colors.transparent;
        } else {
          dotColor = online ? Colors.green : Colors.white;
        }
        final dotBorder = Theme.of(context).colorScheme.surface;
        final showDot = dotColor.opacity > 0;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            baseAvatar,
            if (showDot)
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: radius * 0.42,
                  height: radius * 0.42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    border: Border.all(color: dotBorder, width: 2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChatLoginAvatar extends StatefulWidget {
  const _ChatLoginAvatar({required this.login, required this.avatarUrl, required this.radius});

  final String login;
  final String avatarUrl;
  final double radius;

  @override
  State<_ChatLoginAvatar> createState() => _ChatLoginAvatarState();
}

class _ChatLoginAvatarState extends State<_ChatLoginAvatar> {
  String? _uid;

  @override
  void initState() {
    super.initState();
    _lookupUid();
  }

  @override
  void didUpdateWidget(covariant _ChatLoginAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.login.trim().toLowerCase() != widget.login.trim().toLowerCase()) {
      _uid = null;
      _lookupUid();
    }
  }

  Future<void> _lookupUid() async {
    final key = widget.login.trim().toLowerCase();
    if (key.isEmpty) return;

    final snap = await rtdb().ref('usernames/$key').get();
    final val = snap.value;
    if (!mounted) return;
    setState(() {
      _uid = (val == null) ? null : val.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_uid == null) {
      return (widget.avatarUrl.isNotEmpty)
          ? CircleAvatar(radius: widget.radius, backgroundImage: NetworkImage(widget.avatarUrl))
          : CircleAvatar(radius: widget.radius, child: Icon(Icons.person, size: widget.radius));
    }

    return _AvatarWithPresenceDot(uid: _uid!, avatarUrl: widget.avatarUrl, radius: widget.radius);
  }
}


enum _JobsAudience {
  seekers,
  companies,
}

extension on _JobsAudience {
  // Removed unused getter groupId

  String get feedPath {
    switch (this) {
      case _JobsAudience.seekers:
        return 'jobs/posts/seekers';
      case _JobsAudience.companies:
        return 'jobs/posts/companies';
    }
  }

  String tabTitle(BuildContext context) {
    switch (this) {
      case _JobsAudience.seekers:
        return AppLanguage.tr(context, 'Hledám práci', 'Looking for work');
      case _JobsAudience.companies:
        return AppLanguage.tr(context, 'Hledám lidi', 'Looking for people');
    }
  }

  String addLabel(BuildContext context) {
    switch (this) {
      case _JobsAudience.seekers:
        return AppLanguage.tr(context, 'Přidat profil', 'Add profile');
      case _JobsAudience.companies:
        return AppLanguage.tr(context, 'Přidat nabídku', 'Add listing');
    }
  }

  String composerTitle(BuildContext context) {
    switch (this) {
      case _JobsAudience.seekers:
        return AppLanguage.tr(context, 'Nový profil kandidáta', 'New candidate profile');
      case _JobsAudience.companies:
        return AppLanguage.tr(context, 'Nová pracovní nabídka', 'New job listing');
    }
  }

  String titleHint(BuildContext context) {
    switch (this) {
      case _JobsAudience.seekers:
        return AppLanguage.tr(context, 'Např. Flutter vývojář / Remote / Senior', 'e.g. Flutter developer / Remote / Senior');
      case _JobsAudience.companies:
        return AppLanguage.tr(context, 'Např. ACME hledá Senior Flutter vývojáře', 'e.g. ACME is looking for a Senior Flutter developer');
    }
  }

  String bodyHint(BuildContext context) {
    switch (this) {
      case _JobsAudience.seekers:
        return AppLanguage.tr(
          context,
          'Napiš krátké info o sobě, stack, zkušenosti, dostupnost.\n\nPodporujeme emoji, odrážky, odkazy a kód:\n- Dart\n- Flutter\n\n```dart\nprint("hello");\n```',
          'Write a short intro about yourself, stack, experience, and availability.\n\nWe support emoji, bullet points, links, and code:\n- Dart\n- Flutter\n\n```dart\nprint("hello");\n```',
        );
      case _JobsAudience.companies:
        return AppLanguage.tr(
          context,
          'Popiš roli, požadavky, benefity a kontakt.\n\nPodporujeme emoji, odrážky, odkazy a kód:\n- TypeScript\n- CI/CD\n\n```yaml\nname: build\n```',
          'Describe the role, requirements, benefits, and contact details.\n\nWe support emoji, bullet points, links, and code:\n- TypeScript\n- CI/CD\n\n```yaml\nname: build\n```',
        );
    }
  }
}

class _JobsPostView {
  const _JobsPostView({
    required this.id,
    required this.title,
    required this.body,
    required this.authorUid,
    required this.author,
    required this.authorAvatarUrl,
    required this.stackTags,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String body;
  final String authorUid;
  final String author;
  final String authorAvatarUrl;
  final List<String> stackTags;
  final DateTime createdAt;
}

class _JobsTab extends StatefulWidget {
  const _JobsTab();

  @override
  State<_JobsTab> createState() => _JobsTabState();
}

class _JobsTabState extends State<_JobsTab> {
  _JobsAudience _audience = _JobsAudience.seekers;
  bool _posting = false;
  String _stackFilter = 'All';

  static const List<String> _stackFilters = <String>[
    'All',
    'Flutter',
    'React',
    'Node',
    'Python',
    'DevOps',
  ];

  List<String> _normalizeStackTags(String raw) {
    final tags = raw
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return tags.take(8).toList(growable: false);
  }

  Future<String> _githubLoginForUid(String uid) async {
    final snap = await rtdb().ref('users/$uid/githubUsername').get();
    final value = snap.value?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
    return uid;
  }

  Future<String?> _avatarUrlForUid(String uid) async {
    final snap = await rtdb().ref('users/$uid/avatarUrl').get();
    final value = snap.value?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  Future<void> _createPost({
    required _JobsAudience audience,
    required String title,
    required String body,
    required List<String> stackTags,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _posting = true);
    try {
      final author = await _githubLoginForUid(user.uid);
      final avatarUrl = await _avatarUrlForUid(user.uid);

      final postRef = rtdb().ref(audience.feedPath).push();
      await postRef.set({
        'title': title,
        'body': body,
        'stackTags': stackTags,
        'authorUid': user.uid,
        'author': author,
        if (avatarUrl != null) 'authorAvatarUrl': avatarUrl,
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });
    } finally {
      if (mounted) {
        setState(() => _posting = false);
      }
    }
  }

  Future<void> _updatePost({
    required _JobsAudience audience,
    required _JobsPostView post,
    required String title,
    required String body,
    required List<String> stackTags,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || post.authorUid != user.uid) return;

    setState(() => _posting = true);
    try {
      await rtdb().ref('${audience.feedPath}/${post.id}').update({
        'title': title,
        'body': body,
        'stackTags': stackTags,
        'updatedAt': ServerValue.timestamp,
      });
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _deletePost({
    required _JobsAudience audience,
    required _JobsPostView post,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || post.authorUid != user.uid) return;
    await rtdb().ref('${audience.feedPath}/${post.id}').remove();
  }

  Future<List<_JobsPostView>> _readPosts(Object? value) async {
    final map = (value is Map) ? Map<dynamic, dynamic>.from(value) : <dynamic, dynamic>{};
    if (map.isEmpty) return const [];
    final posts = <_JobsPostView>[];

    for (final entry in map.entries) {
      final id = entry.key.toString();
      final raw = entry.value;
      if (raw is! Map) continue;

      final m = Map<String, dynamic>.from(raw);
      final createdMs = (m['createdAt'] is int)
          ? m['createdAt'] as int
          : int.tryParse((m['createdAt'] ?? '').toString()) ?? 0;
      final author = (m['author'] ?? '').toString().trim();
      final authorUid = (m['authorUid'] ?? '').toString().trim();
        final authorAvatarUrl = (m['authorAvatarUrl'] ?? '').toString().trim();
      final title = (m['title'] ?? '').toString().trim();
      final body = (m['body'] ?? '').toString();
      final stacksRaw = m['stackTags'];
      final stackTags = <String>[];
      if (stacksRaw is List) {
        for (final item in stacksRaw) {
          final s = item?.toString().trim() ?? '';
          if (s.isNotEmpty) stackTags.add(s);
        }
      } else if (stacksRaw is String) {
        stackTags.addAll(_normalizeStackTags(stacksRaw));
      }
      if (title.isEmpty || body.trim().isEmpty) continue;

      posts.add(
        _JobsPostView(
          id: id,
          title: title,
          body: body,
          authorUid: authorUid,
          author: author.isEmpty ? 'unknown' : author,
          authorAvatarUrl: authorAvatarUrl,
          stackTags: stackTags,
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs > 0 ? createdMs : 0),
        ),
      );
    }

    posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return posts;
  }

  String _timeLabel(DateTime dt) {
    if (dt.millisecondsSinceEpoch <= 0) return 'teď';
    final now = DateTime.now();
    final d = now.difference(dt);
    if (d.inMinutes < 1) return 'právě teď';
    if (d.inHours < 1) return 'před ${d.inMinutes} min';
    if (d.inDays < 1) return 'před ${d.inHours} h';
    return 'před ${d.inDays} d';
  }

  Future<void> _openComposer(_JobsAudience audience, {_JobsPostView? editingPost}) async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final stackCtrl = TextEditingController();
    if (editingPost != null) {
      titleCtrl.text = editingPost.title;
      bodyCtrl.text = editingPost.body;
      stackCtrl.text = editingPost.stackTags.join(', ');
    }
    String? localError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocalState) {
            final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;
            return SafeArea(
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: bottomInset),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Text(
                      editingPost == null ? audience.composerTitle(context) : AppLanguage.tr(context, 'Upravit příspěvek', 'Edit post'),
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleCtrl,
                      textInputAction: TextInputAction.next,
                      maxLength: 140,
                      decoration: InputDecoration(
                        labelText: AppLanguage.tr(context, 'Nadpis', 'Title'),
                        hintText: audience.titleHint(context),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: stackCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: AppLanguage.tr(context, 'Stack / tagy', 'Stack / tags'),
                        hintText: AppLanguage.tr(context, 'Flutter, Firebase, React, DevOps...', 'Flutter, Firebase, React, DevOps...'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: bodyCtrl,
                      minLines: 7,
                      maxLines: 14,
                      decoration: InputDecoration(
                        labelText: AppLanguage.tr(context, 'Text (Markdown)', 'Text (Markdown)'),
                        hintText: audience.bodyHint(context),
                        alignLabelWithHint: true,
                      ),
                    ),
                    if (localError != null) ...[
                      const SizedBox(height: 8),
                      Text(localError!, style: const TextStyle(color: Colors.redAccent)),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _posting ? null : () => Navigator.of(ctx).pop(),
                            child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _posting
                                ? null
                                : () async {
                                    final title = titleCtrl.text.trim();
                                    final body = bodyCtrl.text.trim();
                                    final stackTags = _normalizeStackTags(stackCtrl.text);
                                    if (title.isEmpty || body.isEmpty) {
                                      setLocalState(() {
                                        localError = AppLanguage.tr(context, 'Vyplň nadpis i text.', 'Fill in title and text.');
                                      });
                                      return;
                                    }

                                    try {
                                      if (editingPost == null) {
                                        await _createPost(
                                          audience: audience,
                                          title: title,
                                          body: body,
                                          stackTags: stackTags,
                                        );
                                      } else {
                                        await _updatePost(
                                          audience: audience,
                                          post: editingPost,
                                          title: title,
                                          body: body,
                                          stackTags: stackTags,
                                        );
                                      }
                                      if (!mounted) return;
                                      Navigator.of(ctx).pop();
                                    } catch (e) {
                                      setLocalState(() {
                                        localError = e.toString();
                                      });
                                    }
                                  },
                            icon: _posting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Icon(editingPost == null ? Icons.add : Icons.save_outlined),
                            label: Text(_posting ? AppLanguage.tr(context, 'Ukládám...', 'Saving...') : (editingPost == null ? AppLanguage.tr(context, 'Přidat', 'Add') : AppLanguage.tr(context, 'Uložit', 'Save'))),
                          ),
                        ),
                      ],
                    ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _audienceSwitch() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _JobsTabButton(
              label: _JobsAudience.seekers.tabTitle(context),
              selected: _audience == _JobsAudience.seekers,
              onTap: () => setState(() => _audience = _JobsAudience.seekers),
            ),
          ),
          Expanded(
            child: _JobsTabButton(
              label: _JobsAudience.companies.tabTitle(context),
              selected: _audience == _JobsAudience.companies,
              onTap: () => setState(() => _audience = _JobsAudience.companies),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stackFilterBar() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _stackFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final stack = _stackFilters[index];
          return ChoiceChip(
            label: Text(stack),
            selected: _stackFilter == stack,
            onSelected: (_) => setState(() => _stackFilter = stack),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feedRef = rtdb().ref(_audience.feedPath);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: _audienceSwitch(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 10, 8),
          child: Row(
            children: [
              Text(
                _audience == _JobsAudience.seekers
                  ? AppLanguage.tr(context, 'Lidé, kteří hledají práci', 'People looking for work')
                  : AppLanguage.tr(context, 'Firmy, které hledají lidi', 'Companies looking for people'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: _audience.addLabel(context),
                onPressed: _posting ? null : () => _openComposer(_audience),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ),
        _stackFilterBar(),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: feedRef.onValue,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              return FutureBuilder<List<_JobsPostView>>(
                future: _readPosts(snapshot.data?.snapshot.value),
                builder: (context, postsSnap) {
                  if (postsSnap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (postsSnap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '${AppLanguage.tr(context, 'Nepodařilo se načíst Jobs feed.', 'Failed to load Jobs feed.')} ${postsSnap.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  var posts = postsSnap.data ?? const <_JobsPostView>[];
                  if (_stackFilter != 'All') {
                    posts = posts
                        .where((p) => p.stackTags.any((s) => s.toLowerCase() == _stackFilter.toLowerCase()))
                        .toList(growable: false);
                  }
                  if (posts.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _audience == _JobsAudience.seekers
                              ? AppLanguage.tr(context, 'Zatím tu nejsou žádné profily. Přidej první přes +.', 'No profiles here yet. Add the first one with +.')
                              : AppLanguage.tr(context, 'Zatím tu nejsou žádné nabídky. Přidej první přes +.', 'No listings here yet. Add the first one with +.'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                    itemCount: posts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final post = posts[index];
                      final currentUid = FirebaseAuth.instance.currentUser?.uid;
                      final isMine = currentUid != null && post.authorUid == currentUid;
                      return _JobsPostCard(
                        post: post,
                        timeLabel: _timeLabel(post.createdAt),
                        isMine: isMine,
                        onOpenProfile: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _UserProfilePage(
                                login: post.author,
                                avatarUrl: post.authorAvatarUrl,
                                githubDataFuture: _fetchGithubProfileData(post.author),
                              ),
                            ),
                          );
                        },
                        onEdit: isMine ? () => _openComposer(_audience, editingPost: post) : null,
                        onDelete: isMine
                            ? () async {
                                final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: Text(AppLanguage.tr(context, 'Smazat příspěvek?', 'Delete post?')),
                                        content: Text(AppLanguage.tr(context, 'Tato akce nejde vrátit zpět.', 'This action cannot be undone.')),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(ctx).pop(false),
                                            child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel')),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.of(ctx).pop(true),
                                            child: Text(AppLanguage.tr(context, 'Smazat', 'Delete')),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                                if (!ok) return;
                                await _deletePost(audience: _audience, post: post);
                              }
                            : null,
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _JobsTabButton extends StatelessWidget {
  const _JobsTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? cs.secondary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: selected ? cs.onSecondary : cs.onSurface,
          ),
        ),
      ),
    );
  }
}

class _JobsPostCard extends StatelessWidget {
  const _JobsPostCard({
    required this.post,
    required this.timeLabel,
    required this.isMine,
    this.onOpenProfile,
    this.onEdit,
    this.onDelete,
  });

  final _JobsPostView post;
  final String timeLabel;
  final bool isMine;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onOpenProfile,
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.outlineVariant),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  post.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.public, size: 16),
              if (isMine)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (value) {
                    if (value == 'edit') {
                      onEdit?.call();
                    } else if (value == 'delete') {
                      onDelete?.call();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('Upravit')),
                    PopupMenuItem(value: 'delete', child: Text('Smazat')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '@${post.author} • $timeLabel',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
          if (post.stackTags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: post.stackTags
                  .map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white10,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(tag, style: Theme.of(context).textTheme.bodySmall),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          const SizedBox(height: 8),
          _RichMessageText(
            text: post.body,
            fontSize: 14,
            textColor: Theme.of(context).colorScheme.onSurface,
          ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.onLogout, required this.settings});
  final VoidCallback onLogout;
  final UserSettings settings;

  @override
  Widget build(BuildContext context) {
    return _SettingsHome(onLogout: onLogout);
  }
}

class _Debouncer {
  _Debouncer(this.delay);
  final Duration delay;
  Timer? _t;

  void run(VoidCallback action) {
    _t?.cancel();
    _t = Timer(delay, action);
  }

  void dispose() {
    _t?.cancel();
  }
}

class _SettingsHome extends StatelessWidget {
  const _SettingsHome({required this.onLogout});
  final VoidCallback onLogout;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return Center(child: Text(AppLanguage.tr(context, 'Nepřihlášen.', 'Not signed in.')));
    final userRef = rtdb().ref('users/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: userRef.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        final m = (v is Map) ? v : null;
        final gh = (m?['githubUsername'] ?? '').toString();
        final avatar = (m?['avatarUrl'] ?? '').toString();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          children: [
            Center(
              child: Column(
                children: [
                  _AvatarWithPresenceDot(uid: u.uid, avatarUrl: avatar, radius: 44),
                  const SizedBox(height: 12),
                  Text(
                    gh.isNotEmpty ? gh : 'GitMit',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            _SettingsSectionTile(
              icon: Icons.person_outline,
              title: AppLanguage.tr(context, 'Účet', 'Account'),
              subtitle: AppLanguage.tr(context, 'Telefon, narozeniny, bio, účty', 'Phone, birthday, bio, linked accounts'),
              onTap: () => _open(context, _SettingsAccountPage(onLogout: onLogout)),
            ),
            _SettingsSectionTile(
              icon: Icons.chat_bubble_outline,
              title: AppLanguage.tr(context, 'Nastavení chatů', 'Chat settings'),
              subtitle: AppLanguage.tr(context, 'Obrázek na pozadí, barvy, velikost textu', 'Background, colors, and text size'),
              onTap: () => _open(context, const _SettingsChatPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.lock_outline,
              title: AppLanguage.tr(context, 'Soukromí', 'Privacy'),
              subtitle: AppLanguage.tr(context, 'Auto-delete, status, presence, dárky', 'Auto-delete, status, presence, achievements'),
              onTap: () => _open(context, const _SettingsPrivacyPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.notifications_none,
              title: AppLanguage.tr(context, 'Upozornění', 'Notifications'),
              subtitle: AppLanguage.tr(context, 'Zvuky a vibrace', 'Sounds and vibration'),
              onTap: () => _open(context, const _SettingsNotificationsPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.security_outlined,
              title: AppLanguage.tr(context, 'Šifrování a E2EE', 'Encryption and E2EE'),
              subtitle: AppLanguage.tr(context, 'Jak fungují klíče, fingerprinty a vyhledávání', 'How keys, fingerprints, and search work'),
              onTap: () => _open(context, const _SettingsEncryptionPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.menu_book_outlined,
              title: AppLanguage.tr(context, 'Nápověda a dokumentace', 'Help and documentation'),
              subtitle: AppLanguage.tr(context, 'Podrobný popis funkcí aplikace', 'Detailed app feature guide'),
              onTap: () => _open(context, const _SettingsDocumentationPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.storage_outlined,
              title: AppLanguage.tr(context, 'Data a paměť', 'Data and storage'),
              subtitle: AppLanguage.tr(context, 'Zatím základní', 'Basic controls'),
              onTap: () => _open(context, const _SettingsDataPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.devices_outlined,
              title: AppLanguage.tr(context, 'Zařízení', 'Devices'),
              subtitle: AppLanguage.tr(context, 'Aktivní sezení (brzy)', 'Active sessions'),
              onTap: () => _open(context, _SettingsDevicesPage(onLogout: onLogout)),
            ),
            _SettingsSectionTile(
              icon: Icons.language,
              title: AppLanguage.tr(context, 'Jazyk', 'Language'),
              subtitle: AppLanguage.tr(context, 'Čeština / English', 'Czech / English'),
              onTap: () => _open(context, const _SettingsLanguagePage()),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsSectionTile extends StatelessWidget {
  const _SettingsSectionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _SettingsEncryptionPage extends StatelessWidget {
  const _SettingsEncryptionPage();

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;

    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'Šifrování a E2EE', 'Encryption and E2EE'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(context, 'Jak funguje šifrování', 'How encryption works'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      context,
                      'GitMit používá end-to-end šifrování (E2EE). Obsah zpráv se šifruje na tvém zařízení a na server se ukládá pouze ciphertext.',
                      'GitMit uses end-to-end encryption (E2EE). Message content is encrypted on your device and only ciphertext is stored on the server.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      context,
                      'Pro privátní chaty se používá X25519/Ed25519 a ChaCha20-Poly1305. Pro skupiny je k dispozici sdílený group key (v1) nebo Sender Keys (v2), pokud všichni podporují.',
                      'Private chats use X25519/Ed25519 and ChaCha20-Poly1305. For groups, shared group key (v1) or Sender Keys (v2) are used when supported by all participants.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(context, 'Fingerprinty a ověření', 'Fingerprints and verification'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      context,
                      'Fingerprint je otisk veřejného podpisového klíče (Ed25519). Ověř si ho s protějškem přes jiný kanál (osobně).',
                      'A fingerprint is a hash of the public signing key (Ed25519). Verify it with your peer via another channel (in person).',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      context,
                      'Pokud se fingerprint protějšku změní, může to znamenat reinstall nebo riziko MITM.',
                      'If your peer fingerprint changes, it may indicate a reinstall or a possible MITM risk.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(context, 'Vyhledávání', 'Search'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    t(
                      context,
                      'Vyhledávání funguje pouze nad lokálně dešifrovaným obsahem. Plaintext se neodesílá na server, ukládá se jen na zařízení.',
                      'Search works only over locally decrypted content. Plaintext is not sent to the server and remains only on the device.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsDocumentationPage extends StatelessWidget {
  const _SettingsDocumentationPage();

  Widget _docCard({required String title, required List<String> lines}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $line'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;

    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'Nápověda a dokumentace', 'Help and documentation'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _docCard(
            title: t(context, 'Rychlá orientace', 'Quick overview'),
            lines: [
              t(context, 'Účet: profilové údaje, telefon, bio, odhlášení účtu.', 'Account: profile info, phone, bio, sign-out.'),
              t(context, 'Nastavení chatů: vzhled zpráv, velikost textu, pozadí a reakce.', 'Chat settings: message style, text size, background, and reactions.'),
              t(context, 'Soukromí: auto-delete, online status a viditelnost achievementů.', 'Privacy: auto-delete, online status, and achievement visibility.'),
              t(context, 'Upozornění: notifikace, vibrace a zvuky.', 'Notifications: alerts, vibration, and sounds.'),
              t(context, 'Data a paměť: přenos dat, stahování médií a přehled úložiště.', 'Data and storage: network usage, media downloads, and storage overview.'),
              t(context, 'Zařízení: aktivní relace a vzdálené odhlášení dalších zařízení.', 'Devices: active sessions and remote sign-out for other devices.'),
            ],
          ),
          _docCard(
            title: t(context, 'Šifrování a bezpečnost', 'Encryption and security'),
            lines: [
              t(context, 'Privátní zprávy jsou chráněné E2EE – server nevidí plaintext.', 'Private messages are protected with E2EE — the server cannot read plaintext.'),
              t(context, 'Klíče se navazují mezi účastníky chatu; bez dostupného klíče se zpráva nešifruje.', 'Keys are established between chat participants; without a key, messages cannot be encrypted.'),
              t(context, 'Fingerprint ověřuje identitu klíče a pomáhá odhalit MITM útok.', 'The fingerprint verifies key identity and helps detect MITM attacks.'),
              t(context, 'Fingerprint je potřeba porovnat mimo aplikaci (osobně nebo přes jiný důvěryhodný kanál).', 'Fingerprint should be verified out-of-band (in person or via another trusted channel).'),
              t(context, 'Při změně zařízení může dojít ke změně klíče a tím i fingerprintu.', 'Changing device may rotate keys and therefore change the fingerprint.'),
            ],
          ),
          _docCard(
            title: t(context, 'Chaty (DM) – jak to funguje', 'Chats (DM) — how it works'),
            lines: [
              t(context, 'Chat lze otevřít s uživatelem, který je dohledatelný přes GitHub login.', 'A chat can be opened with a user discoverable by GitHub login.'),
              t(context, 'Pokud druhá strana není v databázi GitMitu, DM nemusí být možné navázat standardně.', 'If the other side is not in the GitMit database, DM may not be established in the standard way.'),
              t(context, 'V DM můžeš odpovídat na konkrétní zprávy, reagovat emoji a posílat obrázky/kód.', 'In DM, you can reply to messages, react with emoji, and send images/code.'),
              t(context, 'TTL (ničení zpráv) určuje, jak dlouho se zpráva drží po doručení.', 'TTL (message expiry) determines how long a message is retained after delivery.'),
              t(context, 'Po smazání chatu „u mě“ se smažou pouze lokální/uživatelské záznamy tvého účtu.', 'Deleting chat “for me” removes only your local/account-side records.'),
              t(context, 'Smazání „u obou“ vyžaduje dostupnost a správné mapování druhého účtu.', 'Deleting “for both” requires the peer account to be available and correctly mapped.'),
            ],
          ),
          _docCard(
            title: t(context, 'Skupiny a pozvánky', 'Groups and invites'),
            lines: [
              t(context, 'Pozvánky do skupin najdeš v přehledu chatů, můžeš je přijmout nebo odmítnout.', 'Group invites appear in chat overview; you can accept or decline them.'),
              t(context, 'Admin skupiny může schvalovat žádosti a spravovat členy.', 'Group admins can approve requests and manage members.'),
              t(context, 'Některé skupiny používají skupinové klíče (podle podpory klientů).', 'Some groups use group keys (depending on client support).'),
              t(context, 'U skupin vždy kontroluj, kdo tě pozval a do jaké skupiny vstupuješ.', 'For groups, always verify who invited you and which group you are joining.'),
            ],
          ),
          _docCard(
            title: t(context, 'Soukromí, online stav a notifikace', 'Privacy, presence, and notifications'),
            lines: [
              t(context, 'Presence (online/offline) lze úplně vypnout nebo přepnout na DND/skrytý.', 'Presence (online/offline) can be disabled entirely or set to DND/hidden.'),
              t(context, 'Auto-delete v soukromí je globální politika, TTL v DM je jemnější nastavení pro konverzaci.', 'Privacy auto-delete is a global policy; DM TTL is finer per-conversation control.'),
              t(context, 'Vypnutí notifikací zastaví push/in-app upozornění, ale zprávy se stále doručují.', 'Disabling notifications stops push/in-app alerts, but messages are still delivered.'),
              t(context, 'Vibrace a zvuky lze vypnout samostatně podle preferencí.', 'Vibration and sounds can be toggled independently.'),
            ],
          ),
          _docCard(
            title: t(context, 'Data, média a úložiště', 'Data, media, and storage'),
            lines: [
              t(context, 'Můžeš zvlášť povolit stahování médií pro mobilní data, Wi‑Fi a roaming.', 'You can separately allow media downloads for mobile data, Wi‑Fi, and roaming.'),
              t(context, 'Režim Ekonomie dat omezuje přenosy hlavně na mobilních sítích.', 'Data saver mode limits transfers mainly on mobile networks.'),
              t(context, 'Sekce Využití internetu ukazuje příjem/odeslání dat po typech sítě.', 'The Internet usage section shows received/sent data by network type.'),
              t(context, 'Sekce Využití paměti rozlišuje média, ostatní data a cache.', 'The Storage usage section separates media, other data, and cache.'),
              t(context, 'Po změnách je vhodné použít „Přepočítat“, aby se statistiky obnovily.', 'After changes, use “Recalculate” to refresh statistics.'),
            ],
          ),
          _docCard(
            title: t(context, 'Zařízení a relace', 'Devices and sessions'),
            lines: [
              t(context, 'V seznamu zařízení vidíš aktuální i historické relace účtu.', 'In the devices list, you can see current and historical account sessions.'),
              t(context, 'Neznámé zařízení můžeš vzdáleně odhlásit přímo ze sekce Zařízení.', 'Unknown devices can be remotely signed out from the Devices section.'),
              t(context, 'Po odhlášení cizího zařízení je vhodné změnit heslo/ověření účtu mimo aplikaci.', 'After removing an unknown device, it is recommended to change account credentials outside the app.'),
            ],
          ),
          _docCard(
            title: t(context, 'Nejčastější problémy', 'Common issues'),
            lines: [
              t(context, '„Bad state: Stream has already been listened to“ obvykle vyřeší restart aplikace po update.', '“Bad state: Stream has already been listened to” is usually fixed by a full app restart after update.'),
              t(context, '404 z backendu znamená neplatný endpoint nebo chybějící server route.', 'A backend 404 usually means an invalid endpoint or a missing server route.'),
              t(context, 'Pokud se nenačítá profil/DM, ověř GitHub login a existenci mapování v databázi.', 'If profile/DM does not load, verify GitHub login and account mapping in the database.'),
              t(context, 'Při problému se šifrováním zkus znovu publikovat klíč otevřením zabezpečeného chatu.', 'If encryption fails, try republishing keys by opening a secure chat again.'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsAccountPage extends StatefulWidget {
  const _SettingsAccountPage({required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<_SettingsAccountPage> createState() => _SettingsAccountPageState();
}

class _SettingsAccountPageState extends State<_SettingsAccountPage> {
  final _phone = TextEditingController();
  final _birthday = TextEditingController();
  final _bio = TextEditingController();
  final _debouncer = _Debouncer(const Duration(milliseconds: 500));

  Future<void> _openGitHubLogout() async {
    final uri = Uri.parse('https://github.com/logout');
    var ok = false;

    // Primary: Android native fallback (avoids url_launcher channel issues).
    if (!kIsWeb && Platform.isAndroid) {
      try {
        ok = (await const MethodChannel('gitmit/open_url').invokeMethod<bool>('open', {
              'url': uri.toString(),
            })) ??
            false;
      } catch (_) {
        ok = false;
      }
    }

    // Secondary: url_launcher (for iOS/macOS/web/etc).
    if (!ok) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }

    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se otevřít GitHub logout.', 'Failed to open GitHub logout.'))),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debouncer.dispose();
    _phone.dispose();
    _birthday.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    final snap = await rtdb().ref('users/${u.uid}').get();
    final v = snap.value;
    final m = (v is Map) ? v : null;
    if (!mounted) return;
    setState(() {
      _phone.text = (m?['phone'] ?? '').toString();
      _birthday.text = (m?['birthday'] ?? '').toString();
      _bio.text = (m?['bio'] ?? '').toString();
    });
  }

  void _autoSave() {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    _debouncer.run(() {
      rtdb().ref('users/${u.uid}').update({
        'phone': _phone.text.trim(),
        'birthday': _birthday.text.trim(),
        'bio': _bio.text.trim(),
        'accountUpdatedAt': ServerValue.timestamp,
      });
    });
  }

  Future<void> _reset() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    setState(() {
      _phone.clear();
      _birthday.clear();
      _bio.clear();
    });
    await rtdb().ref('users/${u.uid}').update({
      'phone': '',
      'birthday': '',
      'bio': '',
      'accountUpdatedAt': ServerValue.timestamp,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'Účet', 'Account'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _phone,
            decoration: InputDecoration(labelText: t(context, 'Telefon (volitelné)', 'Phone (optional)')),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _birthday,
            decoration: InputDecoration(labelText: t(context, 'Narozeniny (např. 2000-01-31)', 'Birthday (e.g. 2000-01-31)')),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(labelText: t(context, 'Bio', 'Bio')),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: widget.onLogout,
            child: Text(t(context, 'Odhlásit se', 'Sign out')),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _openGitHubLogout,
            child: Text(t(context, 'Odhlásit z GitHubu', 'Sign out from GitHub')),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _reset,
            child: Text(t(context, 'Reset', 'Reset')),
          ),
        ],
      ),
    );
  }
}

class _SettingsChatPage extends StatefulWidget {
  const _SettingsChatPage();

  @override
  State<_SettingsChatPage> createState() => _SettingsChatPageState();
}

class _SettingsChatPageState extends State<_SettingsChatPage> {
  static const _bgPalette = <({String key, String label, Color color})>[
    (key: 'none', label: 'Default', color: Color(0x00000000)),
    (key: 'graphite', label: 'Graphite', color: Color(0xFF1B1F1D)),
    (key: 'teal', label: 'Teal', color: Color(0xFF1A2B2C)),
    (key: 'pine', label: 'Pine', color: Color(0xFF1C2A24)),
    (key: 'sand', label: 'Sand', color: Color(0xFF2B241C)),
    (key: 'slate', label: 'Slate', color: Color(0xFF20242C)),
  ];

  static const _bubblePalette = <({String key, Color color})>[
    (key: 'custom_01', color: Color(0xFFEF5350)),
    (key: 'custom_02', color: Color(0xFFEC407A)),
    (key: 'custom_03', color: Color(0xFFAB47BC)),
    (key: 'custom_04', color: Color(0xFF7E57C2)),
    (key: 'custom_05', color: Color(0xFF5C6BC0)),
    (key: 'custom_06', color: Color(0xFF42A5F5)),
    (key: 'custom_07', color: Color(0xFF26C6DA)),
    (key: 'custom_08', color: Color(0xFF26A69A)),
    (key: 'custom_09', color: Color(0xFF66BB6A)),
    (key: 'custom_10', color: Color(0xFF9CCC65)),
    (key: 'custom_11', color: Color(0xFFD4E157)),
    (key: 'custom_12', color: Color(0xFFFFCA28)),
    (key: 'custom_13', color: Color(0xFFFFA726)),
    (key: 'custom_14', color: Color(0xFF8D6E63)),
    (key: 'custom_15', color: Color(0xFF90A4AE)),
  ];

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _updateSetting(String uid, Map<String, Object?> patch) async {
    await rtdb().ref('settings/$uid').update({
      ...patch,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _reset(String uid) async {
    await _updateSetting(uid, {
      'chatTextSize': 16,
      'bubbleRadius': 12,
      'bubbleIncoming': 'surface',
      'bubbleOutgoing': 'secondaryContainer',
      'wallpaperUrl': '',
      'reactionsEnabled': true,
      'stickersEnabled': false,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return Scaffold(body: Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.'))));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final settings = UserSettings.fromSnapshot(snap.data?.snapshot.value);

        return Scaffold(
          appBar: AppBar(title: Text(t(context, 'Nastavení chatů', 'Chat settings'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                title: Text(t(context, 'Velikost textu', 'Text size')),
                subtitle: Slider(
                  min: 12,
                  max: 24,
                  value: settings.chatTextSize.clamp(12, 24),
                  onChanged: (v) => _updateSetting(u.uid, {'chatTextSize': v}),
                ),
                trailing: Text(settings.chatTextSize.toStringAsFixed(0)),
              ),
              ListTile(
                title: Text(t(context, 'Zaoblení bublin', 'Bubble radius')),
                subtitle: Slider(
                  min: 4,
                  max: 28,
                  value: settings.bubbleRadius.clamp(4, 28),
                  onChanged: (v) => _updateSetting(u.uid, {'bubbleRadius': v}),
                ),
                trailing: Text(settings.bubbleRadius.toStringAsFixed(0)),
              ),
              const SizedBox(height: 8),
              Text(t(context, 'Pozadí chatu', 'Chat background'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: _bgPalette.map((bg) {
                  final selected = (settings.wallpaperUrl.isEmpty && bg.key == 'none') || settings.wallpaperUrl == bg.key;
                  final swatchColor = bg.key == 'none' ? Theme.of(context).colorScheme.surface : bg.color;
                  return GestureDetector(
                    onTap: () => _updateSetting(u.uid, {'wallpaperUrl': bg.key == 'none' ? '' : bg.key}),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: swatchColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? Theme.of(context).colorScheme.primary : Colors.white24,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: bg.key == 'none'
                              ? const Icon(Icons.block, size: 20)
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(bg.label, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  );
                }).toList(growable: false),
              ),
              Text(t(context, 'Příchozí bublina', 'Incoming bubble'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _bubblePalette.map((p) {
                  final selected = settings.bubbleIncoming == p.key;
                  return GestureDetector(
                    onTap: () => _updateSetting(u.uid, {'bubbleIncoming': p.key}),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: p.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? Theme.of(context).colorScheme.primary : Colors.white24,
                          width: selected ? 3 : 1,
                        ),
                      ),
                    ),
                  );
                }).toList(growable: false),
              ),
              const SizedBox(height: 14),
              Text(t(context, 'Odchozí bublina', 'Outgoing bubble'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _bubblePalette.map((p) {
                  final selected = settings.bubbleOutgoing == p.key;
                  return GestureDetector(
                    onTap: () => _updateSetting(u.uid, {'bubbleOutgoing': p.key}),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: p.color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? Theme.of(context).colorScheme.primary : Colors.white24,
                          width: selected ? 3 : 1,
                        ),
                      ),
                    ),
                  );
                }).toList(growable: false),
              ),
              const SizedBox(height: 12),
              _ChatPreview(settings: settings),
              const SizedBox(height: 12),
              SwitchListTile(
                value: settings.reactionsEnabled,
                onChanged: (v) => _updateSetting(u.uid, {'reactionsEnabled': v}),
                title: Text(t(context, 'Reakce na zprávy', 'Message reactions')),
                subtitle: Text(t(context, 'Dlouhé podržení na zprávě', 'Long press on a message')),
              ),
              SwitchListTile(
                value: settings.stickersEnabled,
                onChanged: (v) => _updateSetting(u.uid, {'stickersEnabled': v}),
                title: Text(t(context, 'Samolepky', 'Stickers')),
                subtitle: Text(t(context, 'Obrázkové nálepky / GIF v chatu', 'Image stickers / GIF in chat')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: Text(t(context, 'Reset', 'Reset')),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsPrivacyPage extends StatelessWidget {
  const _SettingsPrivacyPage();

  Future<void> _update(String uid, Map<String, Object?> patch) async {
    await rtdb().ref('settings/$uid').update({
      ...patch,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _reset(String uid) async {
    await _update(uid, {
      'autoDeleteSeconds': 0,
      'presenceEnabled': true,
      'presenceStatus': 'online',
      'giftsVisible': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.')));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: Text(t(context, 'Soukromí', 'Privacy'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<int>(
                value: s.autoDeleteSeconds,
                decoration: InputDecoration(labelText: t(context, 'Auto-delete zpráv', 'Auto-delete messages')),
                items: [
                  DropdownMenuItem(value: 0, child: Text(t(context, 'Vypnuto', 'Off'))),
                  DropdownMenuItem(value: 86400, child: Text(t(context, '24 hodin', '24 hours'))),
                  DropdownMenuItem(value: 604800, child: Text(t(context, '7 dní', '7 days'))),
                  DropdownMenuItem(value: 2592000, child: Text(t(context, '30 dní', '30 days'))),
                ],
                onChanged: (v) => _update(u.uid, {'autoDeleteSeconds': v ?? 0}),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: s.presenceEnabled,
                onChanged: (v) => _update(u.uid, {'presenceEnabled': v}),
                title: Text(t(context, 'Přítomnost (online/offline)', 'Presence (online/offline)')),
              ),
              DropdownButtonFormField<String>(
                value: s.presenceStatus,
                decoration: InputDecoration(labelText: t(context, 'Status', 'Status')),
                items: [
                  const DropdownMenuItem(value: 'online', child: Text('Online')),
                  DropdownMenuItem(value: 'dnd', child: Text(t(context, 'Nerušit', 'Do not disturb'))),
                  DropdownMenuItem(value: 'hidden', child: Text(t(context, 'Skrytý', 'Hidden'))),
                ],
                onChanged: (v) => _update(u.uid, {'presenceStatus': v ?? 'online'}),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: s.giftsVisible,
                onChanged: (v) => _update(u.uid, {'giftsVisible': v}),
                title: Text(t(context, 'Achievementy viditelné', 'Achievements visible')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: Text(t(context, 'Reset', 'Reset')),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsNotificationsPage extends StatelessWidget {
  const _SettingsNotificationsPage();

  Future<void> _update(String uid, Map<String, Object?> patch) async {
    await rtdb().ref('settings/$uid').update({
      ...patch,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _reset(String uid) async {
    await _update(uid, {
      'notificationsEnabled': true,
      'vibrationEnabled': true,
      'soundsEnabled': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.')));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: Text(t(context, 'Upozornění', 'Notifications'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                value: s.notificationsEnabled,
                onChanged: (v) => _update(u.uid, {'notificationsEnabled': v}),
                title: Text(t(context, 'Notifikace', 'Notifications')),
                subtitle: Text(t(context, 'Push upozornění a upozornění v aplikaci', 'Push notifications and in-app alerts')),
              ),
              SwitchListTile(
                value: s.vibrationEnabled,
                onChanged: (v) => _update(u.uid, {'vibrationEnabled': v}),
                title: Text(t(context, 'Vibrace', 'Vibration')),
              ),
              SwitchListTile(
                value: s.soundsEnabled,
                onChanged: (v) => _update(u.uid, {'soundsEnabled': v}),
                title: Text(t(context, 'Zvuky', 'Sounds')),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: Text(t(context, 'Reset', 'Reset')),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsDataPage extends StatefulWidget {
  const _SettingsDataPage();

  @override
  State<_SettingsDataPage> createState() => _SettingsDataPageState();
}

class _SettingsDataPageState extends State<_SettingsDataPage> {
  Future<_StorageUsage>? _storageFuture;

  static const _categoryLabels = {
    'api': 'API',
    'media': 'Media',
    'avatars': 'Avatary',
    'other': 'Ostatní',
  };

  @override
  void initState() {
    super.initState();
    _refreshStorage();
  }

  void _refreshStorage() {
    _storageFuture = _loadStorageUsage();
  }

  Future<void> _updateSetting(String uid, Map<String, Object?> patch) async {
    await rtdb().ref('settings/$uid').update({
      ...patch,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<_StorageUsage> _loadStorageUsage() async {
    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    final temp = await getTemporaryDirectory();

    final supportStats = await _dirStats(support);
    final docsStats = await _dirStats(docs);
    final cacheSize = await _dirSize(temp);

    final appDataBytes = supportStats.totalBytes + docsStats.totalBytes;
    final mediaBytes = supportStats.mediaBytes + docsStats.mediaBytes;
    final otherBytes = (appDataBytes - mediaBytes).clamp(0, appDataBytes);

    return _StorageUsage(
      appDataBytes: appDataBytes,
      mediaBytes: mediaBytes,
      otherBytes: otherBytes,
      cacheBytes: cacheSize,
    );
  }

  static const _mediaExt = [
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.heic',
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
  ];

  Future<_DirStats> _dirStats(Directory dir) async {
    var total = 0;
    var media = 0;
    if (!await dir.exists()) return const _DirStats(totalBytes: 0, mediaBytes: 0);
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final size = await entity.length();
            total += size;
            final path = entity.path.toLowerCase();
            if (_mediaExt.any(path.endsWith)) {
              media += size;
            }
          } catch (_) {
            // ignore
          }
        }
      }
    } catch (_) {
      // ignore
    }
    return _DirStats(totalBytes: total, mediaBytes: media);
  }

  Future<int> _dirSize(Directory dir) async {
    var total = 0;
    if (!await dir.exists()) return 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // ignore
          }
        }
      }
    } catch (_) {
      // ignore
    }
    return total;
  }

  String _formatBytes(int bytes) {
    const k = 1024;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var b = bytes.toDouble();
    var i = 0;
    while (b >= k && i < units.length - 1) {
      b /= k;
      i++;
    }
    final value = (i == 0) ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
    return '$value ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return Scaffold(body: Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.'))));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final settings = UserSettings.fromSnapshot(snap.data?.snapshot.value);

        return Scaffold(
          appBar: AppBar(title: Text(t(context, 'Data a paměť', 'Data and storage'))),
          body: StreamBuilder<DataUsageSnapshot>(
            stream: DataUsageTracker.stream,
            initialData: DataUsageTracker.snapshot,
            builder: (context, usageSnap) {
              final usage = usageSnap.data ?? DataUsageTracker.snapshot;
              final totalRx = usage.totalRx();
              final totalTx = usage.totalTx();
              final total = totalRx + totalTx;

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(t(context, 'Využití internetu', 'Internet usage'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  _UsageSummaryCard(
                    title: t(context, 'Celkem', 'Total'),
                    total: _formatBytes(total),
                    rx: _formatBytes(totalRx),
                    tx: _formatBytes(totalTx),
                  ),
                  const SizedBox(height: 12),
                  _NetworkUsageCard(
                    title: t(context, 'Mobilní data', 'Mobile data'),
                    netKey: 'mobile',
                    usage: usage,
                    formatBytes: _formatBytes,
                  ),
                  _NetworkUsageCard(
                    title: t(context, 'Wi‑Fi', 'Wi‑Fi'),
                    netKey: 'wifi',
                    usage: usage,
                    formatBytes: _formatBytes,
                  ),
                  _NetworkUsageCard(
                    title: t(context, 'Roaming', 'Roaming'),
                    netKey: 'roaming',
                    usage: usage,
                    formatBytes: _formatBytes,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => DataUsageTracker.reset(),
                    child: Text(t(context, 'Reset využití', 'Reset usage')),
                  ),
                  const SizedBox(height: 24),

                  Text(t(context, 'Stahování médií', 'Media download'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: settings.dataAllowMobile,
                    onChanged: (v) => _updateSetting(u.uid, {'dataAllowMobile': v}),
                    title: Text(t(context, 'Mobilní data', 'Mobile data')),
                    subtitle: Text(t(context, 'Stahovat media přes mobilní internet', 'Download media over mobile data')),
                  ),
                  SwitchListTile(
                    value: settings.dataAllowWifi,
                    onChanged: (v) => _updateSetting(u.uid, {'dataAllowWifi': v}),
                    title: Text(t(context, 'Wi‑Fi', 'Wi‑Fi')),
                    subtitle: Text(t(context, 'Stahovat media přes Wi‑Fi', 'Download media over Wi‑Fi')),
                  ),
                  SwitchListTile(
                    value: settings.dataAllowRoaming,
                    onChanged: (v) => _updateSetting(u.uid, {'dataAllowRoaming': v}),
                    title: Text(t(context, 'Roaming', 'Roaming')),
                    subtitle: Text(t(context, 'Stahovat media v roamingu', 'Download media while roaming')),
                  ),
                  SwitchListTile(
                    value: settings.dataSaverEnabled,
                    onChanged: (v) => _updateSetting(u.uid, {'dataSaverEnabled': v}),
                    title: Text(t(context, 'Ekonomie dat', 'Data saver')),
                    subtitle: Text(t(context, 'Omezuje stahování médií na mobilních datech', 'Limits media downloads on mobile data')),
                  ),
                  const SizedBox(height: 24),

                  Text(t(context, 'Ukládání do galerie', 'Save to gallery'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: settings.savePrivatePhotos,
                    onChanged: (v) => _updateSetting(u.uid, {'savePrivatePhotos': v}),
                    title: Text(t(context, 'Privátní chaty – fotky', 'Private chats – photos')),
                  ),
                  SwitchListTile(
                    value: settings.savePrivateVideos,
                    onChanged: (v) => _updateSetting(u.uid, {'savePrivateVideos': v}),
                    title: Text(t(context, 'Privátní chaty – videa', 'Private chats – videos')),
                  ),
                  SwitchListTile(
                    value: settings.saveGroupPhotos,
                    onChanged: (v) => _updateSetting(u.uid, {'saveGroupPhotos': v}),
                    title: Text(t(context, 'Skupiny – fotky', 'Groups – photos')),
                  ),
                  SwitchListTile(
                    value: settings.saveGroupVideos,
                    onChanged: (v) => _updateSetting(u.uid, {'saveGroupVideos': v}),
                    title: Text(t(context, 'Skupiny – videa', 'Groups – videos')),
                  ),
                  const SizedBox(height: 24),

                  Text(t(context, 'Využití paměti', 'Storage usage'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  FutureBuilder<_StorageUsage>(
                    future: _storageFuture,
                    builder: (context, storageSnap) {
                      final s = storageSnap.data;
                      final appData = s?.appDataBytes ?? 0;
                      final media = s?.mediaBytes ?? 0;
                      final other = s?.otherBytes ?? 0;
                      final cache = s?.cacheBytes ?? 0;
                      final totalStorage = appData + cache;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _UsageSummaryCard(
                            title: 'Celkem',
                            total: _formatBytes(totalStorage),
                            rx: _formatBytes(appData),
                            tx: _formatBytes(cache),
                            rxLabel: 'App data',
                            txLabel: 'Cache',
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: UsagePie(
                                  size: 120,
                                  data: {
                                    'Fotky/video/GIF': media,
                                    'Ostatní data': other,
                                    'Cache': cache,
                                  },
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    Theme.of(context).colorScheme.secondary,
                                    Theme.of(context).colorScheme.tertiary,
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Fotky/video/GIF: ${_formatBytes(media)}'),
                                    Text('${t(context, 'Ostatní data', 'Other data')}: ${_formatBytes(other)}'),
                                    Text('Cache: ${_formatBytes(cache)}'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              OutlinedButton(
                                onPressed: () => setState(_refreshStorage),
                                child: Text(t(context, 'Přepočítat', 'Recalculate')),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _UsageSummaryCard extends StatelessWidget {
  const _UsageSummaryCard({
    required this.title,
    required this.total,
    required this.rx,
    required this.tx,
    this.rxLabel = 'Přijato',
    this.txLabel = 'Odesláno',
  });

  final String title;
  final String total;
  final String rx;
  final String tx;
  final String rxLabel;
  final String txLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Celkem: $total'),
            Text('$rxLabel: $rx'),
            Text('$txLabel: $tx'),
          ],
        ),
      ),
    );
  }
}

class _NetworkUsageCard extends StatelessWidget {
  const _NetworkUsageCard({
    required this.title,
    required this.netKey,
    required this.usage,
    required this.formatBytes,
  });

  final String title;
  final String netKey;
  final DataUsageSnapshot usage;
  final String Function(int bytes) formatBytes;

  @override
  Widget build(BuildContext context) {
    final totalRx = usage.networkRx(netKey);
    final totalTx = usage.networkTx(netKey);
    final total = totalRx + totalTx;
    final categories = DataUsageTracker.categories;
    final totals = usage.categoryTotalsForNetwork(netKey, categories);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('Celkem: ${formatBytes(total)}'),
            Text('${AppLanguage.tr(context, 'Přijato', 'Received')}: ${formatBytes(totalRx)}'),
            Text('${AppLanguage.tr(context, 'Odesláno', 'Sent')}: ${formatBytes(totalTx)}'),
            const SizedBox(height: 8),
            if (total > 0)
              Row(
                children: [
                  UsagePie(
                    size: 120,
                    data: {
                      for (final c in categories) _SettingsDataPageState._categoryLabels[c] ?? c: totals[c] ?? 0,
                    },
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                      Theme.of(context).colorScheme.tertiary,
                      Theme.of(context).colorScheme.error,
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final c in categories)
                          if ((totals[c] ?? 0) > 0)
                            Text('${_SettingsDataPageState._categoryLabels[c] ?? c}: ${formatBytes(totals[c] ?? 0)}'),
                        if (totals.values.every((v) => v == 0))
                          Text(AppLanguage.tr(context, 'Zatím žádná data.', 'No data yet.')),
                      ],
                    ),
                  ),
                ],
              )
            else
              Text(AppLanguage.tr(context, 'Zatím žádná data.', 'No data yet.')),
          ],
        ),
      ),
    );
  }
}

class UsagePie extends StatelessWidget {
  const UsagePie({
    required this.size,
    required this.data,
    required this.colors,
  });

  final double size;
  final Map<String, int> data;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _UsagePiePainter(
          data: data,
          colors: colors,
          background: Theme.of(context).colorScheme.surfaceVariant,
        ),
      ),
    );
  }
}

class _UsagePiePainter extends CustomPainter {
  _UsagePiePainter({
    required this.data,
    required this.colors,
    required this.background,
  });

  final Map<String, int> data;
  final List<Color> colors;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final total = data.values.fold<int>(0, (a, b) => a + b);
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.4;

    if (total <= 0) {
      paint.color = background;
      canvas.drawCircle(center, radius * 0.6, paint);
      return;
    }

    var start = -1.5708;
    var colorIndex = 0;
    for (final value in data.values) {
      if (value <= 0) {
        colorIndex++;
        continue;
      }
      final sweep = (value / total) * 6.283185307179586;
      paint.color = colors[colorIndex % colors.length];
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.6),
        start,
        sweep,
        false,
        paint,
      );
      start += sweep;
      colorIndex++;
    }
  }

  @override
  bool shouldRepaint(covariant _UsagePiePainter oldDelegate) {
    return oldDelegate.data != data || oldDelegate.colors != colors || oldDelegate.background != background;
  }
}

class _StorageUsage {
  const _StorageUsage({
    required this.appDataBytes,
    required this.mediaBytes,
    required this.otherBytes,
    required this.cacheBytes,
  });

  final int appDataBytes;
  final int mediaBytes;
  final int otherBytes;
  final int cacheBytes;
}

class _DirStats {
  const _DirStats({required this.totalBytes, required this.mediaBytes});

  final int totalBytes;
  final int mediaBytes;
}

class _GitmitStats {
  const _GitmitStats({
    required this.privateChats,
    required this.groups,
    required this.messagesSent,
  });

  final int privateChats;
  final int groups;
  final int messagesSent;
}

class _SettingsDevicesPage extends StatefulWidget {
  const _SettingsDevicesPage({required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<_SettingsDevicesPage> createState() => _SettingsDevicesPageState();
}

class _SettingsDevicesPageState extends State<_SettingsDevicesPage> {
  late final Future<String> _localDeviceIdFuture;
  final Set<String> _revoking = <String>{};
  StreamSubscription<DatabaseEvent>? _pairingSub;
  String? _pairingToken;
  String? _pairingError;
  String? _pairingInfo;
  bool _pairingBusy = false;

  String _pairingStatusLabel(BuildContext context) {
    if (_pairingBusy) {
      return AppLanguage.tr(context, 'Párování: probíhá…', 'Pairing: in progress…');
    }
    if (_pairingError != null && _pairingError!.trim().isNotEmpty) {
      return AppLanguage.tr(context, 'Párování: chyba', 'Pairing: error');
    }
    if (_pairingInfo != null && _pairingInfo!.trim().isNotEmpty) {
      if ((_pairingToken ?? '').isNotEmpty && kIsWeb) {
        return AppLanguage.tr(context, 'Párování: čeká na sken', 'Pairing: waiting for scan');
      }
      if ((_pairingToken ?? '').isNotEmpty && !kIsWeb) {
        return AppLanguage.tr(context, 'Párování: čeká na odeslání', 'Pairing: waiting to send');
      }
      return AppLanguage.tr(context, 'Párování: spárováno', 'Pairing: paired');
    }
    return AppLanguage.tr(context, 'Párování: nepřipraveno', 'Pairing: idle');
  }

  @override
  void initState() {
    super.initState();
    _localDeviceIdFuture = _getOrCreateLocalDeviceId();
  }

  @override
  void dispose() {
    _pairingSub?.cancel();
    super.dispose();
  }

  String _pairingQrPayload({required String uid, required String token}) {
    return Uri(
      scheme: 'gitmit',
      host: 'device-pair',
      queryParameters: {
        'uid': uid,
        'token': token,
      },
    ).toString();
  }

  ({String uid, String token})? _parsePairingPayload(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    try {
      final uri = Uri.parse(s);
      final uid = (uri.queryParameters['uid'] ?? '').trim();
      final token = (uri.queryParameters['token'] ?? '').trim();
      if (uid.isEmpty || token.isEmpty) return null;

      final host = uri.host.trim().toLowerCase();
      final path = uri.path.trim().toLowerCase();
      final isGitmitPair = uri.scheme == 'gitmit' && (host == 'device-pair' || path.contains('device-pair'));
      if (!isGitmitPair) return null;
      return (uid: uid, token: token);
    } catch (_) {
      return null;
    }
  }

  Future<void> _startWebPairing({required String uid}) async {
    if (_pairingBusy) return;
    setState(() {
      _pairingBusy = true;
      _pairingError = null;
      _pairingInfo = null;
      _pairingToken = null;
    });

    await _pairingSub?.cancel();
    _pairingSub = null;

    try {
      final token = rtdb().ref().push().key ?? DateTime.now().millisecondsSinceEpoch.toString();
      final expiresAt = DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch;
      final ref = rtdb().ref('deviceKeyTransfers/$uid/$token');
      await ref.set({
        'status': 'waiting',
        'createdAt': ServerValue.timestamp,
        'expiresAt': expiresAt,
      });

      _pairingSub = ref.onValue.listen((event) async {
        final v = event.snapshot.value;
        if (v is! Map) return;
        final m = Map<String, dynamic>.from(v);
        final status = (m['status'] ?? '').toString();
        if (status != 'ready') return;

        final payloadRaw = m['payload'];
        if (payloadRaw is! Map) {
          if (mounted) {
            setState(() {
              _pairingError = AppLanguage.tr(context, 'Párovací data jsou neplatná.', 'Pairing payload is invalid.');
            });
          }
          return;
        }

        final asMap = Map<dynamic, dynamic>.from(payloadRaw);
        final material = <String, String>{};
        final importedPt = <String, String>{};

        final nestedE2ee = asMap['e2ee'];
        if (nestedE2ee is Map) {
          for (final e in nestedE2ee.entries) {
            final k = e.key.toString();
            final val = (e.value ?? '').toString();
            if (k.trim().isEmpty || val.trim().isEmpty) continue;
            material[k] = val;
          }
        } else {
          // Backward compatibility: old flat payload format.
          for (final e in asMap.entries) {
            final k = e.key.toString();
            final val = (e.value ?? '').toString();
            if (k.trim().isEmpty || val.trim().isEmpty) continue;
            material[k] = val;
          }
        }

        final nestedPt = asMap['ptcache'];
        if (nestedPt is Map) {
          for (final e in nestedPt.entries) {
            final k = e.key.toString();
            final val = (e.value ?? '').toString();
            if (k.trim().isEmpty || val.trim().isEmpty) continue;
            importedPt[k] = val;
          }
        }

        if (material.isEmpty) {
          if (mounted) {
            setState(() {
              _pairingError = AppLanguage.tr(context, 'Párovací data neobsahují žádné klíče.', 'Pairing payload contains no keys.');
            });
          }
          return;
        }

        await E2ee.importDeviceKeyMaterial(material);
        if (importedPt.isNotEmpty) {
          await PlaintextCache.importEntries(importedPt);
        }
        await E2ee.publishMyPublicKey(uid: uid);
        await _rebuildWebPlaintextCache(uid: uid);
        await ref.update({
          'status': 'completed',
          'completedAt': ServerValue.timestamp,
        });

        if (mounted) {
          setState(() {
            _pairingInfo = AppLanguage.tr(
              context,
              'Klíče byly úspěšně přeneseny. Otevři chat znovu, aby se obnovilo dešifrování.',
              'Keys were transferred successfully. Reopen chats to refresh decryption.',
            );
            _pairingBusy = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_pairingInfo!)),
          );
        }
      });

      if (mounted) {
        setState(() {
          _pairingToken = token;
          _pairingBusy = false;
          _pairingInfo = AppLanguage.tr(
            context,
            'Naskenuj QR kód v mobilní aplikaci v Nastavení > Zařízení.',
            'Scan this QR code in the mobile app at Settings > Devices.',
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pairingBusy = false;
          _pairingError = '${AppLanguage.tr(context, 'Párování selhalo', 'Pairing failed')}: $e';
        });
      }
    }
  }

  Future<void> _scanAndSendKeysToWeb({required String uid}) async {
    if (_pairingBusy) return;

    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanQrPage()),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;

    final parsed = _parsePairingPayload(raw);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Neplatný párovací QR kód.', 'Invalid pairing QR code.'))),
      );
      return;
    }

    if (parsed.uid != uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'QR kód patří jinému účtu.', 'QR code belongs to a different account.'))),
      );
      return;
    }

    setState(() {
      _pairingBusy = true;
      _pairingError = null;
      _pairingInfo = null;
    });

    try {
      final ref = rtdb().ref('deviceKeyTransfers/$uid/${parsed.token}');
      final snap = await ref.get();
      final v = snap.value;
      if (v is! Map) {
        throw Exception(AppLanguage.tr(context, 'Párovací relace neexistuje.', 'Pairing session not found.'));
      }
      final m = Map<String, dynamic>.from(v);
      final expiresAt = (m['expiresAt'] is int) ? m['expiresAt'] as int : int.tryParse((m['expiresAt'] ?? '').toString()) ?? 0;
      if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch > expiresAt) {
        throw Exception(AppLanguage.tr(context, 'Párovací QR vypršel. Vygeneruj nový.', 'Pairing QR expired. Generate a new one.'));
      }

      await PlaintextCache.flushNow();
      final material = await E2ee.exportDeviceKeyMaterial();
      if (material.isEmpty) {
        throw Exception(AppLanguage.tr(context, 'Na tomto zařízení nejsou dostupné žádné klíče k přenosu.', 'No keys available to transfer on this device.'));
      }

      final ptCache = await PlaintextCache.exportAllEntries(maxEntries: 1500);

      final deviceId = await _getOrCreateLocalDeviceId();
      await ref.update({
        'status': 'ready',
        'providedAt': ServerValue.timestamp,
        'fromDeviceId': deviceId,
        'payload': {
          'e2ee': material,
          'ptcache': ptCache,
        },
      });

      if (mounted) {
        setState(() {
          _pairingBusy = false;
          _pairingInfo = AppLanguage.tr(
            context,
            'Klíče byly odeslány do webu. Na webu počkej na potvrzení importu.',
            'Keys were sent to web. Wait for import confirmation on web.',
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_pairingInfo!)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pairingBusy = false;
          _pairingError = '${AppLanguage.tr(context, 'Přenos klíčů selhal', 'Key transfer failed')}: $e';
        });
      }
    }
  }

  Future<void> _rebuildWebPlaintextCache({required String uid}) async {
    try {
      final peerUidByLoginLower = <String, String?>{};

      final dmRootSnap = await rtdb().ref('messages/$uid').get();
      final dmRootVal = dmRootSnap.value;
      final dmRoot = (dmRootVal is Map) ? dmRootVal : null;
      if (dmRoot != null) {
        for (final threadEntry in dmRoot.entries) {
          final login = threadEntry.key.toString().trim();
          final loginLower = login.toLowerCase();
          if (loginLower.isEmpty) continue;

          if (!peerUidByLoginLower.containsKey(loginLower)) {
            final peerSnap = await rtdb().ref('usernames/$loginLower').get();
            peerUidByLoginLower[loginLower] = peerSnap.value?.toString();
          }

          final peerUid = peerUidByLoginLower[loginLower] ?? '';
          final threadRaw = threadEntry.value;
          if (threadRaw is! Map) continue;

          for (final msgEntry in threadRaw.entries) {
            final key = msgEntry.key.toString();
            final raw = msgEntry.value;
            if (key.isEmpty || raw is! Map) continue;

            final m = Map<String, dynamic>.from(raw);
            final text = (m['text'] ?? '').toString();
            if (text.isNotEmpty) {
              PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: key, plaintext: text);
              continue;
            }

            final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
            if (!hasCipher) continue;
            final cached = PlaintextCache.tryGetDm(otherLoginLower: loginLower, messageKey: key);
            if (cached != null && cached.isNotEmpty) continue;

            final fromUid = (m['fromUid'] ?? '').toString();
            final otherUid = (fromUid == uid) ? peerUid : (fromUid.isNotEmpty ? fromUid : peerUid);
            if (otherUid.isEmpty) continue;

            try {
              final plain = await E2ee.decryptFromUser(otherUid: otherUid, message: m);
              PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: key, plaintext: plain);
            } catch (_) {
              // best-effort
            }
          }
        }
      }

      final ugSnap = await rtdb().ref('userGroups/$uid').get();
      final ugVal = ugSnap.value;
      final ugMap = (ugVal is Map) ? ugVal : null;
      if (ugMap != null) {
        for (final entry in ugMap.entries) {
          if (entry.value != true) continue;
          final groupId = entry.key.toString();
          if (groupId.isEmpty) continue;

          SecretKey? groupKey;
          try {
            groupKey = await E2ee.fetchGroupKey(groupId: groupId, myUid: uid);
          } catch (_) {
            groupKey = null;
          }

          final gSnap = await rtdb().ref('groupMessages/$groupId').get();
          final gVal = gSnap.value;
          final gMap = (gVal is Map) ? gVal : null;
          if (gMap == null) continue;

          for (final msgEntry in gMap.entries) {
            final key = msgEntry.key.toString();
            final raw = msgEntry.value;
            if (key.isEmpty || raw is! Map) continue;

            final m = Map<String, dynamic>.from(raw);
            final text = (m['text'] ?? '').toString();
            if (text.isNotEmpty) {
              PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: text);
              continue;
            }

            final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
            if (!hasCipher) continue;
            final cached = PlaintextCache.tryGetGroup(groupId: groupId, messageKey: key);
            if (cached != null && cached.isNotEmpty) continue;

            try {
              final plain = await E2ee.decryptGroupMessage(
                groupId: groupId,
                myUid: uid,
                groupKey: groupKey,
                message: m,
              );
              PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plain);
            } catch (_) {
              // best-effort
            }
          }
        }
      }

      await PlaintextCache.flushNow();
      await rtdb().ref('users/$uid').update({'e2eeCacheRebuiltAt': ServerValue.timestamp});
    } catch (_) {
      // best-effort rebuild
    }
  }

  String _lastSeenLabel(int ms) {
    if (ms <= 0) return 'neznámé';
    final now = DateTime.now().millisecondsSinceEpoch;
    final d = now - ms;
    if (d < 60 * 1000) return 'právě teď';
    if (d < 60 * 60 * 1000) return 'před ${d ~/ (60 * 1000)} min';
    if (d < 24 * 60 * 60 * 1000) return 'před ${d ~/ (60 * 60 * 1000)} h';
    return 'před ${d ~/ (24 * 60 * 60 * 1000)} d';
  }

  Future<void> _revokeDevice({required String uid, required String deviceId}) async {
    if (_revoking.contains(deviceId)) return;
    setState(() => _revoking.add(deviceId));
    try {
      await rtdb().ref('deviceSessions/$uid/$deviceId').update({
        'forceLogoutAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Zařízení bylo odhlášeno.', 'Device has been signed out.'))),
      );
    } finally {
      if (mounted) setState(() => _revoking.remove(deviceId));
    }
  }

  Widget _deviceCard({
    required String deviceId,
    required Map<String, dynamic> data,
    required bool isCurrent,
    required String uid,
  }) {
    final platform = (data['platform'] ?? '').toString().trim();
    final deviceName = (data['deviceName'] ?? '').toString().trim();
    final online = data['online'] == true;
    final lastSeen = (data['lastSeenAt'] is int)
        ? data['lastSeenAt'] as int
        : int.tryParse((data['lastSeenAt'] ?? '').toString()) ?? 0;

    final title = deviceName.isNotEmpty ? deviceName : (platform.isNotEmpty ? platform : 'Zařízení');
    final subtitle = 'Platforma: ${platform.isEmpty ? '-': platform} • ${online ? 'online' : 'offline'} • ${_lastSeenLabel(lastSeen)}';
    final shortId = deviceId.length > 10 ? deviceId.substring(0, 10) : deviceId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Text(AppLanguage.tr(context, 'Toto zařízení', 'This device'), style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(subtitle),
            const SizedBox(height: 4),
            Text('ID: $shortId', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            if (!isCurrent) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _revoking.contains(deviceId)
                    ? null
                    : () => _revokeDevice(uid: uid, deviceId: deviceId),
                icon: _revoking.contains(deviceId)
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout),
                label: Text(AppLanguage.tr(context, 'Odhlásit toto zařízení', 'Sign out this device')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return Scaffold(body: Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.'))));
    }

    final sessionsRef = rtdb().ref('deviceSessions/${current.uid}');

    return FutureBuilder<String>(
      future: _localDeviceIdFuture,
      builder: (context, idSnap) {
        if (!idSnap.hasData) {
          return Scaffold(
            appBar: AppBar(title: Text(t(context, 'Zařízení', 'Devices'))),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        final localDeviceId = idSnap.data!;

        return Scaffold(
          appBar: AppBar(title: Text(t(context, 'Zařízení', 'Devices'))),
          body: StreamBuilder<DatabaseEvent>(
            stream: sessionsRef.onValue,
            builder: (context, snap) {
              final v = snap.data?.snapshot.value;
              final m = (v is Map) ? Map<dynamic, dynamic>.from(v) : <dynamic, dynamic>{};

              final entries = m.entries
                  .where((e) => e.value is Map)
                  .map((e) {
                    final data = Map<String, dynamic>.from(e.value as Map);
                    return (
                      id: e.key.toString(),
                      data: data,
                      lastSeen: (data['lastSeenAt'] is int)
                          ? data['lastSeenAt'] as int
                          : int.tryParse((data['lastSeenAt'] ?? '').toString()) ?? 0,
                    );
                  })
                  .toList(growable: false);

              entries.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

              final currentEntry = entries.where((e) => e.id == localDeviceId).toList(growable: false);
              final otherEntries = entries.where((e) => e.id != localDeviceId).toList(growable: false);

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(t(context, 'Toto zařízení', 'This device'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (currentEntry.isNotEmpty)
                    _deviceCard(
                      deviceId: currentEntry.first.id,
                      data: currentEntry.first.data,
                      isCurrent: true,
                      uid: current.uid,
                    )
                  else
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(t(context, 'Aktuální zařízení zatím není synchronizované.', 'Current device is not synchronized yet.')),
                      ),
                    ),

                  const SizedBox(height: 16),
                  Text(t(context, 'Ostatní zařízení', 'Other devices'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (otherEntries.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(t(context, 'Žádná další zařízení.', 'No other devices.')),
                      ),
                    )
                  else
                    ...otherEntries.map(
                      (e) => _deviceCard(
                        deviceId: e.id,
                        data: e.data,
                        isCurrent: false,
                        uid: current.uid,
                      ),
                    ),

                  const SizedBox(height: 16),
                  Text(t(context, 'Přenos E2EE klíčů', 'E2EE key transfer'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t(
                              context,
                              'Párování zařízení přes QR (fingerprint + klíče) pro dešifrování chatů na více zařízeních.',
                              'Pair devices via QR (fingerprint + keys) to decrypt chats across devices.',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _pairingStatusLabel(context),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: _pairingError != null
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (kIsWeb) ...[
                            OutlinedButton.icon(
                              onPressed: _pairingBusy ? null : () => _startWebPairing(uid: current.uid),
                              icon: _pairingBusy
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.qr_code_2),
                              label: Text(t(context, 'Vytvořit párovací QR', 'Create pairing QR')),
                            ),
                            if (_pairingToken != null) ...[
                              const SizedBox(height: 10),
                              Center(
                                child: QrImageView(
                                  data: _pairingQrPayload(uid: current.uid, token: _pairingToken!),
                                  size: 210,
                                  backgroundColor: Colors.white,
                                ),
                              ),
                            ],
                          ] else ...[
                            OutlinedButton.icon(
                              onPressed: _pairingBusy ? null : () => _scanAndSendKeysToWeb(uid: current.uid),
                              icon: _pairingBusy
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.qr_code_scanner),
                              label: Text(t(context, 'Naskenovat párovací QR z webu', 'Scan pairing QR from web')),
                            ),
                          ],
                          if (_pairingInfo != null) ...[
                            const SizedBox(height: 8),
                            Text(_pairingInfo!),
                          ],
                          if (_pairingError != null) ...[
                            const SizedBox(height: 8),
                            Text(_pairingError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: widget.onLogout,
                    child: Text(t(context, 'Odhlásit se na tomto zařízení', 'Sign out on this device')),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _SettingsLanguagePage extends StatelessWidget {
  const _SettingsLanguagePage();

  Future<void> _update(String uid, Map<String, Object?> patch) async {
    await rtdb().ref('settings/$uid').update({
      ...patch,
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _reset(String uid) async {
    await _update(uid, {'language': 'cs'});
    AppLanguage.setLanguage('cs');
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      return Center(child: Text(AppLanguage.tr(context, 'Nepřihlášen.', 'Not signed in.')));
    }
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: Text(AppLanguage.tr(context, 'Jazyk', 'Language'))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<String>(
                value: s.language,
                decoration: InputDecoration(labelText: AppLanguage.tr(context, 'Jazyk', 'Language')),
                items: [
                  DropdownMenuItem(value: 'cs', child: Text(AppLanguage.tr(context, 'Čeština', 'Czech'))),
                  const DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (v) async {
                  final lang = v ?? 'cs';
                  AppLanguage.setLanguage(lang);
                  await _update(u.uid, {'language': lang});
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: Text(AppLanguage.tr(context, 'Reset', 'Reset')),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChatPreview extends StatelessWidget {
  const _ChatPreview({required this.settings});

  final UserSettings settings;

  Color? _backgroundColor(BuildContext context, String key) {
    final k = key.trim();
    if (k.isEmpty) return null;
    switch (k) {
      case 'graphite':
        return const Color(0xFF1B1F1D);
      case 'teal':
        return const Color(0xFF1A2B2C);
      case 'pine':
        return const Color(0xFF1C2A24);
      case 'sand':
        return const Color(0xFF2B241C);
      case 'slate':
        return const Color(0xFF20242C);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _backgroundColor(context, settings.wallpaperUrl);
    final decoration = BoxDecoration(
      color: bgColor ?? Theme.of(context).colorScheme.surfaceVariant,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    final inColor = _resolveBubbleColor(context, settings.bubbleIncoming);
    final outColor = _resolveBubbleColor(context, settings.bubbleOutgoing);
    final inText = _resolveBubbleTextColor(context, settings.bubbleIncoming);
    final outText = _resolveBubbleTextColor(context, settings.bubbleOutgoing);

    Widget bubble({required bool outgoing, required String text, required double maxWidth}) {
      final color = outgoing ? outColor : inColor;
      final tcolor = outgoing ? outText : inText;
      return Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(settings.bubbleRadius),
            ),
            child: Text(
              text,
              softWrap: true,
              style: TextStyle(fontSize: settings.chatTextSize, color: tcolor),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBubbleWidth = constraints.maxWidth * 0.78;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: decoration,
          child: Column(
            children: [
              bubble(outgoing: false, text: 'Ahoj! Tohle je preview.', maxWidth: maxBubbleWidth),
              bubble(outgoing: true, text: 'Super, vidím změny hned.', maxWidth: maxBubbleWidth),
              bubble(outgoing: false, text: 'Bubliny jsou teď přehlednější.', maxWidth: maxBubbleWidth),
            ],
          ),
        );
      },
    );
  }
}

// -------------------- Ověření (verified) --------------------

// Improved invite sending logic: validate fields, catch errors, show SnackBar
Future<void> sendInviteWithMessage({
  required String groupId,
  required String targetLogin,
  required String message,
  required String groupTitle,
  required String? logoUrl,
  required String invitedByUid,
  required String invitedByGithub,
  required BuildContext context,
}) async {
  if (groupId.isEmpty || targetLogin.isEmpty || invitedByUid.isEmpty || invitedByGithub.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Chyba: Povinná pole pozvánky chybí.', 'Error: Required invite fields are missing.'))),
      );
    }
    return;
  }
  final lower = targetLogin.toLowerCase();
  try {
    final snap = await rtdb().ref('usernames/$lower').get();
    final uid = snap.value?.toString();
    if (uid == null || uid.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr(context, 'Uživatel není registrovaný v GitMitu.', 'User is not registered in GitMit.'))),
        );
      }
      return;
    }
    final payload = {
      'groupId': groupId,
      'groupTitle': groupTitle,
      if (logoUrl != null && logoUrl.isNotEmpty) 'groupLogoUrl': logoUrl,
      'invitedByUid': invitedByUid,
      'invitedByGithub': invitedByGithub,
      'createdAt': ServerValue.timestamp,
      if (message.isNotEmpty) 'message': message,
    };
    await rtdb().ref('groupInvites/$uid/$groupId').set(payload);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Pozvánka odeslána.', 'Invite sent.'))),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba při odesílání pozvánky', 'Error sending invite')}: $e')),
      );
    }
  }
}

DatabaseReference _verifiedRequestRef(String uid) => rtdb().ref('verifiedRequests/$uid');
DatabaseReference _verifiedMessagesRef(String uid) => rtdb().ref('verifiedMessages/$uid');

Future<void> _createOrUpdateVerifiedRequest({
  required User current,
  required String githubUsername,
  required String reason,
  required String? avatarUrl,
}) async {
  final reqRef = _verifiedRequestRef(current.uid);
  await reqRef.update({
    'uid': current.uid,
    'githubUsername': githubUsername,
    if (avatarUrl != null && avatarUrl.isNotEmpty) 'avatarUrl': avatarUrl,
    'reason': reason,
    'status': 'pending',
    'hasNewModeratorMessage': false,
    'createdAt': ServerValue.timestamp,
    'updatedAt': ServerValue.timestamp,
  });
  await _verifiedMessagesRef(current.uid).push().set({
    'from': 'user',
    'text': reason,
    'createdAt': ServerValue.timestamp,
    'important': false,
    'anonymous': false,
  });
}

Future<void> _sendVerifiedMessage({
  required String requestUid,
  required String from,
  required String text,
  required bool important,
  required bool anonymous,
  String? moderatorGithub,
  bool markNewForRequester = false,
}) async {
  final msgRef = _verifiedMessagesRef(requestUid).push();
  await msgRef.set({
    'from': from,
    'text': text,
    'createdAt': ServerValue.timestamp,
    'important': important,
    'anonymous': anonymous,
    if (moderatorGithub != null) 'moderatorGithub': moderatorGithub,
  });
  await _verifiedRequestRef(requestUid).update({
    'updatedAt': ServerValue.timestamp,
    'lastMessageAt': ServerValue.timestamp,
    'lastMessageText': text,
    'lastMessageFrom': from,
    if (markNewForRequester) 'hasNewModeratorMessage': true,
  });
}

Future<void> _setVerifiedStatus({
  required String requestUid,
  required String status,
  required bool setUserVerified,
  required String moderatorUid,
  required String moderatorGithub,
}) async {
  await _verifiedRequestRef(requestUid).update({
    'status': status,
    'handledByUid': moderatorUid,
    'handledByGithub': moderatorGithub,
    'handledAt': ServerValue.timestamp,
    'updatedAt': ServerValue.timestamp,
    'hasNewModeratorMessage': true,
  });
  if (setUserVerified) {
    await rtdb().ref('users/$requestUid').update({'verified': true});
  }
}

String _statusText(BuildContext context, String? status) {
  switch (status) {
    case 'pending':
      return AppLanguage.tr(context, 'Čeká se na moderátora', 'Waiting for moderator');
    case 'approved':
      return AppLanguage.tr(context, 'Schváleno', 'Approved');
    case 'declined':
      return AppLanguage.tr(context, 'Zamítnuto', 'Declined');
    default:
      return AppLanguage.tr(context, 'Bez žádosti', 'No request');
  }
}

bool _isModeratorFromUserMap(Map? userMap) {
  return userMap?['isModerator'] == true;
}

Future<Map<String, dynamic>?> _fetchGithubProfileData(String? username) async {
  print('[DEBUG] _fetchGithubProfileData() called with username: $username');
  if (username == null || username.isEmpty) return null;

  try {
    // Avatar
    String? avatarUrl;
    final userRes = await DataUsageTracker.trackedGet(
      Uri.https('api.github.com', '/users/$username'),
      headers: githubApiHeaders(),
      category: 'api',
    );
    if (userRes.statusCode == 200) {
      final decoded = jsonDecode(userRes.body);
      if (decoded is Map) {
        avatarUrl = (decoded['avatar_url'] ?? '').toString();
        if (avatarUrl.isEmpty) avatarUrl = null;
      }
    }

    // Top repozitáře (podle hvězdiček)
    final repoRes = await DataUsageTracker.trackedGet(
      Uri.https('api.github.com', '/users/$username/repos', {
        'sort': 'stars',
        'per_page': '5',
      }),
      headers: githubApiHeaders(),
      category: 'api',
    );

    List<Map<String, dynamic>> topRepos = [];
    if (repoRes.statusCode == 200) {
      final decoded = jsonDecode(repoRes.body);
      if (decoded is List) {
        topRepos = decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((r) => r['name'] != null)
            .toList(growable: false);
      }
    }

    return {
      'avatarUrl': avatarUrl,
      'topRepos': topRepos,
    };
  } catch (_) {
    return null;
  }
}

void _openRepoUrl(BuildContext context, String? url) {
  if (url == null || url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _ProfileSectionCard extends StatelessWidget {
  const _ProfileSectionCard({
    required this.title,
    required this.child,
    this.icon,
  });

  final String title;
  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ProfileMetricTile extends StatelessWidget {
  const _ProfileMetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _ProfileTab extends StatefulWidget {
  const _ProfileTab({required this.vibrationEnabled});

  final bool vibrationEnabled;

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  final _verifiedReason = TextEditingController();
  bool _sending = false;

  Future<Map<String, dynamic>?>? _ghFuture;
  String? _ghUsername;

  Future<_GitmitStats?>? _gitmitStatsFuture;
  String? _statsUid;

  @override
  void dispose() {
    _verifiedReason.dispose();
    super.dispose();
  }

  List<String> _parseBadges(Object? raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList(growable: false);
    }
    if (raw is Map) {
      return raw.entries
          .where((e) => e.value == true || e.value == 1)
          .map((e) => e.key.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Future<_GitmitStats?> _loadGitmitStats(String uid) async {
    try {
      final savedSnap = await rtdb().ref('savedChats/$uid').get();
      final savedVal = savedSnap.value;
      final savedMap = (savedVal is Map) ? Map<String, dynamic>.from(savedVal) : <String, dynamic>{};
      final privateChats = savedMap.length;

      final groupsSnap = await rtdb().ref('groupMembers').get();
      final groupsVal = groupsSnap.value;
      var groups = 0;
      if (groupsVal is Map) {
        for (final entry in groupsVal.entries) {
          final members = entry.value;
          if (members is Map) {
            final mm = Map<String, dynamic>.from(members);
            final v = mm[uid];
            if (v is Map || v == true) {
              groups++;
            }
          }
        }
      }

      final msgsSnap = await rtdb().ref('messages/$uid').get();
      final msgsVal = msgsSnap.value;
      var sent = 0;
      if (msgsVal is Map) {
        for (final entry in msgsVal.entries) {
          final thread = entry.value;
          if (thread is! Map) continue;
          for (final msgEntry in thread.entries) {
            final msg = msgEntry.value;
            if (msg is! Map) continue;
            final fromUid = (msg['fromUid'] ?? '').toString();
            if (fromUid == uid) sent++;
          }
        }
      }

      return _GitmitStats(privateChats: privateChats, groups: groups, messagesSent: sent);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLanguage.tr;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Center(child: Text(t(context, 'Nepřihlášen.', 'Not signed in.')));
    }

    if (_statsUid != user.uid) {
      _statsUid = user.uid;
      _gitmitStatsFuture = _loadGitmitStats(user.uid);
    }

    final userRef = rtdb().ref('users/${user.uid}');
    final reqRef = _verifiedRequestRef(user.uid);

    return StreamBuilder<DatabaseEvent>(
      stream: userRef.onValue,
      builder: (context, snapshot) {
        final data = snapshot.data?.snapshot.value;
        final map = (data is Map) ? data : null;

        final githubUsername = map?['githubUsername']?.toString();
        final githubAvatar = map?['avatarUrl']?.toString();
        final verified = map?['verified'] == true;
        final badgesRaw = map?['badges'];
        final badges = _parseBadges(badgesRaw);
        final githubAt = (githubUsername != null && githubUsername.isNotEmpty) ? '@$githubUsername' : '@(není nastaveno)';

        if (githubUsername != _ghUsername) {
          _ghUsername = githubUsername;
          _ghFuture = _fetchGithubProfileData(githubUsername);
        }

        return FutureBuilder<Map<String, dynamic>?>(
          future: _ghFuture,
          builder: (context, snap) {
            final gh = snap.data;
            final fetchedAvatar = gh?['avatarUrl'] as String?;
            final topRepos = gh?['topRepos'] as List<Map<String, dynamic>>?;

            final avatarFromDb = (githubAvatar != null && githubAvatar.isNotEmpty) ? githubAvatar : null;
            final avatarFromAuth = (user.photoURL != null && user.photoURL!.isNotEmpty) ? user.photoURL : null;
            final avatar = avatarFromDb ?? fetchedAvatar ?? avatarFromAuth;
            if (avatarFromDb == null && fetchedAvatar != null && fetchedAvatar.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                userRef.update({
                  'avatarUrl': fetchedAvatar,
                  'avatarFetchedAt': ServerValue.timestamp,
                });
              });
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _AvatarWithPresenceDot(
                    uid: user.uid,
                    avatarUrl: avatar,
                    radius: 48,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(githubAt, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      if (verified) const Icon(Icons.verified, color: Colors.grey, size: 28),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (githubUsername != null && githubUsername.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: () => _openRepoUrl(context, 'https://github.com/$githubUsername'),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(t(context, 'Zobrazit můj GitHub', 'View my GitHub')),
                    ),
                  const SizedBox(height: 8),
                  const Divider(height: 32),
                  const SizedBox(height: 8),
                  Text(t(context, 'Top repozitáře', 'Top repositories'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (topRepos != null && topRepos.isNotEmpty)
                    Column(
                      children: topRepos.take(3).map((repo) {
                        final name = (repo['name'] ?? '').toString();
                        final desc = (repo['description'] ?? '').toString();
                        final stars = repo['stargazers_count'] ?? 0;
                        final url = (repo['html_url'] ?? '').toString();
                        return ListTile(
                          leading: const Icon(Icons.book, color: Colors.white70),
                          title: Text(name),
                          subtitle: desc.isNotEmpty ? Text(desc) : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star, size: 16, color: Colors.amber),
                              Text(' $stars'),
                            ],
                          ),
                          onTap: () => _openRepoUrl(context, url),
                        );
                      }).toList(growable: false),
                    )
                  else
                    const SizedBox.shrink(),
                  const SizedBox(height: 24),

                  // Žádost o ověření
                  Text(t(context, 'Ověření', 'Verification'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  StreamBuilder<DatabaseEvent>(
                    stream: reqRef.onValue,
                    builder: (context, reqSnap) {
                      final v = reqSnap.data?.snapshot.value;
                      final req = (v is Map) ? v : null;
                      final status = req?['status']?.toString();
                      final statusText = _statusText(context, status);
                      final pending = status == 'pending';
                      final approved = status == 'approved';
                      final declined = status == 'declined';

                      if (approved) {
                        return Text('${t(context, 'Stav', 'Status')}: $statusText');
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('${t(context, 'Stav', 'Status')}: $statusText'),
                          const SizedBox(height: 8),
                          if (!pending && !declined) ...[
                            TextField(
                              controller: _verifiedReason,
                              minLines: 2,
                              maxLines: 5,
                              decoration: InputDecoration(
                                labelText: t(context, 'Proč chceš ověření?', 'Why do you want verification?')
                              ),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: (_sending || githubUsername == null || githubUsername.isEmpty)
                                  ? null
                                  : () async {
                                      final reason = _verifiedReason.text.trim();
                                      if (reason.isEmpty) return;
                                      setState(() => _sending = true);
                                      try {
                                        await _createOrUpdateVerifiedRequest(
                                          current: user,
                                          githubUsername: githubUsername,
                                          reason: reason,
                                          avatarUrl: avatar,
                                        );
                                        if (mounted) {
                                          _verifiedReason.clear();
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text(t(context, 'Žádost odeslána, čeká se na moderátora.', 'Request sent, waiting for moderator.'))),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _sending = false);
                                      }
                                    },
                              child: Text(t(context, 'Získat ověření', 'Get verification')),
                            ),
                          ] else if (pending) ...[
                            Text(t(context, 'Žádost byla odeslána. Odpověď najdeš v Chatech v položce „Ověření účtu“.', 'Request was sent. You can find response in Chats under “Account verification”.')),
                          ] else if (declined) ...[
                            Text(t(context, 'Žádost byla zamítnuta. Můžeš poslat novou žádost.', 'Request was declined. You can send a new request.')),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: (_sending || githubUsername == null || githubUsername.isEmpty)
                                  ? null
                                  : () async {
                                      final reason = _verifiedReason.text.trim();
                                      if (reason.isEmpty) return;
                                      setState(() => _sending = true);
                                      try {
                                        await _createOrUpdateVerifiedRequest(
                                          current: user,
                                          githubUsername: githubUsername,
                                          reason: reason,
                                          avatarUrl: avatar,
                                        );
                                        if (mounted) {
                                          _verifiedReason.clear();
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text(t(context, 'Žádost odeslána, čeká se na moderátora.', 'Request sent, waiting for moderator.'))),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _sending = false);
                                      }
                                    },
                              child: Text(t(context, 'Poslat novou žádost', 'Send new request')),
                            ),
                          ],
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 24),
                  _ProfileSectionCard(
                    title: t(context, 'Achievementy na GitMitu', 'GitMit achievements'),
                    icon: Icons.emoji_events_outlined,
                    child: badges.isEmpty
                        ? Text(t(context, 'Zatím žádné achievementy.', 'No achievements yet.'))
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: badges
                                .map(
                                  (b) => Chip(
                                    label: Text(b),
                                    avatar: const Icon(Icons.workspace_premium_outlined, size: 18),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                  ),
                  const SizedBox(height: 12),
                  _ProfileSectionCard(
                    title: t(context, 'Aktivita v GitMitu', 'GitMit activity'),
                    icon: Icons.insights_outlined,
                    child: FutureBuilder<_GitmitStats?>(
                      future: _gitmitStatsFuture,
                      builder: (context, statsSnap) {
                        final stats = statsSnap.data;
                        if (stats == null) {
                          return Text(t(context, 'Načítání aktivity...', 'Loading activity...'));
                        }
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _ProfileMetricTile(label: t(context, 'Priváty', 'Private'), value: '${stats.privateChats}'),
                            _ProfileMetricTile(label: t(context, 'Skupiny', 'Groups'), value: '${stats.groups}'),
                            _ProfileMetricTile(label: t(context, 'Odeslané', 'Sent'), value: '${stats.messagesSent}'),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text('UID: ${user.uid}'),
                  const SizedBox(height: 8),
                  Text('Email: ${user.email ?? "-"}'),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ContactsTab extends StatefulWidget {
  const _ContactsTab({required this.onStartChat, required this.vibrationEnabled});
  final void Function({required String login, required String avatarUrl}) onStartChat;
  final bool vibrationEnabled;

  @override
  State<_ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<_ContactsTab> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;
  List<GithubUser> _results = const [];

  String _lastSearchedQuery = '';
  final Map<String, ({int tsMs, List<GithubUser> results})> _searchCache = {};

  bool _recoLoading = false;
  String? _recoError;
  List<_RecommendedUser> _friends = const [];
  List<_RecommendedUser> _recommended = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLocalRecommendations());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (!mounted) return;
    final q = value.trim();
    setState(() {
      _error = null;
      _loading = false;
      if (q.isEmpty) {
        _results = const [];
        _lastSearchedQuery = '';
      }
    });
    if (q.isEmpty) {
      _refreshLocalRecommendations();
    }
  }

  Future<void> _performSearch(String rawQuery) async {
    final cleaned = rawQuery.trim();
    final q = cleaned.replaceFirst(RegExp(r'^@+'), '');
    if (q.isEmpty) return;
    if (q.length < 2) {
      if (!mounted) return;
      setState(() {
        _error = 'Zadej aspoň 2 znaky (šetří to GitHub API).';
        _results = const [];
        _loading = false;
        _lastSearchedQuery = q;
      });
      return;
    }

    if (_loading) return;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _lastSearchedQuery = q;
    });

    // Cache to avoid repeated GitHub API calls while user toggles UI.
    final now = DateTime.now().millisecondsSinceEpoch;
    final cacheKey = q.toLowerCase();
    final cached = _searchCache[cacheKey];
    if (cached != null && (now - cached.tsMs) < 120000) {
      if (!mounted) return;
      setState(() {
        _results = cached.results;
        _loading = false;
      });
      return;
    }

    try {
      final users = await searchGithubUsers(q);
      if (!mounted) return;
      _searchCache[cacheKey] = (tsMs: now, results: users);
      // keep cache from growing forever
      if (_searchCache.length > 30) {
        final keys = _searchCache.keys.toList(growable: false);
        for (var i = 0; i < 10 && i < keys.length; i++) {
          _searchCache.remove(keys[i]);
        }
      }
      setState(() {
        _results = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addToChats(GithubUser user) async {
    await _onContactTap(login: user.login, avatarUrl: user.avatarUrl);
  }

  Future<_InviteSendResult> _notifyGithubInviteFromContacts({
    required String targetLogin,
    required String fromLogin,
  }) async {
    final endpoint = _githubDmFallbackUrl.trim();
    if (endpoint.isEmpty) {
      debugPrint('[GitMitInvite] Missing GITMIT_GITHUB_NOTIFY_URL');
      return const _InviteSendResult(ok: false, error: 'Missing GITMIT_GITHUB_NOTIFY_URL');
    }

    final uris = _inviteBackendUris(endpoint);
    if (uris.isEmpty) {
      debugPrint('[GitMitInvite] Invalid invite URL: $endpoint');
      return _InviteSendResult(ok: false, error: 'Invalid invite URL: $endpoint');
    }

    final preview =
        'Message from GitMit app: @$fromLogin wants to chat. You do not have GitMit yet—download it and continue the conversation.';

    final payload = jsonEncode({
      'targetLogin': targetLogin,
      'fromLogin': fromLogin,
      'preview': preview,
      'source': 'gitmit-contact-invite',
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_githubDmFallbackToken.trim().isNotEmpty) 'Authorization': 'Bearer ${_githubDmFallbackToken.trim()}',
    };

    String? lastError;
    for (final uri in uris) {
      try {
        final response = await http.post(uri, headers: headers, body: payload);
        final ok = response.statusCode >= 200 && response.statusCode < 300;
        if (ok) return const _InviteSendResult(ok: true);
        lastError = _inviteErrorFromHttp(statusCode: response.statusCode, uri: uri, body: response.body);
        debugPrint('[GitMitInvite] Backend ${response.statusCode} at $uri: ${response.body}');
      } catch (e) {
        lastError = 'Request failed at $uri: $e';
        debugPrint('[GitMitInvite] Request failed at $uri: $e');
      }
    }

    final manualOpened = await _openManualGithubInvite(
      targetLogin: targetLogin,
      fromLogin: fromLogin,
      preview: '@$fromLogin sent you a message in GitMit.',
    );
    if (manualOpened) {
      return _InviteSendResult(
        ok: true,
        error: lastError,
        manualFallbackUsed: true,
      );
    }

    return _InviteSendResult(ok: false, error: lastError ?? 'Unknown invite error');
  }

  Future<void> _onContactTap({required String login, required String avatarUrl}) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final otherLogin = login.trim();
    final otherLower = otherLogin.toLowerCase();
    if (otherLower.isEmpty) return;

    final otherUid = await _lookupUidForLoginLower(otherLower);
    if (otherUid == null || otherUid.isEmpty) {
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundImage: avatarUrl.trim().isNotEmpty ? NetworkImage(avatarUrl.trim()) : null,
                        child: avatarUrl.trim().isEmpty ? const Icon(Icons.person) : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text('@$otherLogin', style: const TextStyle(fontWeight: FontWeight.w700))),
                      IconButton(
                        tooltip: AppLanguage.tr(context, 'Profil', 'Profile'),
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await Navigator.of(this.context).push(
                            MaterialPageRoute(
                              builder: (_) => _UserProfilePage(
                                login: otherLogin,
                                avatarUrl: avatarUrl,
                                githubDataFuture: _fetchGithubProfileData(otherLogin),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppLanguage.tr(
                      context,
                      'Tenhle uživatel zatím nemá účet v GitMitu (není v databázi), takže nejde poslat DM invajt.',
                      'This user does not have a GitMit account yet (not in database), so DM invite cannot be sent.',
                    ),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.person_add_alt_1),
                      onPressed: () async {
                        Navigator.of(context).pop();

                        final myLogin = await _myGithubUsernameFromRtdb(current.uid);
                        if (myLogin == null || myLogin.trim().isEmpty) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              content: Text(
                                AppLanguage.tr(
                                  this.context,
                                  'Nepodařilo se zjistit tvůj GitHub username pro pozvánku.',
                                  'Could not determine your GitHub username for invite.',
                                ),
                              ),
                            ),
                          );
                          return;
                        }

                        _InviteSendResult inviteResult = const _InviteSendResult(ok: false);
                        try {
                          inviteResult = await _notifyGithubInviteFromContacts(
                            targetLogin: otherLogin,
                            fromLogin: myLogin.trim(),
                          );
                        } catch (_) {
                          inviteResult = const _InviteSendResult(ok: false, error: 'Request threw exception');
                        }

                        if (!mounted) return;
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              inviteResult.ok
                                  ? (inviteResult.manualFallbackUsed
                                        ? AppLanguage.tr(
                                            this.context,
                                            'Backend invite není dostupný. Otevřel se GitHub formulář s předvyplněnou pozvánkou pro @$otherLogin.',
                                            'Backend invite is unavailable. A prefilled GitHub invite form for @$otherLogin was opened.',
                                          )
                                        : AppLanguage.tr(
                                            this.context,
                                            'GitHub pozvánka byla odeslána uživateli @$otherLogin od @$myLogin.',
                                            'GitHub invite was sent to @$otherLogin from @$myLogin.',
                                          ))
                                  : '${AppLanguage.tr(this.context, 'Pozvánku se nepodařilo odeslat', 'Failed to send invite')}: ${inviteResult.error ?? AppLanguage.tr(this.context, 'neznámá chyba', 'unknown error')}',
                            ),
                          ),
                        );
                      },
                      label: Text(AppLanguage.tr(context, 'Pozvat ho v GitMitu', 'Invite to GitMit')),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      return;
    }

    widget.onStartChat(login: otherLogin, avatarUrl: avatarUrl);
  }

  Future<void> _refreshLocalRecommendations() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    if (_recoLoading) return;
    if (!mounted) return;
    setState(() {
      _recoLoading = true;
      _recoError = null;
    });

    try {
      final myUid = current.uid;

      final savedSnap = await rtdb().ref('savedChats/$myUid').get();
      final sv = savedSnap.value;
      final sm = (sv is Map) ? sv : null;
      final friends = <_RecommendedUser>[];
      final friendLoginsLower = <String>{};
      if (sm != null) {
        for (final e in sm.entries) {
          if (e.value is! Map) continue;
          final m = Map<String, dynamic>.from(e.value as Map);
          final login = (m['login'] ?? e.key.toString()).toString().trim();
          final lower = login.toLowerCase();
          if (lower.isEmpty) continue;
          friendLoginsLower.add(lower);
          friends.add(
            _RecommendedUser(
              login: login,
              avatarUrl: (m['avatarUrl'] ?? '').toString(),
              score: 9999,
            ),
          );
        }
      }
      friends.sort((a, b) => a.login.toLowerCase().compareTo(b.login.toLowerCase()));

      final ugSnap = await rtdb().ref('userGroups/$myUid').get();
      final ugv = ugSnap.value;
      final ugm = (ugv is Map) ? ugv : null;
      final groupIds = <String>[];
      if (ugm != null) {
        for (final e in ugm.entries) {
          if (e.value == null || e.value == false) continue;
          groupIds.add(e.key.toString());
        }
      }

      final mutualCounts = <String, int>{};
      for (final gid in groupIds) {
        final membersSnap = await rtdb().ref('groupMembers/$gid').get();
        final mv = membersSnap.value;
        final mm = (mv is Map) ? mv : null;
        if (mm == null) continue;
        for (final entry in mm.entries) {
          final uid = entry.key.toString();
          if (uid == myUid) continue;
          mutualCounts[uid] = (mutualCounts[uid] ?? 0) + 1;
        }
      }

      final recos = <_RecommendedUser>[];
      for (final uid in mutualCounts.keys) {
        final userSnap = await rtdb().ref('users/$uid').get();
        final uv = userSnap.value;
        final um = (uv is Map) ? uv : null;
        if (um == null) continue;
        final login = (um['githubUsername'] ?? '').toString().trim();
        final lower = login.toLowerCase();
        if (lower.isEmpty) continue;
        if (friendLoginsLower.contains(lower)) continue;
        recos.add(
          _RecommendedUser(
            login: login,
            avatarUrl: (um['avatarUrl'] ?? '').toString(),
            score: mutualCounts[uid] ?? 0,
          ),
        );
      }

      recos.sort((a, b) {
        final s = b.score.compareTo(a.score);
        if (s != 0) return s;
        return a.login.toLowerCase().compareTo(b.login.toLowerCase());
      });

      if (!mounted) return;
      setState(() {
        _friends = friends;
        _recommended = recos.take(25).toList(growable: false);
        _recoLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recoError = e.toString();
        _recoLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _controller.text.trim();

    final qLower = query.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
    final localMatches = <_RecommendedUser>[];
    if (qLower.isNotEmpty) {
      localMatches.addAll(_friends.where((u) => u.login.toLowerCase().contains(qLower)));
      localMatches.addAll(_recommended.where((u) => u.login.toLowerCase().contains(qLower)));
      localMatches.sort((a, b) => a.login.toLowerCase().compareTo(b.login.toLowerCase()));
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _controller,
            onChanged: _onChanged,
            onSubmitted: (v) => _performSearch(v),
            decoration: InputDecoration(
              labelText: AppLanguage.tr(context, 'Hledat na GitHubu', 'Search on GitHub'),
              prefixText: '@',
              helperText: AppLanguage.tr(context, 'Stiskni Enter pro hledání (šetří to GitHub API).', 'Press Enter to search (saves GitHub API quota).'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () => _performSearch(_controller.text),
                  icon: const Icon(Icons.search),
                  label: Text(_loading
                      ? AppLanguage.tr(context, 'Hledám…', 'Searching…')
                      : AppLanguage.tr(context, 'Hledat', 'Search')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
          if (query.isEmpty) ...[
            if (_recoLoading) const LinearProgressIndicator(),
            if (_recoError != null) ...[
              const SizedBox(height: 12),
              Text(_recoError!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
          Expanded(
            child: query.isEmpty
                ? ListView(
                    children: [
                      if (_friends.isNotEmpty) ...[
                        Text(AppLanguage.tr(context, 'Kamarádi', 'Friends'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        ..._friends.map(
                          (u) => _recommendedTile(
                            u,
                            onTap: () {
                              if (widget.vibrationEnabled) {
                                HapticFeedback.selectionClick();
                              }
                              _onContactTap(login: u.login, avatarUrl: u.avatarUrl);
                            },
                          ),
                        ),
                        const Divider(height: 24),
                      ],
                      if (_recommended.isNotEmpty) ...[
                        Text(AppLanguage.tr(context, 'Doporučené', 'Recommended'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          AppLanguage.tr(context, 'Lidi z tvých skupin (podle počtu společných skupin).', 'People from your groups (by number of mutual groups).'),
                          style: const TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 8),
                        ..._recommended.map(
                          (u) => _recommendedTile(
                            u,
                                subtitle: '${AppLanguage.tr(context, 'Společné skupiny', 'Mutual groups')}: ${u.score}',
                            onTap: () {
                              if (widget.vibrationEnabled) {
                                HapticFeedback.selectionClick();
                              }
                              _onContactTap(login: u.login, avatarUrl: u.avatarUrl);
                            },
                          ),
                        ),
                      ],
                      if (_friends.isEmpty && _recommended.isEmpty && !_recoLoading)
                        const SizedBox.shrink(),
                    ],
                  )
                : ListView(
                    children: [
                      if (localMatches.isNotEmpty) ...[
                        Text(AppLanguage.tr(context, 'Lokálně', 'Local'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        ...localMatches.take(25).map(
                              (u) => _recommendedTile(
                                u,
                                onTap: () {
                                  if (widget.vibrationEnabled) {
                                    HapticFeedback.selectionClick();
                                  }
                                  _onContactTap(login: u.login, avatarUrl: u.avatarUrl);
                                },
                              ),
                            ),
                        const Divider(height: 24),
                      ],
                      Text(AppLanguage.tr(context, 'GitHub', 'GitHub'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      if (_lastSearchedQuery.toLowerCase() != qLower || _results.isEmpty)
                        Text(AppLanguage.tr(context, 'Stiskni Enter nebo tlačítko "Hledat" pro dotaz na GitHub.', 'Press Enter or the "Search" button to query GitHub.')),
                      if (_lastSearchedQuery.toLowerCase() == qLower && _results.isNotEmpty) ...[
                        ..._results.map((u) {
                          return Column(
                            children: [
                              ListTile(
                                leading: CircleAvatar(
                                  backgroundImage: u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
                                  child: u.avatarUrl.isEmpty ? const Icon(Icons.person) : null,
                                ),
                                title: Text('@${u.login}'),
                                onTap: () {
                                  if (widget.vibrationEnabled) {
                                    HapticFeedback.selectionClick();
                                  }
                                  _addToChats(u);
                                },
                              ),
                              const Divider(height: 1),
                            ],
                          );
                        }),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RecommendedUser {
  const _RecommendedUser({required this.login, required this.avatarUrl, required this.score});

  final String login;
  final String avatarUrl;
  final int score;
}

Widget _recommendedTile(
  _RecommendedUser u, {
  String? subtitle,
  VoidCallback? onTap,
}) {
  return ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      radius: 16,
      backgroundImage: u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
      child: u.avatarUrl.isEmpty ? const Icon(Icons.person, size: 16) : null,
    ),
    title: Text('@${u.login}', maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: subtitle == null ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: onTap,
  );
}

class _ChatsTab extends StatefulWidget {
  const _ChatsTab({
    super.key,
    required this.initialOpenLogin,
    required this.initialOpenAvatarUrl,
    required this.settings,
    required this.openChatToken,
    required this.overviewToken,
  });
  final String? initialOpenLogin;
  final String? initialOpenAvatarUrl;
  final UserSettings settings;
  final int openChatToken;
  final int overviewToken;

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> with SingleTickerProviderStateMixin {
  String? _activeLogin;
  String? _activeAvatarUrl;
  String? _activeOtherUid;
  String? _activeOtherUidLoginLower;
  String? _activeGroupId;
  String? _activeVerifiedUid;
  String? _activeVerifiedGithub;
  bool _moderatorAnonymous = true;
  final _messageController = TextEditingController();

  final Map<String, String> _decryptedCache = {};
  final Set<String> _decrypting = {};
  final Set<String> _migrating = {};
  final Map<String, SecretKey> _groupKeyCache = {};
  final Map<String, String> _attachmentCache = {};
  final Set<String> _attachmentLoading = {};
  final Set<String> _deliveredMarked = {};
  final Set<String> _readMarked = {};
  _CodeMessagePayload? _pendingCodePayload;
  String? _replyToKey;
  String? _replyToFrom;
  String? _replyToPreview;
  Timer? _typingTimeout;
  bool _typingOn = false;
  bool _groupTypingOn = false;
  String? _groupTypingGroupId;
  late final AnimationController _typingAnim;
  bool _prewarmDecryptStarted = false;
  bool _prewarmGroupDecryptStarted = false;
  final Set<String> _inlineKeyRequestSent = <String>{};
  bool _sendingInlineKeyRequest = false;
  final Map<String, bool> _peerHasPublishedKey = <String, bool>{};
  final Set<String> _peerKeyProbeInFlight = <String>{};

  Future<File> _attachmentFile(String cacheKey, String ext) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/attachments');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File('${folder.path}/$cacheKey.$ext');
  }

  Future<void> _ensureAttachmentCached({
    required String cacheKey,
    required _AttachmentPayload payload,
  }) async {
    if (_attachmentCache.containsKey(cacheKey) || _attachmentLoading.contains(cacheKey)) return;

    _attachmentLoading.add(cacheKey);
    try {
      final file = await _attachmentFile(cacheKey, payload.ext);
      if (await file.exists()) {
        if (mounted) setState(() => _attachmentCache[cacheKey] = file.path);
        return;
      }

      if (!await DataUsageTracker.canDownloadMedia()) return;

      final ref = FirebaseStorage.instance.ref(payload.path);
      final bytes = await ref.getData(payload.size > 0 ? payload.size : 50 * 1024 * 1024);
      if (bytes == null || bytes.isEmpty) return;
      await DataUsageTracker.recordDownload(bytes.length, category: 'media');
      final clear = await _decryptAttachmentBytes(
        cipher: bytes,
        nonceB64: payload.nonceB64,
        keyB64: payload.keyB64,
      );
      await file.writeAsBytes(clear, flush: true);
      if (!mounted) return;
      setState(() => _attachmentCache[cacheKey] = file.path);
    } catch (_) {
      // ignore
    } finally {
      _attachmentLoading.remove(cacheKey);
    }
  }

  Future<Uint8List?> _pickAndEditImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 2048,
      maxHeight: 2048,
    );
    if (picked == null) return null;
    final bytes = await picked.readAsBytes();
    final edited = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => ImageEditor(image: bytes),
      ),
    );
    final out = edited ?? bytes;
    final decoded = img.decodeImage(out);
    if (decoded == null) return out;
    final jpg = img.encodeJpg(decoded, quality: 82);
    return Uint8List.fromList(jpg);
  }

  Future<_AttachmentPayload?> _uploadAttachment({
    required Uint8List clearBytes,
    required String storagePath,
  }) async {
    try {
      final enc = await _encryptAttachmentBytes(clearBytes);
      final ref = FirebaseStorage.instance.ref(storagePath);
      await ref.putData(
        Uint8List.fromList(enc.cipher),
        SettableMetadata(contentType: 'application/octet-stream'),
      );
      await DataUsageTracker.recordUpload(enc.cipher.length, category: 'media');

      return _AttachmentPayload(
        type: 'image',
        path: storagePath,
        nonceB64: enc.nonceB64,
        keyB64: enc.keyB64,
        size: enc.cipher.length,
        mime: 'image/jpeg',
        ext: 'jpg',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _setTyping(bool value) async {
    if (_typingOn == value) return;
    _typingOn = value;
    final otherUid = await _ensureActiveOtherUid();
    if (otherUid == null || otherUid.isEmpty) return;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final ref = rtdb().ref('typing/${current.uid}/$otherUid');
    if (value) {
      await ref.set({'typing': true, 'at': ServerValue.timestamp});
    } else {
      await ref.remove();
    }
  }

  Future<void> _setGroupTyping({
    required String groupId,
    required bool value,
    String? myGithub,
  }) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    if (_groupTypingGroupId != null && _groupTypingGroupId != groupId && _groupTypingOn) {
      try {
        await rtdb().ref('typingGroups/${_groupTypingGroupId!}/${current.uid}').remove();
      } catch (_) {
        // ignore
      }
    }

    if (_groupTypingOn == value && _groupTypingGroupId == groupId) return;
    _groupTypingOn = value;
    _groupTypingGroupId = groupId;

    final ref = rtdb().ref('typingGroups/$groupId/${current.uid}');
    if (value) {
      await ref.set({
        'typing': true,
        'at': ServerValue.timestamp,
        if (myGithub != null && myGithub.isNotEmpty) 'github': myGithub,
      });
    } else {
      await ref.remove();
    }
  }

  void _onTypingChanged(String text) {
    final hasText = text.trim().isNotEmpty;
    if (hasText) {
      _setTyping(true);
      _typingTimeout?.cancel();
      _typingTimeout = Timer(const Duration(seconds: 4), () {
        _setTyping(false);
      });
    } else {
      _typingTimeout?.cancel();
      _setTyping(false);
    }
  }

  void _onGroupTypingChanged({
    required String groupId,
    required String text,
    required String myGithub,
  }) {
    final hasText = text.trim().isNotEmpty;
    if (hasText) {
      _setGroupTyping(groupId: groupId, value: true, myGithub: myGithub);
      _typingTimeout?.cancel();
      _typingTimeout = Timer(const Duration(seconds: 4), () {
        _setGroupTyping(groupId: groupId, value: false, myGithub: myGithub);
      });
    } else {
      _typingTimeout?.cancel();
      _setGroupTyping(groupId: groupId, value: false, myGithub: myGithub);
    }
  }

  String _formatShortTime(int? ms) {
    if (ms == null || ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Future<void> _markDeliveredRead({
    required String key,
    required String myUid,
    required String otherUid,
    required String myLogin,
    required String otherLogin,
    required bool markRead,
  }) async {
    final deliveredKey = 'd:$key';
    final readKey = 'r:$key';
    final updates = <String, Object?>{};

    if (!_deliveredMarked.contains(deliveredKey)) {
      updates['messages/$myUid/$otherLogin/$key/deliveredTo/$myUid'] = true;
      updates['messages/$otherUid/$myLogin/$key/deliveredTo/$myUid'] = true;
      _deliveredMarked.add(deliveredKey);
    }

    if (markRead && !_readMarked.contains(readKey)) {
      updates['messages/$myUid/$otherLogin/$key/readBy/$myUid'] = true;
      updates['messages/$otherUid/$myLogin/$key/readBy/$myUid'] = true;
      _readMarked.add(readKey);
    }

    if (updates.isNotEmpty) {
      await rtdb().ref().update(updates);
    }
  }

  Widget _statusChecks({
    required Map<String, dynamic> message,
    required String? otherUid,
    required Color color,
  }) {
    if (otherUid == null || otherUid.isEmpty) return const SizedBox.shrink();
    final delivered = (message['deliveredTo'] is Map) ? (message['deliveredTo'] as Map) : null;
    final read = (message['readBy'] is Map) ? (message['readBy'] as Map) : null;
    final deliveredOk = delivered?.containsKey(otherUid) == true;
    final readOk = read?.containsKey(otherUid) == true;

    if (readOk) {
      return Icon(Icons.done_all, size: 14, color: Colors.lightBlueAccent);
    }
    if (deliveredOk) {
      return Icon(Icons.done_all, size: 14, color: Colors.grey);
    }
    return Icon(Icons.check, size: 14, color: Colors.grey);
  }

  Widget _typingPill() {
    final dotColor = Theme.of(context).colorScheme.onSurface.withOpacity(0.7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedBuilder(
        animation: _typingAnim,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final phase = (_typingAnim.value * 2 * pi) + (i * 0.7);
              final opacity = 0.25 + (0.75 * (0.5 + 0.5 * sin(phase)));
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  Widget _attachmentBubble({
    required _AttachmentPayload payload,
    required String cacheKey,
    required double maxWidth,
    required double radius,
  }) {
    final localPath = _attachmentCache[cacheKey];
    if (localPath != null && localPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.file(
          File(localPath),
          width: maxWidth,
          fit: BoxFit.cover,
        ),
      );
    }

    if (!_attachmentLoading.contains(cacheKey)) {
      _ensureAttachmentCached(cacheKey: cacheKey, payload: payload);
    }

    return Container(
      width: maxWidth,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_outlined, size: 32),
          const SizedBox(height: 8),
          Text(
            _attachmentLoading.contains(cacheKey) ? 'Stahuji…' : 'Klepni pro stažení',
            style: const TextStyle(fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _sendImageDm({
    required User current,
    required String login,
    required String myLogin,
    required String otherUid,
    required bool canSend,
  }) async {
    if (!canSend) return;
    final edited = await _pickAndEditImage();
    if (edited == null || edited.isEmpty) return;

    final key = rtdb().ref().push().key;
    if (key == null || key.isEmpty) return;

    final storagePath = 'attachments/dm/${current.uid}/$key.bin';
    final payload = await _uploadAttachment(clearBytes: edited, storagePath: storagePath);
    if (payload == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se nahrát obrázek.', 'Failed to upload image.'))));
      }
      return;
    }

    final plaintext = jsonEncode(payload.toJson());
    Map<String, Object?> encrypted;
    try {
      encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: plaintext);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se zašifrovat obrázek.', 'Failed to encrypt image.'))));
      }
      return;
    }

    final msg = {
      ...encrypted,
      'fromUid': current.uid,
      'createdAt': ServerValue.timestamp,
    };

    final updates = <String, Object?>{};
    updates['messages/${current.uid}/$login/$key'] = msg;
    updates['messages/$otherUid/$myLogin/$key'] = msg;
    if (otherUid == current.uid) {
      updates['messages/${current.uid}/$login/$key/deliveredTo/${current.uid}'] = true;
      updates['messages/${current.uid}/$login/$key/readBy/${current.uid}'] = true;
    }
    if (otherUid == current.uid) {
      updates['messages/${current.uid}/$login/$key/deliveredTo/${current.uid}'] = true;
      updates['messages/${current.uid}/$login/$key/readBy/${current.uid}'] = true;
    }
    updates['savedChats/${current.uid}/$login/lastMessageText'] = '🖼️';
    updates['savedChats/${current.uid}/$login/lastMessageAt'] = ServerValue.timestamp;
    updates['savedChats/$otherUid/$myLogin/lastMessageText'] = '🖼️';
    updates['savedChats/$otherUid/$myLogin/lastMessageAt'] = ServerValue.timestamp;
    try {
      await rtdb().ref().update(updates);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se odeslat obrázek.', 'Failed to send image.'))));
      }
      return;
    }

    final cacheKey = 'dm:${login.trim().toLowerCase()}:$key';
    final file = await _attachmentFile(cacheKey, payload.ext);
    await file.writeAsBytes(edited, flush: true);
    if (mounted) {
      setState(() {
        _decryptedCache[key] = plaintext;
        _attachmentCache[cacheKey] = file.path;
      });
    }

    _typingTimeout?.cancel();
    _setTyping(false);

    PlaintextCache.putDm(otherLoginLower: login.trim().toLowerCase(), messageKey: key, plaintext: plaintext);
  }

  Future<void> _sendImageGroup({
    required String groupId,
    required User current,
    required String myGithub,
    required bool canSend,
  }) async {
    if (!canSend) return;
    final edited = await _pickAndEditImage();
    if (edited == null || edited.isEmpty) return;

    final key = rtdb().ref().push().key;
    if (key == null || key.isEmpty) return;

    final storagePath = 'attachments/group/$groupId/$key.bin';
    final payload = await _uploadAttachment(clearBytes: edited, storagePath: storagePath);
    if (payload == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se nahrát obrázek.', 'Failed to upload image.'))));
      }
      return;
    }
    final plaintext = jsonEncode(payload.toJson());

    Map<String, Object?>? encrypted;
    try {
      encrypted = await E2ee.encryptForGroupSignalLike(groupId: groupId, myUid: current.uid, plaintext: plaintext);
    } catch (_) {
      encrypted = null;
    }

    if (encrypted == null) {
      SecretKey? gk = _groupKeyCache[groupId];
      gk ??= await E2ee.fetchGroupKey(groupId: groupId, myUid: current.uid);
      if (gk == null) {
        if (mounted) {
            ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se zašifrovat obrázek.', 'Failed to encrypt image.'))));
        }
        return;
      }
      _groupKeyCache[groupId] = gk;
      encrypted = await E2ee.encryptForGroup(groupKey: gk, plaintext: plaintext);
    }

    try {
      await rtdb().ref('groupMessages/$groupId/$key').set({
        ...encrypted,
        'fromUid': current.uid,
        'fromGithub': myGithub,
        'createdAt': ServerValue.timestamp,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLanguage.tr(context, 'Nepodařilo se odeslat obrázek.', 'Failed to send image.'))));
      }
      return;
    }

    final cacheKey = 'g:$groupId:$key';
    final file = await _attachmentFile(cacheKey, payload.ext);
    await file.writeAsBytes(edited, flush: true);
    if (mounted) {
      setState(() {
        _decryptedCache[cacheKey] = plaintext;
        _attachmentCache[cacheKey] = file.path;
      });
    }

    _typingTimeout?.cancel();
    _setGroupTyping(groupId: groupId, value: false, myGithub: myGithub);

    PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plaintext);
  }

  Future<void> _warmupDmDecryptAll({
    required List<Map<String, dynamic>> items,
    required String loginLower,
    required String myUid,
  }) async {
    if (!mounted) return;
    if (((_activeLogin ?? '').trim().toLowerCase()) != loginLower) return;

    // Decrypt a small batch per frame to reduce jank.
    const batchSize = 4;
    final peerUid = await _ensureActiveOtherUid();

    var processed = 0;
    var hasMore = false;

    for (final m in items) {
      if (!mounted) return;
      if (((_activeLogin ?? '').trim().toLowerCase()) != loginLower) return;

      final key = (m['__key'] ?? '').toString();
      if (key.isEmpty) continue;

      final plaintext = (m['text'] ?? '').toString();
      final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
      if (!hasCipher || plaintext.isNotEmpty) continue;

      final persisted = PlaintextCache.tryGetDm(otherLoginLower: loginLower, messageKey: key);
      if (persisted != null && persisted.isNotEmpty) {
        _decryptedCache[key] ??= persisted;
        continue;
      }
      if (_decryptedCache.containsKey(key) || _decrypting.contains(key)) continue;

      if (processed >= batchSize) {
        hasMore = true;
        continue;
      }

      processed++;
      _decrypting.add(key);
      try {
        final fromUid = (m['fromUid'] ?? '').toString();
        final otherUid = (fromUid == myUid)
            ? (peerUid ?? '')
            : (fromUid.isNotEmpty ? fromUid : (peerUid ?? ''));
        if (otherUid.isEmpty) {
          hasMore = true;
          continue;
        }

        final plain = await E2ee.decryptFromUser(otherUid: otherUid, message: m);
        if (!mounted) return;
        if (((_activeLogin ?? '').trim().toLowerCase()) != loginLower) return;

        setState(() => _decryptedCache[key] = plain);
        PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: key, plaintext: plain);
      } catch (_) {
        // ignore
      } finally {
        _decrypting.remove(key);
      }

      // Yield to UI.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    if (!mounted) return;
    if (((_activeLogin ?? '').trim().toLowerCase()) != loginLower) return;

    if (hasMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _warmupDmDecryptAll(items: items, loginLower: loginLower, myUid: myUid);
      });
    }
  }

  Future<void> _warmupGroupDecryptAll({
    required List<Map<String, dynamic>> items,
    required String groupId,
    required String myUid,
  }) async {
    if (!mounted) return;
    if (_activeGroupId != groupId) return;

    const batchSize = 3;
    var processed = 0;
    var hasMore = false;

    for (final m in items) {
      if (!mounted) return;
      if (_activeGroupId != groupId) return;

      final key = (m['__key'] ?? '').toString();
      if (key.isEmpty) continue;

      final plaintext = (m['text'] ?? '').toString();
      final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
      if (!hasCipher || plaintext.isNotEmpty) continue;

      final persisted = PlaintextCache.tryGetGroup(groupId: groupId, messageKey: key);
      final memKey = 'g:$groupId:$key';
      if (persisted != null && persisted.isNotEmpty) {
        _decryptedCache[memKey] ??= persisted;
        continue;
      }
      if (_decryptedCache.containsKey(memKey) || _decrypting.contains(memKey)) continue;

      if (processed >= batchSize) {
        hasMore = true;
        continue;
      }

      processed++;
      _decrypting.add(memKey);
      try {
        SecretKey? gk = _groupKeyCache[groupId];
        gk ??= await E2ee.fetchGroupKey(groupId: groupId, myUid: myUid);
        if (gk != null) _groupKeyCache[groupId] = gk;

        final plain = await E2ee.decryptGroupMessage(groupId: groupId, myUid: myUid, groupKey: gk, message: m);
        if (!mounted) return;
        if (_activeGroupId != groupId) return;

        setState(() => _decryptedCache[memKey] = plain);
        PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plain);
      } catch (_) {
        // ignore
      } finally {
        _decrypting.remove(memKey);
      }

      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    if (!mounted) return;
    if (_activeGroupId != groupId) return;

    if (hasMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _warmupGroupDecryptAll(items: items, groupId: groupId, myUid: myUid);
      });
    }
  }

  // DM ephemeral messaging controls.
  // 0=use settings, 1=never, 2=1m, 3=1h, 4=1d, 5=burn-after-read
  int _dmTtlMode = 0;
  final Set<String> _ttlDeleting = {};

  int _overviewMode = 0; // 0=priváty, 1=skupiny, 2=složky
  String? _activeFolderId; // when _overviewMode==2

  Future<String?> _myGithubUsername(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/githubUsername').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<String?> _myAvatarUrl(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/avatarUrl').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _showPeerFingerprintDialog({
    required String peerUid,
    required String peerLogin,
  }) async {
    String? peerFp;
    String myFp = '';
    bool? changed;

    try {
      peerFp = await E2ee.fingerprintForUserSigningKey(uid: peerUid, bytes: 8);
      if (peerFp != null && peerFp.isNotEmpty) {
        changed = await E2ee.rememberPeerFingerprint(peerUid: peerUid, fingerprint: peerFp);
      }
    } catch (_) {}

    try {
      myFp = await E2ee.fingerprintForMySigningKey(bytes: 8);
    } catch (_) {}

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLanguage.tr(context, 'Otisky klíčů (anti‑MITM)', 'Key fingerprints (anti‑MITM)')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLanguage.tr(context, 'Porovnejte fingerprint přes jiný kanál (např. osobně).', 'Compare fingerprint via another channel (e.g. in person).')),
            if (changed == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  AppLanguage.tr(context, 'Pozor: fingerprint protějšku se změnil od minula. Může jít o reinstalaci, nebo MITM.', 'Warning: peer fingerprint changed since last time. It could be reinstall or MITM.'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (peerFp != null && peerFp.isNotEmpty && myFp.isNotEmpty && peerFp == myFp)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Pozor: fingerprinty jsou shodné. To je neobvyklé (může jít o sdílené zařízení nebo záměnu účtů).',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Text('${AppLanguage.tr(context, 'Protějšek', 'Peer')} (@$peerLogin):', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (peerFp != null && peerFp.isNotEmpty)
              Row(
                children: [
                  Expanded(child: SelectableText(peerFp)),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(ClipboardData(text: peerFp!)),
                  ),
                ],
              )
            else
              Text(AppLanguage.tr(context, 'Není dostupné (uživatel ještě nezveřejnil klíč).', 'Unavailable (user has not published a key yet).')),
            const SizedBox(height: 12),
            Text('${AppLanguage.tr(context, 'Můj klíč', 'My key')}:', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: SelectableText(myFp.isEmpty ? '—' : myFp)),
                if (myFp.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(ClipboardData(text: myFp)),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(AppLanguage.tr(context, 'Zavřít', 'Close'))),
        ],
      ),
    );
  }

  DatabaseReference _dmContactRef({required String myUid, required String otherLoginLower}) {
    return rtdb().ref('dmContacts/$myUid/$otherLoginLower');
  }

  DatabaseReference _dmRequestRef({required String myUid, required String fromLoginLower}) {
    return rtdb().ref('dmRequests/$myUid/$fromLoginLower');
  }

  Future<bool> _isDmAccepted({required String myUid, required String otherLoginLower}) async {
    final snap = await _dmContactRef(myUid: myUid, otherLoginLower: otherLoginLower).get();
    if (!snap.exists) return false;
    final v = snap.value;
    if (v is bool) return v;
    return true;
  }

  Future<void> _sendDmRequest({
    required String myUid,
    required String myLogin,
    required String otherUid,
    required String otherLogin,
    String? messageText,
  }) async {
    final myAvatar = await _myAvatarUrl(myUid);
    await _sendDmRequestCore(
      myUid: myUid,
      myLogin: myLogin,
      myAvatarUrl: myAvatar,
      otherUid: otherUid,
      otherLogin: otherLogin,
      otherAvatarUrl: _activeAvatarUrl,
      messageText: messageText,
    );
  }

  Future<void> _rejectDmRequest({
    required String myUid,
    required String otherLogin,
  }) async {
    final otherLower = otherLogin.trim().toLowerCase();
    if (otherLower.isEmpty) return;
    final reqSnap = await _dmRequestRef(myUid: myUid, fromLoginLower: otherLower).get();
    final rv = reqSnap.value;
    if (rv is! Map) {
      await _dmRequestRef(myUid: myUid, fromLoginLower: otherLower).remove();
      return;
    }
    final req = Map<String, dynamic>.from(rv);
    final fromUid = (req['fromUid'] ?? '').toString();
    final fromLogin = (req['fromLogin'] ?? otherLogin).toString();

    final myLogin = await _myGithubUsername(myUid);
    final updates = <String, Object?>{
      'dmRequests/$myUid/$otherLower': null,
      'savedChats/$myUid/$fromLogin': null,
    };
    if (fromUid.isNotEmpty && myLogin != null && myLogin.trim().isNotEmpty) {
      updates['savedChats/$fromUid/$myLogin'] = null;
    }
    await rtdb().ref().update(updates);
  }

  Future<void> _acceptDmRequest({
    required String myUid,
    required String otherLogin,
  }) async {
    final otherLoginLower = otherLogin.trim().toLowerCase();
    final reqSnap = await _dmRequestRef(myUid: myUid, fromLoginLower: otherLoginLower).get();
    final rv = reqSnap.value;
    if (rv is! Map) return;
    final req = Map<String, dynamic>.from(rv);
    final fromUid = (req['fromUid'] ?? '').toString();
    final fromLogin = (req['fromLogin'] ?? otherLogin).toString();
    final fromAvatarUrl = (req['fromAvatarUrl'] ?? '').toString();
    if (fromUid.isEmpty) return;

    final myLogin = await _myGithubUsername(myUid);
    if (myLogin == null || myLogin.trim().isEmpty) {
      throw Exception('Nelze zjistit tvůj GitHub username.');
    }

    // Ensure my E2EE bundle is published as soon as we accept a private chat.
    // This makes fingerprints/keys available to the other side immediately.
    try {
      await E2ee.publishMyPublicKey(uid: myUid);
    } catch (_) {}

    final myLoginLower = myLogin.trim().toLowerCase();

    // Extract optional encrypted message fields from the request.
    final enc = <String, Object?>{};
    for (final k in ['e2eeV', 'alg', 'nonce', 'ciphertext', 'mac', 'dh', 'pn', 'n', 'init', 'spkId']) {
      if (req[k] != null) enc[k] = req[k];
    }

    final myAvatar = await _myAvatarUrl(myUid);

    final updates = <String, Object?>{
      'dmContacts/$myUid/$otherLoginLower': true,
      'dmContacts/$fromUid/$myLoginLower': true,
      'savedChats/$myUid/$fromLogin': {
        'login': fromLogin,
        if (fromAvatarUrl.isNotEmpty) 'avatarUrl': fromAvatarUrl,
        'status': 'accepted',
        'lastMessageText': '🔒',
        'lastMessageAt': ServerValue.timestamp,
        'savedAt': ServerValue.timestamp,
      },
      'savedChats/$fromUid/$myLogin': {
        'login': myLogin,
        if (myAvatar != null) 'avatarUrl': myAvatar,
        'status': 'accepted',
        'lastMessageText': '🔒',
        'lastMessageAt': ServerValue.timestamp,
        'savedAt': ServerValue.timestamp,
      },
      'dmRequests/$myUid/$otherLoginLower': null,
    };

    if (enc.isNotEmpty) {
      final key = rtdb().ref().push().key;
      if (key != null && key.isNotEmpty) {
        final msg = {
          ...enc,
          'fromUid': fromUid,
          'createdAt': ServerValue.timestamp,
        };
        updates['messages/$myUid/$fromLogin/$key'] = msg;
        updates['messages/$fromUid/$myLogin/$key'] = msg;
      }
    }

    await rtdb().ref().update(updates);
  }

  bool handleBack() {
    if (_activeLogin != null) {
      setState(() {
        _activeLogin = null;
        _activeAvatarUrl = null;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
        _pendingCodePayload = null;
        _replyToKey = null;
        _replyToFrom = null;
        _replyToPreview = null;
      });
      return true;
    }
    if (_activeGroupId != null) {
      _typingTimeout?.cancel();
      _setGroupTyping(groupId: _activeGroupId!, value: false);
      setState(() {
        _activeGroupId = null;
        _pendingCodePayload = null;
        _replyToKey = null;
        _replyToFrom = null;
        _replyToPreview = null;
      });
      return true;
    }
    if (_activeVerifiedUid != null) {
      setState(() {
        _activeVerifiedUid = null;
        _activeVerifiedGithub = null;
      });
      return true;
    }
    if (_overviewMode == 2) {
      if (_activeFolderId != null) {
        setState(() => _activeFolderId = null);
        return true;
      }
      setState(() => _overviewMode = 0);
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _typingAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
    _activeLogin = widget.initialOpenLogin;
    _activeAvatarUrl = widget.initialOpenAvatarUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prewarmDmDecryptAfterJoin();
      _prewarmGroupDecryptAfterJoin();
    });
  }

  @override
  void didUpdateWidget(covariant _ChatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.overviewToken != oldWidget.overviewToken) {
      setState(() {
        _activeLogin = null;
        _activeAvatarUrl = null;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
        _activeGroupId = null;
        _activeVerifiedUid = null;
        _activeVerifiedGithub = null;
        _activeFolderId = null;
        _overviewMode = 0;
        _pendingCodePayload = null;
        _replyToKey = null;
        _replyToFrom = null;
        _replyToPreview = null;
      });
      return;
    }

    if (widget.openChatToken != oldWidget.openChatToken && widget.initialOpenLogin != null) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
        _pendingCodePayload = null;
        _replyToKey = null;
        _replyToFrom = null;
        _replyToPreview = null;
      });
      return;
    }

    if (widget.initialOpenLogin != null && widget.initialOpenLogin != oldWidget.initialOpenLogin) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
        _pendingCodePayload = null;
        _replyToKey = null;
        _replyToFrom = null;
        _replyToPreview = null;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _typingTimeout?.cancel();
    _setTyping(false);
    if (_activeGroupId != null) {
      _setGroupTyping(groupId: _activeGroupId!, value: false);
    }
    _typingAnim.dispose();
    super.dispose();
  }

  void _hapticSelect() {
    if (widget.settings.vibrationEnabled) {
      HapticFeedback.selectionClick();
    }
  }

  void _hapticMedium() {
    if (widget.settings.vibrationEnabled) {
      HapticFeedback.mediumImpact();
    }
  }

  Future<String?> _lookupUidForLoginLower(String loginLower) async {
    final snap = await rtdb().ref('usernames/$loginLower').get();
    final v = snap.value;
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _prewarmDmDecryptAfterJoin() async {
    if (_prewarmDecryptStarted) return;
    _prewarmDecryptStarted = true;

    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final myUid = current.uid;

    try {
      final rootSnap = await rtdb().ref('messages/$myUid').get();
      final rootValue = rootSnap.value;
      final root = (rootValue is Map) ? rootValue : null;
      if (root == null) return;

      final peerUidByLoginLower = <String, String?>{};

      for (final threadEntry in root.entries) {
        if (!mounted) return;

        final login = threadEntry.key.toString();
        final loginLower = login.trim().toLowerCase();
        if (loginLower.isEmpty) continue;

        if (!peerUidByLoginLower.containsKey(loginLower)) {
          peerUidByLoginLower[loginLower] = await _lookupUidForLoginLower(loginLower);
        }
        final peerUid = peerUidByLoginLower[loginLower];

        final threadRaw = threadEntry.value;
        if (threadRaw is! Map) continue;

        final items = <Map<String, dynamic>>[];
        for (final msgEntry in threadRaw.entries) {
          if (msgEntry.value is! Map) continue;
          final m = Map<String, dynamic>.from(msgEntry.value as Map);
          m['__key'] = msgEntry.key.toString();
          items.add(m);
        }

        items.sort((a, b) {
          final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
          final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
          return bt.compareTo(at);
        });

        for (final m in items) {
          if (!mounted) return;

          final key = (m['__key'] ?? '').toString();
          if (key.isEmpty) continue;

          final plaintext = (m['text'] ?? '').toString();
          final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
          if (!hasCipher || plaintext.isNotEmpty) continue;

          final persisted = PlaintextCache.tryGetDm(otherLoginLower: loginLower, messageKey: key);
          if (persisted != null && persisted.isNotEmpty) continue;

          final fromUid = (m['fromUid'] ?? '').toString();
          final otherUid = (fromUid == myUid)
              ? (peerUid ?? '')
              : (fromUid.isNotEmpty ? fromUid : (peerUid ?? ''));
          if (otherUid.isEmpty) continue;

          try {
            final plain = await E2ee.decryptFromUser(otherUid: otherUid, message: m);
            PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: key, plaintext: plain);
          } catch (_) {
            // best-effort: warm-up should never break UI flow
          }
        }
      }
    } catch (_) {
      // best-effort
    }
  }

  Future<void> _prewarmGroupDecryptAfterJoin() async {
    if (_prewarmGroupDecryptStarted) return;
    _prewarmGroupDecryptStarted = true;

    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final myUid = current.uid;

    try {
      final ugSnap = await rtdb().ref('userGroups/$myUid').get();
      final ugv = ugSnap.value;
      final ugm = (ugv is Map) ? ugv : null;
      if (ugm == null || ugm.isEmpty) return;

      final groupIds = <String>[];
      for (final e in ugm.entries) {
        if (e.value == true) {
          groupIds.add(e.key.toString());
        }
      }

      for (final groupId in groupIds) {
        if (!mounted) return;
        if (groupId.trim().isEmpty) continue;

        SecretKey? gk;
        try {
          gk = await E2ee.fetchGroupKey(groupId: groupId, myUid: myUid);
          if (gk != null) {
            _groupKeyCache[groupId] = gk;
          }
        } catch (_) {
          gk = null;
        }

        final snap = await rtdb().ref('groupMessages/$groupId').get();
        final vv = snap.value;
        final root = (vv is Map) ? vv : null;
        if (root == null || root.isEmpty) continue;

        for (final entry in root.entries) {
          if (!mounted) return;
          final key = entry.key.toString();
          final raw = entry.value;
          if (key.isEmpty || raw is! Map) continue;

          final m = Map<String, dynamic>.from(raw);
          final plaintext = (m['text'] ?? '').toString();
          if (plaintext.isNotEmpty) {
            PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plaintext);
            continue;
          }

          final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
          if (!hasCipher) continue;

          final persisted = PlaintextCache.tryGetGroup(groupId: groupId, messageKey: key);
          if (persisted != null && persisted.isNotEmpty) continue;

          try {
            final plain = await E2ee.decryptGroupMessage(
              groupId: groupId,
              myUid: myUid,
              groupKey: gk,
              message: m,
            );
            PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plain);
          } catch (_) {
            // best-effort
          }
        }
      }

      await PlaintextCache.flushNow();
    } catch (_) {
      // best-effort
    }
  }

  Future<String?> _ensureActiveOtherUid() async {
    final login = _activeLogin;
    if (login == null || login.trim().isEmpty) return null;
    final loginLower = login.trim().toLowerCase();
    if (_activeOtherUid != null && _activeOtherUidLoginLower == loginLower) {
      unawaited(_probePeerPublishedKey(loginLower: loginLower, peerUid: _activeOtherUid!));
      return _activeOtherUid;
    }
    final uid = await _lookupUidForLoginLower(loginLower);
    if (!mounted) return uid;
    setState(() {
      _activeOtherUid = uid;
      _activeOtherUidLoginLower = loginLower;
    });
    if (uid != null && uid.isNotEmpty) {
      unawaited(_probePeerPublishedKey(loginLower: loginLower, peerUid: uid));
    }
    return uid;
  }

  Future<void> _probePeerPublishedKey({
    required String loginLower,
    required String peerUid,
  }) async {
    if (loginLower.isEmpty || peerUid.isEmpty) return;
    if (_peerKeyProbeInFlight.contains(loginLower)) return;
    _peerKeyProbeInFlight.add(loginLower);
    try {
      final fp = await E2ee.fingerprintForUserSigningKey(uid: peerUid, bytes: 8);
      final hasKey = (fp ?? '').trim().isNotEmpty;
      if (!mounted) return;
      if (_peerHasPublishedKey[loginLower] == hasKey) return;
      setState(() {
        _peerHasPublishedKey[loginLower] = hasKey;
      });
    } catch (_) {
      // Keep previous cached value if probe fails.
    } finally {
      _peerKeyProbeInFlight.remove(loginLower);
    }
  }

  void _setReplyTarget({required String key, required String from, required String preview}) {
    setState(() {
      _replyToKey = key;
      _replyToFrom = from;
      _replyToPreview = preview;
    });
  }

  void _clearReplyTarget() {
    if (_replyToKey == null && _replyToFrom == null && _replyToPreview == null) return;
    setState(() {
      _replyToKey = null;
      _replyToFrom = null;
      _replyToPreview = null;
    });
  }

  String? _firstUrlInText(String text) {
    final markdownLink = RegExp(r'\[[^\]]+\]\((https?:\/\/[^\s)]+)\)', caseSensitive: false);
    final m1 = markdownLink.firstMatch(text);
    if (m1 != null) {
      final u = (m1.group(1) ?? '').trim();
      if (u.isNotEmpty) return u;
    }

    final plainUrl = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    final m2 = plainUrl.firstMatch(text);
    if (m2 != null) {
      final u = (m2.group(1) ?? '').trim();
      if (u.isNotEmpty) return u;
    }
    return null;
  }

  Future<void> _openCodeSnippetSheet(_CodeMessagePayload payload) async {
    final codeBlock = payload.language.trim().isEmpty
        ? '```\n${payload.code}\n```'
        : '```' + payload.language.trim() + '\n${payload.code}\n```';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  payload.title.trim().isEmpty ? 'Code snippet' : payload.title.trim(),
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (payload.language.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(payload.language.trim(), style: const TextStyle(color: Colors.white70)),
                ],
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: _RichMessageText(
                      text: codeBlock,
                      fontSize: widget.settings.chatTextSize,
                      textColor: Theme.of(ctx).colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: payload.code));
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(AppLanguage.tr(context, 'Kód zkopírován.', 'Code copied.'))),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: Text(AppLanguage.tr(context, 'Kopírovat kód', 'Copy code')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: Text(AppLanguage.tr(context, 'Zavřít', 'Close')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _forwardToUsername({
    required String targetLogin,
    required String messageText,
  }) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    final myLogin = await _myGithubUsername(current.uid);
    if (myLogin == null || myLogin.trim().isEmpty) return;

    final cleaned = targetLogin.trim().replaceFirst(RegExp(r'^@+'), '');
    if (cleaned.isEmpty) return;
    final otherUid = await _lookupUidForLoginLower(cleaned.toLowerCase());
    if (otherUid == null || otherUid.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Cílový uživatel není v GitMit.', 'Target user is not in GitMit.'))),
      );
      return;
    }

    final forwardedText = 'Přeposláno:\n$messageText';
    final accepted = await _isDmAccepted(myUid: current.uid, otherLoginLower: cleaned.toLowerCase());
    if (!accepted) {
      await _sendDmRequest(
        myUid: current.uid,
        myLogin: myLogin,
        otherUid: otherUid,
        otherLogin: cleaned,
        messageText: forwardedText,
      );
      return;
    }

    final encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: forwardedText);
    final key = rtdb().ref().push().key;
    if (key == null || key.isEmpty) return;
    final nowPayload = {
      ...encrypted,
      'fromUid': current.uid,
      'createdAt': ServerValue.timestamp,
      'forwarded': true,
    };

    final myAvatar = await _myAvatarUrl(current.uid);
    final updates = <String, Object?>{};
    updates['messages/${current.uid}/$cleaned/$key'] = nowPayload;
    updates['messages/$otherUid/$myLogin/$key'] = nowPayload;
    updates['savedChats/${current.uid}/$cleaned'] = {
      'login': cleaned,
      'status': 'accepted',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    };
    updates['savedChats/$otherUid/$myLogin'] = {
      'login': myLogin,
      if (myAvatar != null) 'avatarUrl': myAvatar,
      'status': 'accepted',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    };
    await rtdb().ref().update(updates);
  }

  Future<void> _showMessageActions({
    required bool isGroup,
    required String chatTarget,
    required String messageKey,
    required String fromLabel,
    required String text,
    required bool canDeleteForMe,
    required bool canDeleteForAll,
    Future<void> Function()? onDeleteForMe,
    Future<void> Function()? onDeleteForAll,
  }) async {
    final codePayload = _CodeMessagePayload.tryParse(text);
    final link = _firstUrlInText(text);

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        const emojis = ['👍', '❤️', '😂', '😮', '😢'];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: emojis
                      .map(
                        (e) => TextButton(
                          onPressed: () => Navigator.of(ctx).pop('react:$e'),
                          child: Text(e, style: const TextStyle(fontSize: 22)),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.reply),
                title: Text(AppLanguage.tr(context, 'Odpovědět', 'Reply')),
                onTap: () => Navigator.of(ctx).pop('reply'),
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(AppLanguage.tr(context, 'Kopírovat', 'Copy')),
                onTap: () => Navigator.of(ctx).pop('copy'),
              ),
              if (link != null)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(AppLanguage.tr(context, 'Kopírovat odkaz', 'Copy link')),
                  onTap: () => Navigator.of(ctx).pop('copy_link'),
                ),
              ListTile(
                leading: const Icon(Icons.forward_to_inbox_outlined),
                title: Text(AppLanguage.tr(context, 'Přeposlat', 'Forward')),
                onTap: () => Navigator.of(ctx).pop('forward'),
              ),
              if (codePayload != null)
                ListTile(
                  leading: const Icon(Icons.code),
                  title: Text(AppLanguage.tr(context, 'Otevřít kód', 'Open code')),
                  onTap: () => Navigator.of(ctx).pop('open_code'),
                ),
              if (canDeleteForMe && onDeleteForMe != null)
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(AppLanguage.tr(context, 'Smazat u mě', 'Delete for me')),
                  onTap: () => Navigator.of(ctx).pop('delete_me'),
                ),
              if (canDeleteForAll && onDeleteForAll != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(AppLanguage.tr(context, 'Smazat u všech', 'Delete for everyone')),
                  onTap: () => Navigator.of(ctx).pop('delete_all'),
                ),
            ],
          ),
        );
      },
    );

    if (action == null) return;

    if (action.startsWith('react:')) {
      final emoji = action.substring('react:'.length);
      if (isGroup) {
        final current = FirebaseAuth.instance.currentUser;
        if (current != null) {
          await rtdb().ref('groupMessages/$chatTarget/$messageKey/reactions/$emoji/${current.uid}').set(true);
        }
      } else {
        await _reactToMessage(login: chatTarget, messageKey: messageKey, emoji: emoji);
      }
      return;
    }

    switch (action) {
      case 'reply':
        final preview = codePayload?.previewLabel() ?? text.replaceAll('\n', ' ').trim();
        final limited = preview.length > 120 ? '${preview.substring(0, 120)}…' : preview;
        _setReplyTarget(key: messageKey, from: fromLabel, preview: limited);
        return;
      case 'copy':
        final copied = codePayload?.code ?? text;
        await Clipboard.setData(ClipboardData(text: copied));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr(context, 'Zkopírováno.', 'Copied.'))),
        );
        return;
      case 'copy_link':
        if (link != null) {
          await Clipboard.setData(ClipboardData(text: link));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLanguage.tr(context, 'Odkaz zkopírován.', 'Link copied.'))),
          );
        }
        return;
      case 'forward':
        final targetCtrl = TextEditingController();
        final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(AppLanguage.tr(context, 'Přeposlat zprávu', 'Forward message')),
                content: TextField(
                  controller: targetCtrl,
                  decoration: InputDecoration(
                    labelText: AppLanguage.tr(context, 'GitHub username', 'GitHub username'),
                    prefixText: '@',
                  ),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel'))),
                  TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(AppLanguage.tr(context, 'Přeposlat', 'Forward'))),
                ],
              ),
            ) ??
            false;
        if (!ok) return;
        final target = targetCtrl.text.trim();
        if (target.isEmpty) return;
        await _forwardToUsername(targetLogin: target, messageText: codePayload?.code ?? text);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr(context, 'Přeposláno.', 'Forwarded.'))),
        );
        return;
      case 'open_code':
        if (codePayload != null) {
          await _openCodeSnippetSheet(codePayload);
        }
        return;
      case 'delete_me':
        if (canDeleteForMe && onDeleteForMe != null) {
          await onDeleteForMe();
        }
        return;
      case 'delete_all':
        if (canDeleteForAll && onDeleteForAll != null) {
          await onDeleteForAll();
        }
        return;
    }
  }

  Future<void> _insertCodeBlockTemplate() async {
    final langCtrl = TextEditingController();
    final titleCtrl = TextEditingController();
    final codeCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        return SafeArea(
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
            child: FractionallySizedBox(
              heightFactor: 0.9,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      AppLanguage.tr(context, 'Vložit code block', 'Insert code block'),
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: langCtrl,
                      decoration: InputDecoration(
                        labelText: AppLanguage.tr(context, 'Jazyk (volitelné)', 'Language (optional)'),
                        hintText: AppLanguage.tr(context, 'dart, js, ts, python, ...', 'dart, js, ts, python, ...'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: titleCtrl,
                      decoration: InputDecoration(
                        labelText: AppLanguage.tr(context, 'Název snippetu (volitelné)', 'Snippet title (optional)'),
                        hintText: AppLanguage.tr(context, 'Např. Login handler', 'e.g. Login handler'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        controller: codeCtrl,
                        minLines: null,
                        maxLines: null,
                        expands: true,
                        decoration: InputDecoration(
                          labelText: AppLanguage.tr(context, 'Kód', 'Code'),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              final lang = langCtrl.text.trim();
                              final title = titleCtrl.text.trim();
                              final code = codeCtrl.text;
                              if (code.trim().isEmpty) return;

                              final payload = _CodeMessagePayload(
                                title: title,
                                language: lang,
                                code: code,
                              );

                              setState(() {
                                _pendingCodePayload = payload;
                                _messageController.value = TextEditingValue(
                                  text: payload.previewLabel(),
                                  selection: TextSelection.collapsed(offset: payload.previewLabel().length),
                                );
                              });

                              Navigator.of(ctx).pop();
                            },
                            icon: const Icon(Icons.code),
                            label: Text(AppLanguage.tr(context, 'Vložit', 'Insert')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _notifyGithubNonGitmit({
    required String targetLogin,
    required String fromLogin,
    required String preview,
  }) async {
    final endpoint = _githubDmFallbackUrl.trim();
    if (endpoint.isEmpty) return false;

    final uri = Uri.tryParse(endpoint);
    if (uri == null) return false;

    final payload = jsonEncode({
      'targetLogin': targetLogin,
      'fromLogin': fromLogin,
      'preview': preview,
      'source': 'gitmit',
    });

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_githubDmFallbackToken.trim().isNotEmpty) 'Authorization': 'Bearer ${_githubDmFallbackToken.trim()}',
    };

    final response = await http.post(uri, headers: headers, body: payload);
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Future<void> _moveChatToFolder({required String myUid, required String login}) async {
    final foldersSnap = await rtdb().ref('folders/$myUid').get();
    final fv = foldersSnap.value;
    final fm = (fv is Map) ? fv : null;
    final folders = <Map<String, String>>[];
    if (fm != null) {
      for (final e in fm.entries) {
        if (e.value is! Map) continue;
        final mm = Map<String, dynamic>.from(e.value as Map);
        final name = (mm['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        folders.add({'id': e.key.toString(), 'name': name});
      }
      folders.sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
    }

    final picked = await showModalBottomSheet<String?>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(AppLanguage.tr(context, 'Přesunout do složky', 'Move to folder'), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              ListTile(
                leading: const Icon(Icons.inbox_outlined),
                title: Text(AppLanguage.tr(context, 'Priváty', 'Private')),
                onTap: () => Navigator.of(context).pop(null),
              ),
              const Divider(height: 1),
              ...folders.map((f) {
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f['name'] ?? AppLanguage.tr(context, 'Složka', 'Folder')),
                  onTap: () => Navigator.of(context).pop(f['id']),
                );
              }),
            ],
          ),
        );
      },
    );

    final key = login.trim().toLowerCase();
    if (picked == null) {
      await rtdb().ref('chatFolders/$myUid/$key').remove();
    } else {
      await rtdb().ref('chatFolders/$myUid/$key').set(picked);
    }
  }

  Color _bubbleColor(BuildContext context, String key) {
    return _resolveBubbleColor(context, key);
  }

  Color _bubbleTextColor(BuildContext context, String key) {
    return _resolveBubbleTextColor(context, key);
  }

  Future<void> _send() async {
    final current = FirebaseAuth.instance.currentUser;
    final login = _activeLogin;
    final text = _messageController.text.trim();
    if (current == null || login == null || text.isEmpty) return;

    final pendingCode = _pendingCodePayload;
    final isPendingCodeText = pendingCode != null && text.startsWith('<> kód');
    final replyToKey = _replyToKey;
    final replyToFrom = _replyToFrom;
    final replyToPreview = _replyToPreview;

    String outgoingText;
    if (isPendingCodeText) {
      outgoingText = jsonEncode(pendingCode.toJson());
    } else {
      outgoingText = text;
    }

    if (replyToFrom != null && replyToFrom.trim().isNotEmpty && !outgoingText.trim().startsWith('@')) {
      final cleanFrom = replyToFrom.trim().replaceFirst(RegExp(r'^@+'), '');
      outgoingText = '@$cleanFrom $outgoingText';
    }

    final myLogin = await _myGithubUsername(current.uid);
    if (myLogin == null || myLogin.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLanguage.tr(context, 'Nelze zjistit tvůj GitHub username.', 'Unable to determine your GitHub username.'))),
        );
      }
      return;
    }

    final otherUid = await _ensureActiveOtherUid();
    if (otherUid == null || otherUid.isEmpty) {
      var sentFallback = false;
      try {
        sentFallback = await _notifyGithubNonGitmit(
          targetLogin: login,
          fromLogin: myLogin,
          preview: outgoingText,
        );
      } catch (_) {
        sentFallback = false;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sentFallback
                  ? AppLanguage.tr(context, 'Uživatel není v GitMit. Poslán GitHub ping přes backend.', 'User is not in GitMit. GitHub ping sent via backend.')
                  : AppLanguage.tr(context, 'Uživatel není v GitMit (nenalezené UID).', 'User is not in GitMit (UID not found).'),
            ),
          ),
        );
      }
      return;
    }

    try {
      await E2ee.publishMyPublicKey(uid: current.uid);
    } catch (_) {
      // best-effort
    }

    final otherLoginLower = login.trim().toLowerCase();

    Map<String, Object?> encrypted;
    try {
      encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: outgoingText);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${AppLanguage.tr(context, 'E2EE: šifrování selhalo', 'E2EE: encryption failed')}: $e')),
        );
      }
      return;
    }

    _messageController.clear();
    _typingTimeout?.cancel();
    _setTyping(false);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final burnAfterRead = _dmTtlMode == 5;
    final ttlSeconds = switch (_dmTtlMode) {
      0 => widget.settings.autoDeleteSeconds,
      1 => 0,
      2 => 60,
      3 => 60 * 60,
      4 => 60 * 60 * 24,
      _ => widget.settings.autoDeleteSeconds,
    };
    final expiresAt = (!burnAfterRead && ttlSeconds > 0) ? (nowMs + (ttlSeconds * 1000)) : null;

    final key = rtdb().ref().push().key;
    if (key == null || key.isEmpty) return;

    final msg = {
      ...encrypted,
      'fromUid': current.uid,
      'createdAt': ServerValue.timestamp,
      if (replyToKey != null && replyToKey.trim().isNotEmpty) 'replyToKey': replyToKey,
      if (replyToFrom != null && replyToFrom.trim().isNotEmpty) 'replyToFrom': replyToFrom,
      if (replyToPreview != null && replyToPreview.trim().isNotEmpty) 'replyToPreview': replyToPreview,
      if (expiresAt != null) 'expiresAt': expiresAt,
      if (burnAfterRead) 'burnAfterRead': true,
    };

    final updates = <String, Object?>{};
    updates['messages/${current.uid}/$login/$key'] = msg;
    updates['messages/$otherUid/$myLogin/$key'] = msg;

    // Chat tiles for both sides.
    updates['savedChats/${current.uid}/$login'] = {
      'login': login,
      if (_activeAvatarUrl != null && _activeAvatarUrl!.isNotEmpty) 'avatarUrl': _activeAvatarUrl,
      'status': 'accepted',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    };
    final myAvatar = await _myAvatarUrl(current.uid);
    updates['savedChats/$otherUid/$myLogin'] = {
      'login': myLogin,
      if (myAvatar != null) 'avatarUrl': myAvatar,
      'status': 'accepted',
      'lastMessageText': '🔒',
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    };

    await rtdb().ref().update(updates);

    // Show our own message immediately (avoid "🔒 …" placeholder).
    if (mounted) {
      setState(() {
        _decryptedCache[key] = outgoingText;
        _pendingCodePayload = null;
      });
      PlaintextCache.putDm(otherLoginLower: otherLoginLower, messageKey: key, plaintext: outgoingText);
    }
    _clearReplyTarget();

    if (widget.settings.vibrationEnabled) {
      HapticFeedback.lightImpact();
    }
    if (widget.settings.soundsEnabled) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> _reactToMessage({required String login, required String messageKey, required String emoji}) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    // Enforce: one reaction per user per message.
    final basePath = 'messages/${current.uid}/$login/$messageKey/reactions';
    final reactionsSnap = await rtdb().ref(basePath).get();
    final v = reactionsSnap.value;
    final updates = <String, Object?>{};
    if (v is Map) {
      for (final e in v.entries) {
        final existingEmoji = e.key.toString();
        final voters = e.value;
        if (voters is Map && voters.containsKey(current.uid)) {
          updates['$basePath/$existingEmoji/${current.uid}'] = null;
        }
      }
    }
    updates['$basePath/$emoji/${current.uid}'] = true;
    await rtdb().ref().update(updates);
  }

  Future<void> _openUserProfile({required String login, required String avatarUrl}) async {
    final res = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _UserProfilePage(
          login: login,
          avatarUrl: avatarUrl,
          githubDataFuture: _fetchGithubProfileData(login),
        ),
      ),
    );

    if (!mounted) return;
    if (res == 'deleted_chat_for_me' || res == 'deleted_chat_for_both') {
      setState(() {
        _activeLogin = null;
        _activeAvatarUrl = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLanguage.tr(context, 'Chat byl smazán.', 'Chat was deleted.'))),
      );
    }
  }

  Future<void> _sendVerified({required bool asModerator, required String moderatorGithub}) async {
    final current = FirebaseAuth.instance.currentUser;
    final requestUid = _activeVerifiedUid;
    final text = _messageController.text.trim();
    if (current == null || requestUid == null || text.isEmpty) return;
    _messageController.clear();

    if (asModerator) {
      await _sendVerifiedMessage(
        requestUid: requestUid,
        from: 'moderator',
        text: text,
        important: true,
        anonymous: _moderatorAnonymous,
        moderatorGithub: moderatorGithub,
        markNewForRequester: true,
      );
    } else {
      await _sendVerifiedMessage(
        requestUid: requestUid,
        from: 'user',
        text: text,
        important: false,
        anonymous: false,
        markNewForRequester: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return Center(child: Text(AppLanguage.tr(context, 'Nepřihlášen.', 'Not signed in.')));
    }

    final currentUserRef = rtdb().ref('users/${current.uid}');
    final invitesRef = rtdb().ref('groupInvites/${current.uid}');

    // Seznam chatů + ověření
    if (_activeLogin == null && _activeVerifiedUid == null && _activeGroupId == null) {
      final chatsMetaRef = rtdb().ref('savedChats/${current.uid}');
      final chatsMessagesRef = rtdb().ref('messages/${current.uid}');
      final blockedRef = rtdb().ref('blocked/${current.uid}');
      final myVerifyReqRef = _verifiedRequestRef(current.uid);
      final allVerifyReqsRef = rtdb().ref('verifiedRequests');
      final userGroupsRef = rtdb().ref('userGroups/${current.uid}');
      final groupsRef = rtdb().ref('groups');

      return StreamBuilder<DatabaseEvent>(
        stream: currentUserRef.onValue,
        builder: (context, userSnap) {
          final uval = userSnap.data?.snapshot.value;
          final umap = (uval is Map) ? uval : null;
          final myGithub = umap?['githubUsername']?.toString() ?? '';
          final isModerator = _isModeratorFromUserMap(umap);

          return StreamBuilder<DatabaseEvent>(
            stream: myVerifyReqRef.onValue,
            builder: (context, myReqSnap) {
              final rv = myReqSnap.data?.snapshot.value;
              final myReq = (rv is Map) ? rv : null;
              final myStatus = myReq?['status']?.toString();
              final hasNew = myReq?['hasNewModeratorMessage'] == true;

              return StreamBuilder<DatabaseEvent>(
                stream: isModerator ? allVerifyReqsRef.onValue : null,
                builder: (context, allReqSnap) {
                  final allVal = allReqSnap.data?.snapshot.value;
                  final allMap = (allVal is Map) ? allVal : null;
                  final pendingReqs = <Map<String, dynamic>>[];
                  if (isModerator && allMap != null) {
                    for (final entry in allMap.entries) {
                      final uid = entry.key.toString();
                      final v = entry.value;
                      if (v is! Map) continue;
                      final m = Map<String, dynamic>.from(v);
                      if ((m['status'] ?? '').toString() == 'pending') {
                        m['uid'] = uid;
                        pendingReqs.add(m);
                      }
                    }
                    pendingReqs.sort((a, b) {
                      final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                      final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                      return bt.compareTo(at);
                    });
                  }

                  return StreamBuilder<DatabaseEvent>(
                    stream: blockedRef.onValue,
                    builder: (context, blockedSnap) {
                      final bv = blockedSnap.data?.snapshot.value;
                      final blockedMap = (bv is Map) ? bv : null;

                      return StreamBuilder<DatabaseEvent>(
                        stream: chatsMetaRef.onValue,
                        builder: (context, metaSnap) {
                          final mv = metaSnap.data?.snapshot.value;
                          final metaMap = (mv is Map) ? mv : null;

                          return StreamBuilder<DatabaseEvent>(
                            stream: chatsMessagesRef.onValue,
                            builder: (context, msgSnap) {
                              final vv = msgSnap.data?.snapshot.value;
                              final root = (vv is Map) ? vv : null;

                              final rows = <Map<String, Object?>>[];
                              final handled = <String>{};
                              if (root != null) {
                                for (final entry in root.entries) {
                                  final login = entry.key.toString();
                                  final lower = login.trim().toLowerCase();
                                  final blocked = (blockedMap != null && blockedMap[lower] == true);
                                  if (blocked) continue;

                                  final thread = (entry.value is Map) ? (entry.value as Map) : null;
                                  if (thread == null || thread.isEmpty) continue;

                                  int lastAt = 0;
                                  String lastText = '';
                                  for (final me in thread.entries) {
                                    if (me.value is! Map) continue;
                                    final mm = Map<String, dynamic>.from(me.value as Map);
                                    final createdAt = (mm['createdAt'] is int) ? mm['createdAt'] as int : 0;
                                    if (createdAt >= lastAt) {
                                      lastAt = createdAt;
                                      lastText = (mm['text'] ?? '').toString();
                                    }
                                  }

                                  final meta = (metaMap != null && metaMap[login] is Map) ? (metaMap[login] as Map) : null;
                                  final avatarUrl = (meta?['avatarUrl'] ?? '').toString();
                                  final status = (meta?['status'] ?? 'accepted').toString();
                                  if (status.startsWith('pending')) {
                                    lastText = 'Žádost o chat';
                                  } else if (lastText.trim().isEmpty) {
                                    lastText = '🔒';
                                  }

                                  handled.add(lower);

                                  rows.add({
                                    'login': login,
                                    'avatarUrl': avatarUrl,
                                    'lastAt': lastAt,
                                    'lastText': lastText,
                                    'status': status,
                                  });
                                }
                              }

                              // Include pending chats from savedChats even when thread doesn't exist yet.
                              if (metaMap != null) {
                                for (final entry in metaMap.entries) {
                                  final login = entry.key.toString();
                                  final lower = login.trim().toLowerCase();
                                  if (handled.contains(lower)) continue;
                                  final blocked = (blockedMap != null && blockedMap[lower] == true);
                                  if (blocked) continue;
                                  if (entry.value is! Map) continue;
                                  final meta = Map<String, dynamic>.from(entry.value as Map);
                                  final status = (meta['status'] ?? 'accepted').toString();
                                  if (!(status.startsWith('pending') || status == 'accepted')) continue;
                                  final avatarUrl = (meta['avatarUrl'] ?? '').toString();
                                  final lastAt = (meta['lastMessageAt'] is int)
                                      ? meta['lastMessageAt'] as int
                                      : ((meta['savedAt'] is int) ? meta['savedAt'] as int : 0);
                                  final lastText = status.startsWith('pending') ? 'Žádost o chat' : '🔒';
                                  rows.add({
                                    'login': login,
                                    'avatarUrl': avatarUrl,
                                    'lastAt': lastAt,
                                    'lastText': lastText,
                                    'status': status,
                                  });
                                }
                              }

                              rows.sort((a, b) => ((b['lastAt'] as int?) ?? 0).compareTo(((a['lastAt'] as int?) ?? 0)));

                              return ListView(
                                children: [
                          if (myStatus != null) ...[
                            ListTile(
                              leading: const Icon(Icons.verified_user),
                              title: Text(AppLanguage.tr(context, 'Ověření účtu', 'Account verification')),
                              subtitle: Text(_statusText(context, myStatus)),
                              trailing: hasNew ? const Icon(Icons.circle, size: 10, color: Colors.redAccent) : null,
                              onTap: () async {
                                setState(() {
                                  _activeVerifiedUid = current.uid;
                                  _activeVerifiedGithub = myGithub;
                                });
                                await myVerifyReqRef.update({'hasNewModeratorMessage': false});
                              },
                            ),
                            const Divider(height: 1),
                          ],

                          // Pozvánky do skupin (pod ověřením účtu)
                          StreamBuilder<DatabaseEvent>(
                            stream: invitesRef.onValue,
                            builder: (context, invSnap) {
                              final iv = invSnap.data?.snapshot.value;
                              final imap = (iv is Map) ? iv : null;
                              final invites = <Map<String, dynamic>>[];
                              if (imap != null) {
                                for (final e in imap.entries) {
                                  if (e.value is! Map) continue;
                                  final m = Map<String, dynamic>.from(e.value as Map);
                                  m['__key'] = e.key.toString();
                                  invites.add(m);
                                }
                                invites.sort((a, b) {
                                  final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                                  final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                                  return bt.compareTo(at);
                                });
                              }

                              Future<void> acceptInvite(String key, Map<String, dynamic> inv) async {
                                final groupId = (inv['groupId'] ?? '').toString();
                                if (groupId.isEmpty) return;
                                await rtdb().ref('groupMembers/$groupId/${current.uid}').set({
                                  'role': 'member',
                                  'joinedAt': ServerValue.timestamp,
                                  'joinedVia': 'invite',
                                });
                                await rtdb().ref('userGroups/${current.uid}/$groupId').set(true);
                                await invitesRef.child(key).remove();
                              }

                              Future<void> declineInvite(String key) async {
                                await invitesRef.child(key).remove();
                              }

                              Future<void> acceptAll() async {
                                for (final inv in invites) {
                                  final key = (inv['__key'] ?? '').toString();
                                  if (key.isEmpty) continue;
                                  await acceptInvite(key, inv);
                                }
                              }

                              Future<void> declineAll() async {
                                for (final inv in invites) {
                                  final key = (inv['__key'] ?? '').toString();
                                  if (key.isEmpty) continue;
                                  await declineInvite(key);
                                }
                              }

                              if (invites.isEmpty) return const SizedBox.shrink();

                              return Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.group_add),
                                    title: Text(AppLanguage.tr(context, 'Pozvánky do skupin', 'Group invites')),
                                    subtitle: Text('${AppLanguage.tr(context, 'Čeká', 'Pending')}: ${invites.length}'),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: acceptAll,
                                            child: Text(AppLanguage.tr(context, 'Přijmout všechny', 'Accept all')),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: declineAll,
                                            child: Text(AppLanguage.tr(context, 'Odmítnout všechny', 'Decline all')),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ...invites.map((inv) {
                                    final key = (inv['__key'] ?? '').toString();
                                    final groupTitle = (inv['groupTitle'] ?? AppLanguage.tr(context, 'Skupina', 'Group')).toString();
                                    final groupId = (inv['groupId'] ?? '').toString();
                                    final invitedBy = (inv['invitedByGithub'] ?? '').toString();
                                    final groupLogo = (inv['groupLogoUrl'] ?? '').toString();
                                    return ListTile(
                                      leading: CircleAvatar(
                                        radius: 18,
                                        backgroundImage: groupLogo.isNotEmpty ? NetworkImage(groupLogo) : null,
                                        child: groupLogo.isEmpty ? const Icon(Icons.group) : null,
                                      ),
                                      title: Text(groupTitle),
                                      subtitle: invitedBy.isNotEmpty ? Text('${AppLanguage.tr(context, 'Pozval', 'Invited by')}: @$invitedBy') : (groupId.isNotEmpty ? Text(groupId) : null),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.close),
                                            onPressed: () => declineInvite(key),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.check),
                                            onPressed: () => acceptInvite(key, inv),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  const Divider(height: 1),
                                ],
                              );
                            },
                          ),

                          // Inbox pro adminy skupin: žádosti od členů na přidání lidí
                          StreamBuilder<DatabaseEvent>(
                            stream: rtdb().ref('groupAdminInbox/${current.uid}').onValue,
                            builder: (context, inboxSnap) {
                              final iv = inboxSnap.data?.snapshot.value;
                              final im = (iv is Map) ? iv : null;
                              final items = <Map<String, dynamic>>[];
                              if (im != null) {
                                for (final e in im.entries) {
                                  if (e.value is! Map) continue;
                                  final m = Map<String, dynamic>.from(e.value as Map);
                                  m['__key'] = e.key.toString();
                                  items.add(m);
                                }
                                items.sort((a, b) {
                                  final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                                  final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                                  return bt.compareTo(at);
                                });
                              }

                              Future<void> _cleanupAllAdmins({required String groupId, required String targetLower}) async {
                                final membersSnap = await rtdb().ref('groupMembers/$groupId').get();
                                final mv = membersSnap.value;
                                final m = (mv is Map) ? mv : null;
                                if (m != null) {
                                  for (final e in m.entries) {
                                    if (e.value is! Map) continue;
                                    final mm = Map<String, dynamic>.from(e.value as Map);
                                    final role = (mm['role'] ?? 'member').toString();
                                    if (role != 'admin') continue;
                                    final adminUid = e.key.toString();
                                    await rtdb().ref('groupAdminInbox/$adminUid/${groupId}~$targetLower').remove();
                                  }
                                }
                              }

                              Future<void> _approve(Map<String, dynamic> item) async {
                                final key = (item['__key'] ?? '').toString();
                                final groupId = (item['groupId'] ?? '').toString();
                                final targetLower = (item['targetLower'] ?? '').toString();
                                final targetLogin = (item['targetLogin'] ?? '').toString();
                                if (groupId.isEmpty || targetLower.isEmpty) return;

                                final uidSnap = await rtdb().ref('usernames/$targetLower').get();
                                final targetUid = uidSnap.value?.toString();
                                if (targetUid == null || targetUid.isEmpty) {
                                  await _cleanupAllAdmins(groupId: groupId, targetLower: targetLower);
                                  await rtdb().ref('groupJoinRequests/$groupId/$targetLower').remove();
                                  return;
                                }

                                final gSnap = await rtdb().ref('groups/$groupId').get();
                                final gv = gSnap.value;
                                final gm = (gv is Map) ? gv : null;
                                final title = (gm?['title'] ?? '').toString();
                                final logo = (gm?['logoUrl'] ?? '').toString();

                                await rtdb().ref('groupInvites/$targetUid/$groupId').set({
                                  'groupId': groupId,
                                  'groupTitle': title,
                                  if (logo.isNotEmpty) 'groupLogoUrl': logo,
                                  'invitedByUid': current.uid,
                                  'invitedByGithub': myGithub,
                                  'createdAt': ServerValue.timestamp,
                                  'via': 'member_request',
                                  if (targetLogin.isNotEmpty) 'targetLogin': targetLogin,
                                });

                                await _cleanupAllAdmins(groupId: groupId, targetLower: targetLower);
                                await rtdb().ref('groupJoinRequests/$groupId/$targetLower').remove();
                                await rtdb().ref('groupAdminInbox/${current.uid}/$key').remove();
                              }

                              Future<void> _reject(Map<String, dynamic> item) async {
                                final key = (item['__key'] ?? '').toString();
                                final groupId = (item['groupId'] ?? '').toString();
                                final targetLower = (item['targetLower'] ?? '').toString();
                                if (groupId.isEmpty || targetLower.isEmpty) return;
                                await _cleanupAllAdmins(groupId: groupId, targetLower: targetLower);
                                await rtdb().ref('groupJoinRequests/$groupId/$targetLower').remove();
                                await rtdb().ref('groupAdminInbox/${current.uid}/$key').remove();
                              }

                              if (items.isEmpty) return const SizedBox.shrink();

                              return Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.admin_panel_settings_outlined),
                                    title: Text(AppLanguage.tr(context, 'Žádosti do skupin', 'Group requests')),
                                    subtitle: Text('${AppLanguage.tr(context, 'Čeká', 'Pending')}: ${items.length}'),
                                  ),
                                  ...items.map((item) {
                                    final groupId = (item['groupId'] ?? '').toString();
                                    final targetLogin = (item['targetLogin'] ?? '').toString();
                                    final requestedBy = (item['requestedByGithub'] ?? '').toString();
                                    return StreamBuilder<DatabaseEvent>(
                                      stream: (groupId.isEmpty) ? null : rtdb().ref('groups/$groupId').onValue,
                                      builder: (context, gSnap) {
                                        final gv = gSnap.data?.snapshot.value;
                                        final gm = (gv is Map) ? gv : null;
                                        if (gm == null) return const SizedBox.shrink();
                                        final title = (gm['title'] ?? '').toString();
                                        return ListTile(
                                          leading: const Icon(Icons.group),
                                          title: Text(title),
                                          subtitle: Text(
                                            '${AppLanguage.tr(context, 'Přidat', 'Add')}: @${targetLogin.isEmpty ? AppLanguage.tr(context, 'uživatel', 'user') : targetLogin}${requestedBy.isNotEmpty ? ' • ${AppLanguage.tr(context, 'od', 'by')} @$requestedBy' : ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                icon: const Icon(Icons.close),
                                                onPressed: () => _reject(item),
                                              ),
                                              IconButton(
                                                icon: const Icon(Icons.check),
                                                onPressed: () => _approve(item),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  }),
                                  const Divider(height: 1),
                                ],
                              );
                            },
                          ),

                          // DM žádosti (priváty) – notifikace nahoře v přehledu Chaty
                          StreamBuilder<DatabaseEvent>(
                            stream: rtdb().ref('dmRequests/${current.uid}').onValue,
                            builder: (context, reqSnap) {
                              final v = reqSnap.data?.snapshot.value;
                              final m = (v is Map) ? v : null;

                              final items = <Map<String, dynamic>>[];
                              if (m != null) {
                                for (final e in m.entries) {
                                  if (e.value is! Map) continue;
                                  final mm = Map<String, dynamic>.from(e.value as Map);
                                  mm['__key'] = e.key.toString();
                                  items.add(mm);
                                }
                                items.sort((a, b) {
                                  final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                                  final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                                  return bt.compareTo(at);
                                });
                              }

                              if (items.isEmpty) return const SizedBox.shrink();

                              Future<void> accept(Map<String, dynamic> req) async {
                                final fromLogin = (req['fromLogin'] ?? '').toString();
                                if (fromLogin.trim().isEmpty) return;
                                try {
                                  await _acceptDmRequest(myUid: current.uid, otherLogin: fromLogin);
                                } catch (e) {
                                  if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba', 'Error')}: $e')),
                                            );
                                  }
                                }
                              }

                              Future<void> reject(Map<String, dynamic> req) async {
                                final fromLogin = (req['fromLogin'] ?? '').toString();
                                if (fromLogin.trim().isEmpty) return;
                                try {
                                  await _rejectDmRequest(myUid: current.uid, otherLogin: fromLogin);
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba', 'Error')}: $e')),
                                    );
                                  }
                                }
                              }

                              return Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.mail_lock_outlined),
                                    title: Text(AppLanguage.tr(context, 'Žádosti o chat', 'Chat requests')),
                                    subtitle: Text('${AppLanguage.tr(context, 'Čeká', 'Pending')}: ${items.length}'),
                                  ),
                                  ...items.map((req) {
                                    final fromLogin = (req['fromLogin'] ?? '').toString();
                                    final fromUid = (req['fromUid'] ?? '').toString();
                                    final fromAvatar = (req['fromAvatarUrl'] ?? '').toString();
                                    final hasEncryptedText = ((req['ciphertext'] ?? req['ct'] ?? req['cipher'])?.toString().isNotEmpty ?? false);
                                    return ListTile(
                                      leading: fromUid.isNotEmpty
                                          ? _AvatarWithPresenceDot(uid: fromUid, avatarUrl: fromAvatar, radius: 18)
                                          : CircleAvatar(
                                              radius: 18,
                                              backgroundImage: fromAvatar.isNotEmpty ? NetworkImage(fromAvatar) : null,
                                              child: fromAvatar.isEmpty ? const Icon(Icons.person, size: 18) : null,
                                            ),
                                      title: Text('@$fromLogin'),
                                        subtitle: hasEncryptedText
                                          ? Text(AppLanguage.tr(context, 'Zpráva: 🔒 (šifrovaně)', 'Message: 🔒 (encrypted)'))
                                          : Text(AppLanguage.tr(context, 'Invajt do privátu', 'Private chat invite')),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.close),
                                            onPressed: () => reject(req),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.check),
                                            onPressed: () => accept(req),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  const Divider(height: 1),
                                ],
                              );
                            },
                          ),

                          // Přepínače: Priváty / Skupiny / Složky
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ChoiceChip(
                                  label: Text(AppLanguage.tr(context, 'Priváty', 'Private')),
                                  selected: _overviewMode == 0,
                                  onSelected: (_) => setState(() {
                                    _overviewMode = 0;
                                    _activeFolderId = null;
                                  }),
                                ),
                                ChoiceChip(
                                  label: Text(AppLanguage.tr(context, 'Skupiny', 'Groups')),
                                  selected: _overviewMode == 1,
                                  onSelected: (_) => setState(() {
                                    _overviewMode = 1;
                                    _activeFolderId = null;
                                  }),
                                ),
                                ChoiceChip(
                                  label: Text(AppLanguage.tr(context, 'Složky', 'Folders')),
                                  selected: _overviewMode == 2,
                                  onSelected: (_) => setState(() {
                                    _overviewMode = 2;
                                    _activeFolderId = null;
                                  }),
                                ),
                              ],
                            ),
                          ),

                          if (isModerator) ...[
                            Padding(
                              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                                child: Text(AppLanguage.tr(context, 'Žádosti o ověření', 'Verification requests'), style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            if (pendingReqs.isEmpty)
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: Text(AppLanguage.tr(context, 'Žádné čekající žádosti.', 'No pending requests.')),
                              )
                            else
                              ...pendingReqs.map((r) {
                                final uid = (r['uid'] ?? '').toString();
                                final gh = (r['githubUsername'] ?? '').toString();
                                final reason = (r['reason'] ?? '').toString();
                                final avatar = (r['avatarUrl'] ?? '').toString();
                                return ListTile(
                                  leading: _AvatarWithPresenceDot(uid: uid, avatarUrl: avatar, radius: 20),
                                  title: Text('@$gh'),
                                  subtitle: Text(reason, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () {
                                    _hapticSelect();
                                    setState(() {
                                      _activeVerifiedUid = uid;
                                      _activeVerifiedGithub = gh;
                                      _moderatorAnonymous = true;
                                    });
                                  },
                                );
                              }),
                            const Divider(height: 1),
                          ],

                          if (_overviewMode == 0) ...[
                            if (rows.isEmpty)
                              Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Text(AppLanguage.tr(context, 'Zatím žádné chaty. Napiš někomu zprávu.', 'No chats yet. Send someone a message.')),
                              )
                            else
                              ...rows.map((r) {
                                final login = (r['login'] ?? '').toString();
                                final avatarUrl = (r['avatarUrl'] ?? '').toString();
                                final lastText = (r['lastText'] ?? '').toString();
                                final status = (r['status'] ?? 'accepted').toString();
                                return ListTile(
                                  leading: _ChatLoginAvatar(login: login, avatarUrl: avatarUrl, radius: 20),
                                  title: Row(
                                    children: [
                                      Expanded(child: Text('@$login')),
                                      if (status.startsWith('pending')) const Icon(Icons.lock_outline, size: 16),
                                    ],
                                  ),
                                  subtitle: lastText.isNotEmpty
                                      ? Text(lastText, maxLines: 1, overflow: TextOverflow.ellipsis)
                                      : null,
                                  onLongPress: () {
                                    _hapticMedium();
                                    _moveChatToFolder(myUid: current.uid, login: login);
                                  },
                                  onTap: () {
                                    _hapticSelect();
                                    setState(() {
                                      _activeLogin = login;
                                      _activeAvatarUrl = avatarUrl;
                                    });
                                  },
                                );
                              }),
                          ] else if (_overviewMode == 1) ...[
                            ListTile(
                              leading: const Icon(Icons.group_add),
                              title: Text(AppLanguage.tr(context, 'Vytvořit skupinu', 'Create group')),
                              onTap: () async {
                                _hapticSelect();
                                final created = await Navigator.of(context).push<String>(
                                  MaterialPageRoute(
                                    builder: (_) => _CreateGroupPage(myGithubUsername: myGithub),
                                  ),
                                );
                                if (!mounted) return;
                                if (created != null && created.isNotEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(AppLanguage.tr(context, 'Skupina vytvořena.', 'Group created.'))),
                                  );
                                }
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.qr_code_scanner),
                              title: Text(AppLanguage.tr(context, 'Připojit se přes link / QR', 'Join via link / QR')),
                              onTap: () async {
                                _hapticSelect();
                                final joined = await Navigator.of(context).push<String>(
                                  MaterialPageRoute(builder: (_) => const JoinGroupViaLinkQrPage()),
                                );
                                if (!mounted) return;
                                if (joined != null && joined.isNotEmpty) {
                                  setState(() {
                                    _activeGroupId = joined;
                                    _activeLogin = null;
                                    _activeVerifiedUid = null;
                                  });
                                }
                              },
                            ),
                            const Divider(height: 1),
                            StreamBuilder<DatabaseEvent>(
                              stream: userGroupsRef.onValue,
                              builder: (context, gSnap) {
                                final gv = gSnap.data?.snapshot.value;
                                final gmap = (gv is Map) ? gv : null;
                                final groupIds = <String>[];
                                if (gmap != null) {
                                  for (final e in gmap.entries) {
                                    if (e.value == true) groupIds.add(e.key.toString());
                                  }
                                }
                                if (groupIds.isEmpty) {
                                  return Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    child: Text(AppLanguage.tr(context, 'Zatím nejsi v žádné skupině.', 'You are not in any group yet.')),
                                  );
                                }

                                return Column(
                                  children: groupIds.map((gid) {
                                    final gref = groupsRef.child(gid);
                                    return StreamBuilder<DatabaseEvent>(
                                      stream: gref.onValue,
                                      builder: (context, meta) {
                                        final v = meta.data?.snapshot.value;
                                        final m = (v is Map) ? v : null;
                                        if (m == null) return const SizedBox.shrink();
                                        final title = (m['title'] ?? '').toString();
                                        final desc = (m['description'] ?? '').toString();
                                        final logo = (m['logoUrl'] ?? '').toString();
                                        return ListTile(
                                          leading: CircleAvatar(
                                            radius: 18,
                                            backgroundImage: logo.isNotEmpty ? NetworkImage(logo) : null,
                                            child: logo.isEmpty ? const Icon(Icons.group) : null,
                                          ),
                                          title: Text(title),
                                          subtitle: desc.isNotEmpty
                                              ? Text(desc, maxLines: 1, overflow: TextOverflow.ellipsis)
                                              : null,
                                          onTap: () {
                                            setState(() {
                                              _activeGroupId = gid;
                                              _activeLogin = null;
                                              _activeVerifiedUid = null;
                                            });
                                          },
                                        );
                                      },
                                    );
                                  }).toList(growable: false),
                                );
                              },
                            ),
                          ] else ...[
                            StreamBuilder<DatabaseEvent>(
                              stream: rtdb().ref('folders/${current.uid}').onValue,
                              builder: (context, fSnap) {
                                final fv = fSnap.data?.snapshot.value;
                                final fm = (fv is Map) ? fv : null;
                                final folders = <Map<String, dynamic>>[];
                                if (fm != null) {
                                  for (final e in fm.entries) {
                                    if (e.value is! Map) continue;
                                    final mm = Map<String, dynamic>.from(e.value as Map);
                                    final name = (mm['name'] ?? '').toString();
                                    if (name.trim().isEmpty) continue;
                                    folders.add({'id': e.key.toString(), 'name': name});
                                  }
                                  folders.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
                                }

                                return StreamBuilder<DatabaseEvent>(
                                  stream: rtdb().ref('chatFolders/${current.uid}').onValue,
                                  builder: (context, cfSnap) {
                                    final cv = cfSnap.data?.snapshot.value;
                                    final cfm = (cv is Map) ? cv : null;

                                    return StreamBuilder<DatabaseEvent>(
                                      stream: rtdb().ref('userGroups/${current.uid}').onValue,
                                      builder: (context, ugSnap) {
                                        final ugv = ugSnap.data?.snapshot.value;
                                        final ugm = (ugv is Map) ? ugv : null;
                                        final allGroupIds = <String>[];
                                        if (ugm != null) {
                                          for (final e in ugm.entries) {
                                            if (e.value == true) allGroupIds.add(e.key.toString());
                                          }
                                        }

                                        return StreamBuilder<DatabaseEvent>(
                                          stream: rtdb().ref('groupFolders/${current.uid}').onValue,
                                          builder: (context, gfSnap) {
                                            final gfv = gfSnap.data?.snapshot.value;
                                            final gfm = (gfv is Map) ? gfv : null;

                                            int countChatsForFolder(String? folderId) {
                                              var c = 0;
                                              for (final r in rows) {
                                                final login = (r['login'] ?? '').toString();
                                                final key = login.trim().toLowerCase();
                                                final mapped = cfm?[key]?.toString();
                                                if (folderId == null) {
                                                  if (mapped == null || mapped.isEmpty) c++;
                                                } else {
                                                  if (mapped == folderId) c++;
                                                }
                                              }
                                              return c;
                                            }

                                            int countGroupsForFolder(String? folderId) {
                                              if (folderId == null) return 0;
                                              var c = 0;
                                              for (final gid in allGroupIds) {
                                                final mapped = gfm?[gid]?.toString();
                                                if (mapped == folderId) c++;
                                              }
                                              return c;
                                            }

                                            Future<void> createFolder() async {
                                              final ctrl = TextEditingController();
                                              final name = await showDialog<String>(
                                                context: context,
                                                builder: (context) {
                                                  return AlertDialog(
                                                    title: Text(AppLanguage.tr(context, 'Nová složka', 'New folder')),
                                                    content: TextField(
                                                      controller: ctrl,
                                                      decoration: InputDecoration(labelText: AppLanguage.tr(context, 'Název', 'Name')),
                                                    ),
                                                    actions: [
                                                      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel'))),
                                                      FilledButton(
                                                        onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
                                                        child: Text(AppLanguage.tr(context, 'Vytvořit', 'Create')),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              );
                                              final n = (name ?? '').trim();
                                              if (n.isEmpty) return;
                                              final push = rtdb().ref('folders/${current.uid}').push();
                                              await push.set({'name': n, 'createdAt': ServerValue.timestamp});
                                            }

                                            Future<void> deleteFolder(String folderId, {required String folderName}) async {
                                              final ok = await showDialog<bool>(
                                                context: context,
                                                builder: (context) => AlertDialog(
                                                  title: Text(AppLanguage.tr(context, 'Smazat složku?', 'Delete folder?')),
                                                  content: Text(AppLanguage.tr(context, 'Složka "$folderName" se smaže a všechny položky se vrátí zpět do privátů/skupin.', 'Folder "$folderName" will be deleted and all items will be moved back to private chats/groups.')),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppLanguage.tr(context, 'Zrušit', 'Cancel'))),
                                                    FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(AppLanguage.tr(context, 'Smazat', 'Delete'))),
                                                  ],
                                                ),
                                              );
                                              if (ok != true) return;

                                              final updates = <String, Object?>{};
                                              updates['folders/${current.uid}/$folderId'] = null;

                                              if (cfm != null) {
                                                for (final e in cfm.entries) {
                                                  final key = e.key.toString();
                                                  final mapped = e.value?.toString();
                                                  if (mapped == folderId) {
                                                    updates['chatFolders/${current.uid}/$key'] = null;
                                                  }
                                                }
                                              }
                                              if (gfm != null) {
                                                for (final e in gfm.entries) {
                                                  final gid = e.key.toString();
                                                  final mapped = e.value?.toString();
                                                  if (mapped == folderId) {
                                                    updates['groupFolders/${current.uid}/$gid'] = null;
                                                  }
                                                }
                                              }

                                              await rtdb().ref().update(updates);
                                              if (mounted) {
                                                setState(() => _activeFolderId = null);
                                              }
                                            }

                                            Future<void> addToFolder(String folderId) async {
                                              final kind = await showModalBottomSheet<String>(
                                                context: context,
                                                builder: (context) {
                                                  return SafeArea(
                                                    child: ListView(
                                                      shrinkWrap: true,
                                                      children: [
                                                        ListTile(
                                                          leading: const Icon(Icons.person_add_alt_1),
                                                          title: Text(AppLanguage.tr(context, 'Přidat privát', 'Add private chat')),
                                                          onTap: () => Navigator.of(context).pop('chat'),
                                                        ),
                                                        ListTile(
                                                          leading: const Icon(Icons.group_add),
                                                          title: Text(AppLanguage.tr(context, 'Přidat skupinu', 'Add group')),
                                                          onTap: () => Navigator.of(context).pop('group'),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              );
                                              if (kind == null) return;

                                              if (kind == 'chat') {
                                                final candidates = rows.where((r) {
                                                  final login = (r['login'] ?? '').toString();
                                                  final key = login.trim().toLowerCase();
                                                  final mapped = cfm?[key]?.toString();
                                                  return mapped != folderId;
                                                }).toList(growable: false);

                                                final pickedLogin = await showModalBottomSheet<String>(
                                                  context: context,
                                                  isScrollControlled: true,
                                                  builder: (context) {
                                                    return SafeArea(
                                                      child: ListView(
                                                        shrinkWrap: true,
                                                        children: [
                                                          ListTile(
                                                            title: Text(AppLanguage.tr(context, 'Vyber privát', 'Select private chat'), style: const TextStyle(fontWeight: FontWeight.w700)),
                                                          ),
                                                          const Divider(height: 1),
                                                          ...candidates.map((r) {
                                                            final login = (r['login'] ?? '').toString();
                                                            final avatarUrl = (r['avatarUrl'] ?? '').toString();
                                                            return ListTile(
                                                              leading: _ChatLoginAvatar(login: login, avatarUrl: avatarUrl, radius: 18),
                                                              title: Text('@$login'),
                                                              onTap: () => Navigator.of(context).pop(login),
                                                            );
                                                          }),
                                                        ],
                                                      ),
                                                    );
                                                  },
                                                );
                                                if (pickedLogin == null || pickedLogin.isEmpty) return;
                                                final key = pickedLogin.trim().toLowerCase();
                                                await rtdb().ref('chatFolders/${current.uid}/$key').set(folderId);
                                              } else {
                                                final candidates = allGroupIds.where((gid) {
                                                  final mapped = gfm?[gid]?.toString();
                                                  return mapped != folderId;
                                                }).toList(growable: false);

                                                final pickedGid = await showModalBottomSheet<String>(
                                                  context: context,
                                                  isScrollControlled: true,
                                                  builder: (context) {
                                                    return SafeArea(
                                                      child: ListView(
                                                        shrinkWrap: true,
                                                        children: [
                                                          ListTile(
                                                            title: Text(AppLanguage.tr(context, 'Vyber skupinu', 'Select group'), style: const TextStyle(fontWeight: FontWeight.w700)),
                                                          ),
                                                          const Divider(height: 1),
                                                          ...candidates.map((gid) {
                                                            return StreamBuilder<DatabaseEvent>(
                                                              stream: rtdb().ref('groups/$gid').onValue,
                                                              builder: (context, snap) {
                                                                final v = snap.data?.snapshot.value;
                                                                final m = (v is Map) ? v : null;
                                                                if (m == null) return const SizedBox.shrink();
                                                                final title = (m['title'] ?? '').toString();
                                                                final logo = (m['logoUrl'] ?? '').toString();
                                                                return ListTile(
                                                                  leading: CircleAvatar(
                                                                    radius: 18,
                                                                    backgroundImage: logo.isNotEmpty ? NetworkImage(logo) : null,
                                                                    child: logo.isEmpty ? const Icon(Icons.group) : null,
                                                                  ),
                                                                  title: Text(title),
                                                                  subtitle: Text(gid, maxLines: 1, overflow: TextOverflow.ellipsis),
                                                                  onTap: () => Navigator.of(context).pop(gid),
                                                                );
                                                              },
                                                            );
                                                          }),
                                                        ],
                                                      ),
                                                    );
                                                  },
                                                );
                                                if (pickedGid == null || pickedGid.isEmpty) return;
                                                await rtdb().ref('groupFolders/${current.uid}/$pickedGid').set(folderId);
                                              }
                                            }

                                            Widget buildFolderView(String fid) {
                                              final folderName = (fid == '__privates__')
                                                    ? AppLanguage.tr(context, 'Priváty', 'Private')
                                                  : (folders.firstWhere(
                                                          (e) => e['id'] == fid,
                                                      orElse: () => {'name': AppLanguage.tr(context, 'Složka', 'Folder')},
                                                        )['name'] as String);

                                              final filteredChats = rows.where((r) {
                                                final login = (r['login'] ?? '').toString();
                                                final key = login.trim().toLowerCase();
                                                final mapped = cfm?[key]?.toString();
                                                if (fid == '__privates__') {
                                                  return mapped == null || mapped.isEmpty;
                                                }
                                                return mapped == fid;
                                              }).toList(growable: false);

                                              final filteredGroups = (fid == '__privates__')
                                                  ? const <String>[]
                                                  : allGroupIds.where((gid) => (gfm?[gid]?.toString() == fid)).toList(growable: false);

                                              return Column(
                                                key: ValueKey('folder:$fid'),
                                                children: [
                                                  ListTile(
                                                    leading: IconButton(
                                                      icon: const Icon(Icons.arrow_back),
                                                      onPressed: () {
                                                        _hapticSelect();
                                                        setState(() => _activeFolderId = null);
                                                      },
                                                    ),
                                                    title: Text(folderName),
                                                    subtitle: Text(
                                                      fid == '__privates__'
                                                              ? '${AppLanguage.tr(context, 'Chaty', 'Chats')}: ${filteredChats.length}'
                                                              : '${AppLanguage.tr(context, 'Chaty', 'Chats')}: ${filteredChats.length} • ${AppLanguage.tr(context, 'Skupiny', 'Groups')}: ${filteredGroups.length}',
                                                    ),
                                                    trailing: (fid == '__privates__')
                                                        ? null
                                                        : Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              IconButton(
                                                                tooltip: AppLanguage.tr(context, 'Přidat', 'Add'),
                                                                icon: const Icon(Icons.add),
                                                                onPressed: () {
                                                                  _hapticSelect();
                                                                  addToFolder(fid);
                                                                },
                                                              ),
                                                              IconButton(
                                                                tooltip: AppLanguage.tr(context, 'Smazat složku', 'Delete folder'),
                                                                icon: const Icon(Icons.delete_outline),
                                                                onPressed: () {
                                                                  _hapticMedium();
                                                                  deleteFolder(fid, folderName: folderName);
                                                                },
                                                              ),
                                                            ],
                                                          ),
                                                  ),
                                                  const Divider(height: 1),

                                                  if (filteredChats.isEmpty && filteredGroups.isEmpty)
                                                    Padding(
                                                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                      child: Text(AppLanguage.tr(context, 'Ve složce zatím nic není.', 'Folder is empty.')),
                                                    ),

                                                  ...filteredChats.map((r) {
                                                    final login = (r['login'] ?? '').toString();
                                                    final avatarUrl = (r['avatarUrl'] ?? '').toString();
                                                    final lastText = (r['lastText'] ?? '').toString();
                                                    return ListTile(
                                                      leading: _ChatLoginAvatar(login: login, avatarUrl: avatarUrl, radius: 20),
                                                      title: Text('@$login'),
                                                      subtitle: lastText.isNotEmpty
                                                          ? Text(lastText, maxLines: 1, overflow: TextOverflow.ellipsis)
                                                          : null,
                                                      onLongPress: () {
                                                        _hapticMedium();
                                                        _moveChatToFolder(myUid: current.uid, login: login);
                                                      },
                                                      onTap: () {
                                                        _hapticSelect();
                                                        setState(() {
                                                          _activeLogin = login;
                                                          _activeAvatarUrl = avatarUrl;
                                                        });
                                                      },
                                                    );
                                                  }),

                                                  if (filteredGroups.isNotEmpty) ...[
                                                    const Divider(height: 1),
                                                    Padding(
                                                      padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                                                      child: Align(
                                                        alignment: Alignment.centerLeft,
                                                        child: Text(AppLanguage.tr(context, 'Skupiny', 'Groups'), style: const TextStyle(fontWeight: FontWeight.w700)),
                                                      ),
                                                    ),
                                                    ...filteredGroups.map((gid) {
                                                      return StreamBuilder<DatabaseEvent>(
                                                        stream: rtdb().ref('groups/$gid').onValue,
                                                        builder: (context, snap) {
                                                          final v = snap.data?.snapshot.value;
                                                          final m = (v is Map) ? v : null;
                                                          if (m == null) return const SizedBox.shrink();
                                                          final title = (m['title'] ?? '').toString();
                                                          final logo = (m['logoUrl'] ?? '').toString();
                                                          final desc = (m['description'] ?? '').toString();
                                                          return ListTile(
                                                            leading: CircleAvatar(
                                                              radius: 18,
                                                              backgroundImage: logo.isNotEmpty ? NetworkImage(logo) : null,
                                                              child: logo.isEmpty ? const Icon(Icons.group) : null,
                                                            ),
                                                            title: Text(title),
                                                            subtitle: desc.isNotEmpty
                                                                ? Text(desc, maxLines: 1, overflow: TextOverflow.ellipsis)
                                                                : null,
                                                            onTap: () {
                                                              _hapticSelect();
                                                              setState(() {
                                                                _activeGroupId = gid;
                                                                _activeLogin = null;
                                                                _activeVerifiedUid = null;
                                                              });
                                                            },
                                                          );
                                                        },
                                                      );
                                                    }),
                                                  ],
                                                ],
                                              );
                                            }

                                            Widget buildFolderList() {
                                              return Column(
                                                key: const ValueKey('folders:list'),
                                                children: [
                                                  ListTile(
                                                    leading: const Icon(Icons.create_new_folder_outlined),
                                                    title: Text(AppLanguage.tr(context, 'Vytvořit složku', 'Create folder')),
                                                    onTap: () {
                                                      _hapticSelect();
                                                      createFolder();
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(Icons.inbox_outlined),
                                                    title: Text(AppLanguage.tr(context, 'Priváty', 'Private')),
                                                    subtitle: Text('${AppLanguage.tr(context, 'Chaty', 'Chats')}: ${countChatsForFolder(null)}'),
                                                    onTap: () {
                                                      _hapticSelect();
                                                      setState(() => _activeFolderId = '__privates__');
                                                    },
                                                  ),
                                                  const Divider(height: 1),
                                                  if (folders.isEmpty)
                                                    Padding(
                                                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                      child: Text(AppLanguage.tr(context, 'Zatím nemáš žádné složky.', 'You have no folders yet.')),
                                                    )
                                                  else
                                                    ...folders.map((f) {
                                                      final fid = (f['id'] ?? '').toString();
                                                      final name = (f['name'] ?? AppLanguage.tr(context, 'Složka', 'Folder')).toString();
                                                      return ListTile(
                                                        leading: const Icon(Icons.folder_outlined),
                                                        title: Text(name),
                                                        subtitle: Text('${AppLanguage.tr(context, 'Chaty', 'Chats')}: ${countChatsForFolder(fid)} • ${AppLanguage.tr(context, 'Skupiny', 'Groups')}: ${countGroupsForFolder(fid)}'),
                                                        trailing: IconButton(
                                                          icon: const Icon(Icons.delete_outline),
                                                          onPressed: () {
                                                            _hapticMedium();
                                                            deleteFolder(fid, folderName: name);
                                                          },
                                                        ),
                                                        onTap: () {
                                                          _hapticSelect();
                                                          setState(() => _activeFolderId = fid);
                                                        },
                                                      );
                                                    }),
                                                ],
                                              );
                                            }

                                            final body = (_activeFolderId != null)
                                                ? buildFolderView(_activeFolderId!)
                                                : buildFolderList();

                                            return AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 220),
                                              switchInCurve: Curves.easeOut,
                                              switchOutCurve: Curves.easeIn,
                                              transitionBuilder: (child, anim) {
                                                return SizeTransition(
                                                  sizeFactor: anim,
                                                  axisAlignment: -1,
                                                  child: FadeTransition(opacity: anim, child: child),
                                                );
                                              },
                                              child: body,
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ],
                      );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      );
    }

    // Verified chat view
    if (_activeVerifiedUid != null) {
      final requestUid = _activeVerifiedUid!;
      final reqRef = _verifiedRequestRef(requestUid);
      final msgsRef = _verifiedMessagesRef(requestUid);

      return StreamBuilder<DatabaseEvent>(
        stream: currentUserRef.onValue,
        builder: (context, userSnap) {
          final uval = userSnap.data?.snapshot.value;
          final umap = (uval is Map) ? uval : null;
          final myGithub = umap?['githubUsername']?.toString() ?? '';
          final isModerator = _isModeratorFromUserMap(umap);

          return StreamBuilder<DatabaseEvent>(
            stream: reqRef.onValue,
            builder: (context, reqSnap) {
              final rv = reqSnap.data?.snapshot.value;
              final req = (rv is Map) ? rv : null;
              final status = req?['status']?.toString();
              final requesterGh = (req?['githubUsername'] ?? _activeVerifiedGithub ?? '').toString();

              return Column(
                children: [
                  ListTile(
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() {
                        _activeVerifiedUid = null;
                        _activeVerifiedGithub = null;
                      }),
                    ),
                    title: Text(isModerator ? 'Žádost: @$requesterGh' : 'Ověření účtu'),
                    subtitle: Text(_statusText(context, status)),
                  ),
                  const Divider(height: 1),

                  if (isModerator) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(context).colorScheme.secondary,
                                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                              ),
                              onPressed: status == 'approved'
                                  ? null
                                  : () async {
                                      await _setVerifiedStatus(
                                        requestUid: requestUid,
                                        status: 'approved',
                                        setUserVerified: true,
                                        moderatorUid: current.uid,
                                        moderatorGithub: myGithub,
                                      );
                                      await _sendVerifiedMessage(
                                        requestUid: requestUid,
                                        from: 'system',
                                        text: 'Ověření bylo schváleno.',
                                        important: true,
                                        anonymous: true,
                                        moderatorGithub: myGithub,
                                        markNewForRequester: true,
                                      );
                                    },
                              child: Text(AppLanguage.tr(context, 'Schválit', 'Accept')),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Theme.of(context).colorScheme.onError,
                                side: BorderSide(color: Theme.of(context).colorScheme.error),
                              ),
                              onPressed: status == 'declined'
                                  ? null
                                  : () async {
                                      await _setVerifiedStatus(
                                        requestUid: requestUid,
                                        status: 'declined',
                                        setUserVerified: false,
                                        moderatorUid: current.uid,
                                        moderatorGithub: myGithub,
                                      );
                                      await _sendVerifiedMessage(
                                        requestUid: requestUid,
                                        from: 'system',
                                        text: 'Ověření bylo zamítnuto.',
                                        important: true,
                                        anonymous: true,
                                        moderatorGithub: myGithub,
                                        markNewForRequester: true,
                                      );
                                    },
                              child: Text(AppLanguage.tr(context, 'Odmítnout', 'Decline')),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile(
                      value: _moderatorAnonymous,
                      onChanged: (v) => setState(() => _moderatorAnonymous = v),
                      title: Text(AppLanguage.tr(context, 'Odpovídat anonymně', 'Reply anonymously')),
                      subtitle: Text(
                        _moderatorAnonymous
                            ? AppLanguage.tr(context, 'U druhé strany bude „Moderátor"', 'The other side will see “Moderator”')
                            : '${AppLanguage.tr(context, 'U druhé strany bude', 'The other side will see')} @$myGithub',
                      ),
                    ),
                    const Divider(height: 1),
                  ],

                  Expanded(
                    child: StreamBuilder<DatabaseEvent>(
                      stream: msgsRef.onValue,
                      builder: (context, msgSnap) {
                        final value = msgSnap.data?.snapshot.value;
                        if (value is! Map) {
                          return Center(child: Text(AppLanguage.tr(context, 'Zatím žádné zprávy.', 'No messages yet.')));
                        }

                        final items = value.entries
                            .where((e) => e.value is Map)
                            .map((e) => Map<String, dynamic>.from(e.value as Map))
                            .toList();

                        items.sort((a, b) {
                          final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                          final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                          return at.compareTo(bt);
                        });

                        return ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final m = items[i];
                            final text = (m['text'] ?? '').toString();
                            final from = (m['from'] ?? '').toString();
                            final important = m['important'] == true;
                            final anonymous = m['anonymous'] == true;
                            final moderatorGithub = (m['moderatorGithub'] ?? myGithub).toString();

                            final isMine = (!isModerator && from == 'user') || (isModerator && from == 'moderator');
                            final bubbleColor = important ? Colors.orange.withOpacity(0.25) : Theme.of(context).colorScheme.surface;
                            final label = from == 'system'
                                ? AppLanguage.tr(context, 'Systém', 'System')
                                : (from == 'moderator'
                                  ? (anonymous ? AppLanguage.tr(context, 'Moderátor', 'Moderator') : '@$moderatorGithub')
                                    : '@$requesterGh');

                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Align(
                                alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: bubbleColor,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(text),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            decoration: InputDecoration(labelText: AppLanguage.tr(context, 'Zpráva', 'Message')),
                            onSubmitted: (_) => _sendVerified(asModerator: isModerator, moderatorGithub: myGithub),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: () => _sendVerified(asModerator: isModerator, moderatorGithub: myGithub),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    }

    // Group chat view
    if (_activeGroupId != null) {
      final groupId = _activeGroupId!;
      final groupRef = rtdb().ref('groups/$groupId');
      final memberRef = rtdb().ref('groupMembers/$groupId/${current.uid}');
      final msgsRef = rtdb().ref('groupMessages/$groupId');

      return StreamBuilder<DatabaseEvent>(
        stream: currentUserRef.onValue,
        builder: (context, userSnap) {
          final uv = userSnap.data?.snapshot.value;
          final um = (uv is Map) ? uv : null;
          final myGithub = (um?['githubUsername'] ?? '').toString();
          final myGithubLower = myGithub.toLowerCase();

          return StreamBuilder<DatabaseEvent>(
            stream: memberRef.onValue,
            builder: (context, memSnap) {
              final mv = memSnap.data?.snapshot.value;
              final mm = (mv is Map) ? mv : null;
              final role = (mm?['role'] ?? 'member').toString();
              final isAdmin = role == 'admin';

              return StreamBuilder<DatabaseEvent>(
                stream: groupRef.onValue,
                builder: (context, gSnap) {
                  final gv = gSnap.data?.snapshot.value;
                  final gm = (gv is Map) ? gv : null;
                  if (gm == null) return const SizedBox.shrink();
                  final title = (gm['title'] ?? '').toString();
                  final perms = (gm['permissions'] is Map) ? (gm['permissions'] as Map) : null;
                  final canSend = (perms?['sendMessages'] != false) || isAdmin;

                  String ttlLabel(int v) {
                    return switch (v) {
                      0 => 'Podle nastavení',
                      1 => 'Nikdy',
                      2 => '1 minuta',
                      3 => '1 hodina',
                      4 => '1 den',
                      5 => 'Po přečtení',
                      _ => 'Podle nastavení',
                    };
                  }

                  Future<void> deleteMessage(String key) async {
                    await msgsRef.child(key).remove();
                  }

                  Future<void> send() async {
                    final text = _messageController.text.trim();
                    if (text.isEmpty || !canSend) return;

                    final pendingCode = _pendingCodePayload;
                    final isPendingCodeText = pendingCode != null && text.startsWith('<> kód');
                    final replyToKey = _replyToKey;
                    final replyToFrom = _replyToFrom;
                    final replyToPreview = _replyToPreview;

                    String outgoingText;
                    if (isPendingCodeText) {
                      outgoingText = jsonEncode(pendingCode.toJson());
                    } else {
                      outgoingText = text;
                    }

                    if (replyToFrom != null && replyToFrom.trim().isNotEmpty && !outgoingText.trim().startsWith('@')) {
                      final cleanFrom = replyToFrom.trim().replaceFirst(RegExp(r'^@+'), '');
                      outgoingText = '@$cleanFrom $outgoingText';
                    }

                    _messageController.clear();
                    _typingTimeout?.cancel();
                    _setGroupTyping(groupId: groupId, value: false, myGithub: myGithub);

                    final nowMs = DateTime.now().millisecondsSinceEpoch;
                    final burnAfterRead = _dmTtlMode == 5;
                    final ttlSeconds = switch (_dmTtlMode) {
                      0 => widget.settings.autoDeleteSeconds,
                      1 => 0,
                      2 => 60,
                      3 => 60 * 60,
                      4 => 60 * 60 * 24,
                      _ => widget.settings.autoDeleteSeconds,
                    };
                    final expiresAt = (!burnAfterRead && ttlSeconds > 0) ? (nowMs + (ttlSeconds * 1000)) : null;

                    try {
                      await E2ee.publishMyPublicKey(uid: current.uid);
                    } catch (_) {}

                    Map<String, Object?>? encrypted;
                    try {
                      encrypted = await E2ee.encryptForGroupSignalLike(groupId: groupId, myUid: current.uid, plaintext: outgoingText);
                    } catch (_) {
                      encrypted = null;
                    }

                    if (encrypted == null) {
                      // Fallback to legacy v1 group shared key.
                      SecretKey? gk = _groupKeyCache[groupId];
                      gk ??= await E2ee.fetchGroupKey(groupId: groupId, myUid: current.uid);

                      if (gk == null) {
                        if (!isAdmin) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(AppLanguage.tr(context, 'E2EE: skupina není připravená (chybí klíč).', 'E2EE: group is not ready (missing key).'))),
                            );
                          }
                          return;
                        }
                        try {
                          await E2ee.ensureGroupKeyDistributed(groupId: groupId, myUid: current.uid);
                          gk = await E2ee.fetchGroupKey(groupId: groupId, myUid: current.uid);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('${AppLanguage.tr(context, 'E2EE: nelze nastavit skupinový klíč', 'E2EE: failed to set group key')}: $e')),
                            );
                          }
                          return;
                        }
                      }

                      if (gk == null) return;
                      _groupKeyCache[groupId] = gk;

                      try {
                        encrypted = await E2ee.encryptForGroup(groupKey: gk, plaintext: outgoingText);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('${AppLanguage.tr(context, 'E2EE: šifrování selhalo', 'E2EE: encryption failed')}: $e')),
                          );
                        }
                        return;
                      }
                    }

                    final newRef = msgsRef.push();
                    final newKey = newRef.key;
                    await newRef.set({
                      ...encrypted,
                      'fromUid': current.uid,
                      'fromGithub': myGithub,
                      'createdAt': ServerValue.timestamp,
                      if (replyToKey != null && replyToKey.trim().isNotEmpty) 'replyToKey': replyToKey,
                      if (replyToFrom != null && replyToFrom.trim().isNotEmpty) 'replyToFrom': replyToFrom,
                      if (replyToPreview != null && replyToPreview.trim().isNotEmpty) 'replyToPreview': replyToPreview,
                      if (expiresAt != null) 'expiresAt': expiresAt,
                      if (burnAfterRead) 'burnAfterRead': true,
                    });

                    // Show our own message immediately (avoid "🔒 …" placeholder).
                    if (newKey != null && newKey.isNotEmpty && mounted) {
                      setState(() {
                        _decryptedCache['g:$groupId:$newKey'] = outgoingText;
                        _pendingCodePayload = null;
                      });
                      PlaintextCache.putGroup(groupId: groupId, messageKey: newKey, plaintext: outgoingText);
                    }
                    _clearReplyTarget();
                    if (widget.settings.vibrationEnabled) {
                      HapticFeedback.lightImpact();
                    }
                    if (widget.settings.soundsEnabled) {
                      SystemSound.play(SystemSoundType.click);
                    }
                  }

                  return Column(
                    children: [
                      ListTile(
                        leading: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => setState(() => _activeGroupId = null),
                        ),
                        title: Text(title),
                        subtitle: Text(isAdmin ? AppLanguage.tr(context, 'Admin', 'Admin') : AppLanguage.tr(context, 'Člen', 'Member')),
                        trailing: const Icon(Icons.info_outline),
                        onTap: () async {
                          final res = await Navigator.of(context).push<String>(
                            MaterialPageRoute(builder: (_) => _GroupInfoPage(groupId: groupId)),
                          );
                          if (!mounted) return;
                          if (res == 'left' || res == 'deleted') {
                            setState(() => _activeGroupId = null);
                          }
                        },
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: StreamBuilder<DatabaseEvent>(
                          stream: msgsRef.onValue,
                          builder: (context, msgSnap) {
                            final v = msgSnap.data?.snapshot.value;
                            if (v is! Map) {
                              return Center(child: Text(AppLanguage.tr(context, 'Zatím žádné zprávy.', 'No messages yet.')));
                            }
                            final now = DateTime.now().millisecondsSinceEpoch;
                            final items = <Map<String, dynamic>>[];
                            for (final e in v.entries) {
                              if (e.value is! Map) continue;
                              final m = Map<String, dynamic>.from(e.value as Map);
                              m['__key'] = e.key.toString();
                              final expiresAt = (m['expiresAt'] is int) ? m['expiresAt'] as int : null;
                              final deletedFor = (m['deletedFor'] is Map) ? (m['deletedFor'] as Map) : null;
                              if (deletedFor?.containsKey(current.uid) == true) {
                                continue;
                              }
                              if (expiresAt != null && expiresAt <= now) {
                                final k = (m['__key'] ?? '').toString();
                                final delKey = 'g:$groupId:$k';
                                if (k.isNotEmpty && !_ttlDeleting.contains(delKey)) {
                                  _ttlDeleting.add(delKey);
                                  () async {
                                    try {
                                      await msgsRef.child(k).remove();
                                    } catch (_) {
                                      // ignore
                                    } finally {
                                      _ttlDeleting.remove(delKey);
                                    }
                                  }();
                                }
                                continue;
                              }
                              items.add(m);
                            }
                            items.sort((a, b) {
                              final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                              final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                              return at.compareTo(bt);
                            });

                            // Best-effort migration: encrypt old plaintext group messages.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              for (final msg in items.take(30)) {
                                final k = (msg['__key'] ?? '').toString();
                                if (k.isEmpty) continue;
                                if (_migrating.contains('g:$groupId:$k')) continue;
                                final pt = (msg['text'] ?? '').toString();
                                final hasC = ((msg['ciphertext'] ?? msg['ct'] ?? msg['cipher'])?.toString().isNotEmpty ?? false);
                                if (pt.isEmpty || hasC) continue;

                                _migrating.add('g:$groupId:$k');
                                () async {
                                  try {
                                    SecretKey? gk = _groupKeyCache[groupId];
                                    gk ??= await E2ee.fetchGroupKey(groupId: groupId, myUid: current.uid);
                                    if (gk == null) return;
                                    _groupKeyCache[groupId] = gk;
                                    final enc = await E2ee.encryptForGroup(groupKey: gk, plaintext: pt);
                                    await msgsRef.child(k).update({
                                      ...enc,
                                      'text': null,
                                    });
                                    if (!mounted) return;
                                    setState(() => _decryptedCache['g:$groupId:$k'] = pt);
                                    PlaintextCache.putGroup(groupId: groupId, messageKey: k, plaintext: pt);
                                  } catch (_) {
                                    // ignore
                                  } finally {
                                    _migrating.remove('g:$groupId:$k');
                                  }
                                }();
                              }
                            });

                            // Background warm-up: decrypt & persist ciphertext messages.
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _warmupGroupDecryptAll(items: items, groupId: groupId, myUid: current.uid);
                            });

                            return ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: items.length,
                              itemBuilder: (context, i) {
                                final m = items[i];
                                final key = (m['__key'] ?? '').toString();
                                final plaintext = (m['text'] ?? '').toString();
                                final fromUid = (m['fromUid'] ?? '').toString();
                                final fromGh = (m['fromGithub'] ?? '').toString();
                                final isMe = fromUid == current.uid;
                                final burnAfterRead = m['burnAfterRead'] == true;
                                final createdAt = (m['createdAt'] is int) ? m['createdAt'] as int : null;
                                final timeLabel = _formatShortTime(createdAt);

                                final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
                                final cacheKey = 'g:$groupId:$key';
                                String text = plaintext;
                                if (text.isEmpty && hasCipher) {
                                  final persisted = PlaintextCache.tryGetGroup(groupId: groupId, messageKey: key);
                                  if (persisted != null && persisted.isNotEmpty) {
                                    text = persisted;
                                    _decryptedCache[cacheKey] ??= persisted;
                                  } else {
                                    text = _decryptedCache[cacheKey] ?? '🔒 …';
                                  }

                                  if (persisted == null && _decryptedCache[cacheKey] == null && !_decrypting.contains(cacheKey)) {
                                    _decrypting.add(cacheKey);
                                    () async {
                                      try {
                                        SecretKey? gk = _groupKeyCache[groupId];
                                        gk ??= await E2ee.fetchGroupKey(groupId: groupId, myUid: current.uid);
                                        if (gk != null) _groupKeyCache[groupId] = gk;
                                        final plain = await E2ee.decryptGroupMessage(groupId: groupId, myUid: current.uid, groupKey: gk, message: m);
                                        if (!mounted) return;
                                        setState(() => _decryptedCache[cacheKey] = plain);
                                        PlaintextCache.putGroup(groupId: groupId, messageKey: key, plaintext: plain);

                                        if (burnAfterRead && !isMe) {
                                          final delKey = 'g:$groupId:$key';
                                          if (key.isNotEmpty && !_ttlDeleting.contains(delKey)) {
                                            _ttlDeleting.add(delKey);
                                            () async {
                                              try {
                                                await msgsRef.child(key).remove();
                                              } catch (_) {
                                                // ignore
                                              } finally {
                                                _ttlDeleting.remove(delKey);
                                              }
                                            }();
                                          }
                                        }
                                      } catch (_) {
                                        // keep placeholder
                                      } finally {
                                        _decrypting.remove(cacheKey);
                                      }
                                    }();
                                  }
                                }

                                if (burnAfterRead && !isMe && text.isNotEmpty && !hasCipher) {
                                  // Old plaintext message: treat first render as "read".
                                  final delKey = 'g:$groupId:$key';
                                  if (key.isNotEmpty && !_ttlDeleting.contains(delKey)) {
                                    _ttlDeleting.add(delKey);
                                    () async {
                                      try {
                                        await msgsRef.child(key).remove();
                                      } catch (_) {
                                        // ignore
                                      } finally {
                                        _ttlDeleting.remove(delKey);
                                      }
                                    }();
                                  }
                                }

                                final attachment = _AttachmentPayload.tryParse(text);
                                final isAttachment = attachment != null;
                                final codePayload = _CodeMessagePayload.tryParse(text);
                                final isCode = codePayload != null;
                                if (attachment != null) {
                                  if (!_attachmentCache.containsKey(cacheKey)) {
                                    _ensureAttachmentCached(cacheKey: cacheKey, payload: attachment);
                                  }
                                }

                                final mentioned = !isAttachment && !isCode && myGithubLower.isNotEmpty && text.toLowerCase().contains('@$myGithubLower');

                                final replyToFrom = (m['replyToFrom'] ?? '').toString().trim();
                                final replyToPreview = (m['replyToPreview'] ?? '').toString().trim();
                                final hasReply = replyToFrom.isNotEmpty && replyToPreview.isNotEmpty;

                                final reactions = (m['reactions'] is Map) ? (m['reactions'] as Map) : null;
                                final reactionChips = <Widget>[];
                                if (reactions != null) {
                                  for (final re in reactions.entries) {
                                    final emoji = re.key.toString();
                                    final voters = (re.value is Map) ? (re.value as Map) : null;
                                    final count = voters?.length ?? 0;
                                    if (count > 0) {
                                      reactionChips.add(
                                        Container(
                                          margin: const EdgeInsets.only(top: 4, right: 6),
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.surface,
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Text('$emoji $count', style: TextStyle(fontSize: widget.settings.chatTextSize - 4)),
                                        ),
                                      );
                                    }
                                  }
                                }

                                final bubbleKey = isMe ? widget.settings.bubbleOutgoing : widget.settings.bubbleIncoming;
                                final color = _bubbleColor(context, bubbleKey);
                                final tcolor = _bubbleTextColor(context, bubbleKey);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onLongPress: () => _showMessageActions(
                                      isGroup: true,
                                      chatTarget: groupId,
                                      messageKey: key,
                                      fromLabel: fromGh.isNotEmpty ? fromGh : (isMe ? myGithub : 'user'),
                                      text: text,
                                      canDeleteForMe: true,
                                      canDeleteForAll: isAdmin || isMe,
                                      onDeleteForMe: () => msgsRef.child(key).child('deletedFor').child(current.uid).set(true),
                                      onDeleteForAll: () => deleteMessage(key),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                      children: [
                                        if (fromGh.isNotEmpty)
                                          Text('@$fromGh', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                        Align(
                                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                            decoration: BoxDecoration(
                                              color: color,
                                              borderRadius: BorderRadius.circular(widget.settings.bubbleRadius),
                                              border: mentioned ? Border.all(color: Colors.amber, width: 2) : null,
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                if (hasReply)
                                                  Container(
                                                    margin: const EdgeInsets.only(bottom: 8),
                                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black26,
                                                      borderRadius: BorderRadius.circular(8),
                                                      border: Border.all(color: Colors.white24),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        const Icon(Icons.subdirectory_arrow_right, size: 14, color: Colors.white70),
                                                        const SizedBox(width: 6),
                                                        Flexible(
                                                          child: Text(
                                                            '@$replyToFrom • $replyToPreview',
                                                            maxLines: 2,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(fontSize: widget.settings.chatTextSize - 2, color: Colors.white70),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                if (attachment != null)
                                                  _attachmentBubble(
                                                    payload: attachment,
                                                    cacheKey: cacheKey,
                                                    maxWidth: MediaQuery.of(context).size.width * 0.62,
                                                    radius: widget.settings.bubbleRadius,
                                                  )
                                                else if (codePayload != null)
                                                  InkWell(
                                                    onTap: () => _openCodeSnippetSheet(codePayload),
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white10,
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(color: Colors.white24),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          const Icon(Icons.code, size: 16),
                                                          const SizedBox(width: 8),
                                                          Flexible(
                                                            child: Text(
                                                              codePayload.previewLabel(),
                                                              maxLines: 2,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: TextStyle(fontSize: widget.settings.chatTextSize, color: tcolor),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  )
                                                else
                                                  _RichMessageText(
                                                    text: text,
                                                    fontSize: widget.settings.chatTextSize,
                                                    textColor: tcolor,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (reactionChips.isNotEmpty)
                                          Wrap(
                                            alignment: WrapAlignment.end,
                                            children: reactionChips,
                                          ),
                                        if (timeLabel.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              timeLabel,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      StreamBuilder<DatabaseEvent>(
                        stream: rtdb().ref('typingGroups/$groupId').onValue,
                        builder: (context, tSnap) {
                          final tval = tSnap.data?.snapshot.value;
                          final tmap = (tval is Map) ? tval : null;
                          if (tmap == null || tmap.isEmpty) return const SizedBox.shrink();
                          final names = <String>[];
                          for (final entry in tmap.entries) {
                            final uid = entry.key.toString();
                            if (uid == current.uid) continue;
                            final val = entry.value;
                            if (val is Map) {
                              final gh = (val['github'] ?? '').toString();
                              if (gh.isNotEmpty) {
                                names.add('@$gh');
                              } else {
                                names.add(uid);
                              }
                            }
                          }
                          if (names.isEmpty) return const SizedBox.shrink();
                          final label = names.length == 1
                              ? '${AppLanguage.tr(context, 'Píše', 'Typing')} ${names.first}'
                            : '${AppLanguage.tr(context, 'Píší', 'Typing')} ${names.take(3).join(', ')}${names.length > 3 ? '…' : ''}';
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _typingPill(),
                                  const SizedBox(width: 8),
                                  Text(
                                    label,
                                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      if (_replyToPreview != null && _replyToPreview!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.subdirectory_arrow_right, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '@${_replyToFrom ?? ''} • ${_replyToPreview ?? ''}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: _clearReplyTarget,
                                  tooltip: AppLanguage.tr(context, 'Zrušit odpověď', 'Cancel reply'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _messageController,
                                decoration: InputDecoration(labelText: AppLanguage.tr(context, 'Zpráva / Markdown', 'Message / Markdown')),
                                enabled: canSend,
                                minLines: 1,
                                maxLines: 6,
                                onSubmitted: (_) => send(),
                                onChanged: canSend
                                    ? (text) {
                                        if (_pendingCodePayload != null && !text.trim().startsWith('<> kód')) {
                                          setState(() => _pendingCodePayload = null);
                                        }
                                        _onGroupTypingChanged(
                                          groupId: groupId,
                                          text: text,
                                          myGithub: myGithub,
                                        );
                                      }
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<String>(
                              tooltip: AppLanguage.tr(context, 'Více', 'More'),
                              enabled: canSend,
                              onSelected: (value) async {
                                if (value == 'image') {
                                  await _sendImageGroup(
                                    groupId: groupId,
                                    current: current,
                                    myGithub: myGithub,
                                    canSend: canSend,
                                  );
                                  return;
                                }
                                if (value == 'code') {
                                  await _insertCodeBlockTemplate();
                                  return;
                                }
                                if (value.startsWith('ttl:')) {
                                  final ttl = int.tryParse(value.split(':').last);
                                  if (ttl != null) {
                                    setState(() => _dmTtlMode = ttl);
                                  }
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem<String>(
                                  value: 'image',
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.image_outlined),
                                    title: Text(AppLanguage.tr(context, 'Poslat obrázek', 'Send image')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'code',
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.code),
                                    title: Text(AppLanguage.tr(context, 'Vložit kód', 'Insert code')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const PopupMenuDivider(),
                                for (final ttl in const [0, 1, 2, 3, 4, 5])
                                  PopupMenuItem<String>(
                                    value: 'ttl:$ttl',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(
                                        _dmTtlMode == ttl ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                      ),
                                      title: Text('${AppLanguage.tr(context, 'Ničení', 'TTL')}: ${ttlLabel(ttl)}'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                              ],
                              icon: const Icon(Icons.more_vert),
                            ),
                            IconButton(
                              icon: const Icon(Icons.send),
                              onPressed: canSend ? send : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      );
    }

    final login = _activeLogin!;
    final messagesRef = rtdb().ref('messages/${current.uid}/$login');
    final loginLower = login.trim().toLowerCase();
    if (_activeOtherUidLoginLower != loginLower) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureActiveOtherUid();
      });
    }
    final blockedRef = rtdb().ref('blocked/${current.uid}/$loginLower');
    final dmContactRef = _dmContactRef(myUid: current.uid, otherLoginLower: loginLower);

    final bg = widget.settings.wallpaperUrl.trim();
    Color? bgColor;
    if (bg.isNotEmpty) {
      switch (bg) {
        case 'graphite':
          bgColor = const Color(0xFF1B1F1D);
          break;
        case 'teal':
          bgColor = const Color(0xFF1A2B2C);
          break;
        case 'pine':
          bgColor = const Color(0xFF1C2A24);
          break;
        case 'sand':
          bgColor = const Color(0xFF2B241C);
          break;
        case 'slate':
          bgColor = const Color(0xFF20242C);
          break;
        default:
          bgColor = null;
      }
    }
    return StreamBuilder<DatabaseEvent>(
      stream: currentUserRef.onValue,
      builder: (context, uSnap) {
        final uv = uSnap.data?.snapshot.value;
        final um = (uv is Map) ? uv : null;
        final myGithub = (um?['githubUsername'] ?? '').toString();
        final myGithubLower = myGithub.toLowerCase();

        return StreamBuilder<DatabaseEvent>(
          stream: dmContactRef.onValue,
          builder: (context, cSnap) {
                final cVal = cSnap.data?.snapshot.value;
                final dmAccepted = (cVal is bool) ? cVal : (cVal != null);

                String ttlLabel(int v) {
                  return switch (v) {
                    0 => 'Podle nastavení',
                    1 => 'Nikdy',
                    2 => '1 minuta',
                    3 => '1 hodina',
                    4 => '1 den',
                    5 => 'Po přečtení',
                    _ => 'Podle nastavení',
                  };
                }

                return Column(
                  children: [
            ListTile(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _activeLogin = null),
              ),
              title: Text('@$login'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: AppLanguage.tr(context, 'Fingerprint klíčů', 'Key fingerprint'),
                    icon: const Icon(Icons.fingerprint),
                    onPressed: () async {
                      final peerUid = await _ensureActiveOtherUid();
                      if (peerUid == null || peerUid.isEmpty) return;
                      await _showPeerFingerprintDialog(peerUid: peerUid, peerLogin: login);
                    },
                  ),
                  _ChatLoginAvatar(
                    login: login,
                    avatarUrl: _activeAvatarUrl ?? '',
                    radius: 18,
                  ),
                ],
              ),
              onTap: (loginLower == myGithubLower)
                  ? null
                  : () => _openUserProfile(login: login, avatarUrl: _activeAvatarUrl ?? ''),
            ),
            const Divider(height: 1),
            // DM žádosti – zobrazené i během chatu
            StreamBuilder<DatabaseEvent>(
              stream: rtdb().ref('dmRequests/${current.uid}').onValue,
              builder: (context, reqSnap) {
                final v = reqSnap.data?.snapshot.value;
                final m = (v is Map) ? v : null;

                final items = <Map<String, dynamic>>[];
                if (m != null) {
                  for (final e in m.entries) {
                    if (e.value is! Map) continue;
                    final mm = Map<String, dynamic>.from(e.value as Map);
                    mm['__key'] = e.key.toString();
                    items.add(mm);
                  }
                  items.sort((a, b) {
                    final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                    final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                    return bt.compareTo(at);
                  });
                }

                if (items.isEmpty) return const SizedBox.shrink();

                Future<void> accept(Map<String, dynamic> req) async {
                  final fromLogin = (req['fromLogin'] ?? '').toString();
                  if (fromLogin.trim().isEmpty) return;
                  try {
                    await _acceptDmRequest(myUid: current.uid, otherLogin: fromLogin);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba', 'Error')}: $e')));
                    }
                  }
                }

                Future<void> reject(Map<String, dynamic> req) async {
                  final fromLogin = (req['fromLogin'] ?? '').toString();
                  if (fromLogin.trim().isEmpty) return;
                  try {
                    await _rejectDmRequest(myUid: current.uid, otherLogin: fromLogin);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba', 'Error')}: $e')),
                      );
                    }
                  }
                }

                return Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.mail_lock_outlined),
                      title: Text(AppLanguage.tr(context, 'Žádosti o chat', 'Chat requests')),
                      subtitle: Text('${AppLanguage.tr(context, 'Čeká', 'Pending')}: ${items.length}'),
                    ),
                    ...items.map((req) {
                      final fromLogin = (req['fromLogin'] ?? '').toString();
                      final fromUid = (req['fromUid'] ?? '').toString();
                      final fromAvatar = (req['fromAvatarUrl'] ?? '').toString();
                      final hasEncryptedText = ((req['ciphertext'] ?? req['ct'] ?? req['cipher'])?.toString().isNotEmpty ?? false);
                      return ListTile(
                        leading: fromUid.isNotEmpty
                            ? _AvatarWithPresenceDot(uid: fromUid, avatarUrl: fromAvatar, radius: 18)
                            : CircleAvatar(
                                radius: 18,
                                backgroundImage: fromAvatar.isNotEmpty ? NetworkImage(fromAvatar) : null,
                                child: fromAvatar.isEmpty ? const Icon(Icons.person, size: 18) : null,
                              ),
                        title: Text('@$fromLogin'),
                        subtitle: hasEncryptedText
                          ? Text(AppLanguage.tr(context, 'Zpráva: 🔒 (šifrovaně)', 'Message: 🔒 (encrypted)'))
                          : Text(AppLanguage.tr(context, 'Invajt do privátu', 'Private chat invite')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => reject(req),
                            ),
                            IconButton(
                              icon: const Icon(Icons.check),
                              onPressed: () => accept(req),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 1),
                  ],
                );
              },
            ),
            StreamBuilder<DatabaseEvent>(
              stream: blockedRef.onValue,
              builder: (context, bSnap) {
                final blocked = bSnap.data?.snapshot.value == true;

                final canSend = true;

                return Expanded(
                  child: Column(
                    children: [
                      if (blocked)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          color: Theme.of(context).colorScheme.surface,
                          child: Text(AppLanguage.tr(context, 'Uživatel je zablokovaný. Zprávy nelze odesílat.', 'User is blocked. Messages cannot be sent.')),
                        ),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: bgColor ?? Theme.of(context).colorScheme.surface,
                          ),
                          child: StreamBuilder<DatabaseEvent>(
                            stream: messagesRef.onValue,
                            builder: (context, snapshot) {
                              final value = snapshot.data?.snapshot.value;
                              if (value is! Map) {
                                return Center(child: Text(AppLanguage.tr(context, 'Napiš první zprávu.', 'Write the first message.')));
                              }

                              if (_activeOtherUid == null || _activeOtherUidLoginLower != loginLower) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  _ensureActiveOtherUid().then((_) {
                                    if (!mounted) return;
                                    setState(() {});
                                  });
                                });
                              }

                              final now = DateTime.now().millisecondsSinceEpoch;
                              final items = <Map<String, dynamic>>[];
                              for (final e in value.entries) {
                                if (e.value is! Map) continue;
                                final msg = Map<String, dynamic>.from(e.value as Map);
                                msg['__key'] = e.key.toString();
                                final expiresAt = (msg['expiresAt'] is int) ? msg['expiresAt'] as int : null;
                                if (expiresAt != null && expiresAt <= now) {
                                  final k = (msg['__key'] ?? '').toString();
                                  if (k.isNotEmpty && !_ttlDeleting.contains(k)) {
                                    _ttlDeleting.add(k);
                                    () async {
                                      try {
                                        final peerUid = await _ensureActiveOtherUid();
                                        final myLogin = myGithub.trim();
                                        final updates = <String, Object?>{
                                          'messages/${current.uid}/$login/$k': null,
                                        };
                                        if (peerUid != null && peerUid.isNotEmpty && myLogin.isNotEmpty) {
                                          updates['messages/$peerUid/$myLogin/$k'] = null;
                                        }
                                        await rtdb().ref().update(updates);
                                      } catch (_) {
                                        try {
                                          await messagesRef.child(k).remove();
                                        } catch (_) {}
                                      } finally {
                                        _ttlDeleting.remove(k);
                                      }
                                    }();
                                  }
                                  continue;
                                }
                                items.add(msg);
                              }

                              items.sort((a, b) {
                                final at = (a['createdAt'] is int) ? a['createdAt'] as int : 0;
                                final bt = (b['createdAt'] is int) ? b['createdAt'] as int : 0;
                                return at.compareTo(bt);
                              });

                              // Best-effort migration: encrypt old plaintext messages.
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                for (final msg in items.take(30)) {
                                  final k = (msg['__key'] ?? '').toString();
                                  if (k.isEmpty) continue;
                                  if (_migrating.contains(k)) continue;
                                  final pt = (msg['text'] ?? '').toString();
                                  final hasC = ((msg['ciphertext'] ?? msg['ct'] ?? msg['cipher'])?.toString().isNotEmpty ?? false);
                                  final fu = (msg['fromUid'] ?? '').toString();
                                  if (pt.isEmpty || hasC || fu.isEmpty) continue;

                                  _migrating.add(k);
                                  () async {
                                    try {
                                      final otherUid = (fu == current.uid) ? (await _ensureActiveOtherUid()) : fu;
                                      if (otherUid == null || otherUid.isEmpty) return;
                                      final enc = await E2ee.encryptForUser(otherUid: otherUid, plaintext: pt);
                                      await messagesRef.child(k).update({
                                        ...enc,
                                        'text': null,
                                      });
                                      if (!mounted) return;
                                      setState(() => _decryptedCache[k] = pt);
                                      PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: k, plaintext: pt);
                                    } catch (_) {
                                      // ignore
                                    } finally {
                                      _migrating.remove(k);
                                    }
                                  }();
                                }
                              });

                              // Background warm-up: decrypt & persist ciphertext messages.
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                _warmupDmDecryptAll(items: items, loginLower: loginLower, myUid: current.uid);
                              });

                              return ListView.builder(
                                padding: const EdgeInsets.all(12),
                                itemCount: items.length,
                                itemBuilder: (context, i) {
                                  final m = items[i];
                                  final key = (m['__key'] ?? '').toString();
                                  final plaintext = (m['text'] ?? '').toString();
                                  final fromUid = (m['fromUid'] ?? '').toString();
                                  final isMe = fromUid == current.uid;
                                  final burnAfterRead = m['burnAfterRead'] == true;
                                  final createdAt = (m['createdAt'] is int) ? m['createdAt'] as int : null;
                                  final timeLabel = _formatShortTime(createdAt);
                                  final otherUid = isMe ? (_activeOtherUid ?? '') : fromUid;
                                  if (!isMe && otherUid.isNotEmpty && canSend && !blocked) {
                                    _markDeliveredRead(
                                      key: key,
                                      myUid: current.uid,
                                      otherUid: otherUid,
                                      myLogin: myGithub.trim(),
                                      otherLogin: login,
                                      markRead: true,
                                    );
                                  }

                                  final hasCipher = ((m['ciphertext'] ?? m['ct'] ?? m['cipher'])?.toString().isNotEmpty ?? false);
                                  String text = plaintext;
                                  if (text.isEmpty && hasCipher) {
                                    final persisted = PlaintextCache.tryGetDm(otherLoginLower: loginLower, messageKey: key);
                                    if (persisted != null && persisted.isNotEmpty) {
                                      text = persisted;
                                      _decryptedCache[key] ??= persisted;
                                    } else {
                                      text = _decryptedCache[key] ?? '🔒 …';
                                    }

                                    if (persisted == null && _decryptedCache[key] == null && !_decrypting.contains(key)) {
                                      _decrypting.add(key);
                                      () async {
                                        try {
                                          final peerUid = await _ensureActiveOtherUid();
                                          final otherUid = isMe ? (peerUid ?? '') : (fromUid.isNotEmpty ? fromUid : (peerUid ?? ''));
                                          if (otherUid.isEmpty) return;
                                          final plain = await E2ee.decryptFromUser(otherUid: otherUid, message: m);
                                          if (!mounted) return;
                                          setState(() => _decryptedCache[key] = plain);
                                          PlaintextCache.putDm(otherLoginLower: loginLower, messageKey: key, plaintext: plain);

                                          if (burnAfterRead && !isMe) {
                                            if (key.isNotEmpty && !_ttlDeleting.contains(key)) {
                                              _ttlDeleting.add(key);
                                              () async {
                                                try {
                                                  final peerUid = await _ensureActiveOtherUid();
                                                  final myLogin = myGithub.trim();
                                                  final updates = <String, Object?>{
                                                    'messages/${current.uid}/$login/$key': null,
                                                  };
                                                  if (peerUid != null && peerUid.isNotEmpty && myLogin.isNotEmpty) {
                                                    updates['messages/$peerUid/$myLogin/$key'] = null;
                                                  }
                                                  await rtdb().ref().update(updates);
                                                } catch (_) {
                                                  try {
                                                    await messagesRef.child(key).remove();
                                                  } catch (_) {}
                                                } finally {
                                                  _ttlDeleting.remove(key);
                                                }
                                              }();
                                            }
                                          }
                                        } catch (_) {
                                          // keep placeholder
                                        } finally {
                                          _decrypting.remove(key);
                                        }
                                      }();
                                    }
                                  }

                                  final attachment = _AttachmentPayload.tryParse(text);
                                  final isAttachment = attachment != null;
                                  final codePayload = _CodeMessagePayload.tryParse(text);
                                  final isCode = codePayload != null;
                                  if (attachment != null) {
                                    final cacheKey = 'dm:$loginLower:$key';
                                    if (!_attachmentCache.containsKey(cacheKey)) {
                                      _ensureAttachmentCached(cacheKey: cacheKey, payload: attachment);
                                    }
                                  }

                                  final mentioned =
                                      !isAttachment && !isCode && myGithubLower.isNotEmpty && text.toLowerCase().contains('@$myGithubLower');

                                  final replyToFrom = (m['replyToFrom'] ?? '').toString().trim();
                                  final replyToPreview = (m['replyToPreview'] ?? '').toString().trim();
                                  final hasReply = replyToFrom.isNotEmpty && replyToPreview.isNotEmpty;

                                  final bubbleKey = isMe ? widget.settings.bubbleOutgoing : widget.settings.bubbleIncoming;
                                  final color = _bubbleColor(context, bubbleKey);
                                  final tcolor = _bubbleTextColor(context, bubbleKey);

                                  final reactions = (m['reactions'] is Map) ? (m['reactions'] as Map) : null;
                                  final reactionChips = <Widget>[];
                                  if (reactions != null) {
                                    for (final re in reactions.entries) {
                                      final emoji = re.key.toString();
                                      final voters = (re.value is Map) ? (re.value as Map) : null;
                                      final count = voters?.length ?? 0;
                                      if (count > 0) {
                                        reactionChips.add(
                                          Container(
                                            margin: const EdgeInsets.only(top: 4, right: 6),
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.surface,
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Text('$emoji $count', style: TextStyle(fontSize: widget.settings.chatTextSize - 4)),
                                          ),
                                        );
                                      }
                                    }
                                  }

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 6),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onLongPress: blocked
                                          ? null
                                          : () => _showMessageActions(
                                                isGroup: false,
                                                chatTarget: login,
                                                messageKey: key,
                                                fromLabel: isMe ? myGithub : login,
                                                text: text,
                                                canDeleteForMe: true,
                                                canDeleteForAll: isMe,
                                                onDeleteForMe: () async {
                                                  await messagesRef.child(key).remove();
                                                },
                                                onDeleteForAll: isMe
                                                    ? () async {
                                                        final peerUid = await _ensureActiveOtherUid();
                                                        final myLogin = myGithub.trim();
                                                        final updates = <String, Object?>{
                                                          'messages/${current.uid}/$login/$key': null,
                                                        };
                                                        if (peerUid != null && peerUid.isNotEmpty && myLogin.isNotEmpty) {
                                                          updates['messages/$peerUid/$myLogin/$key'] = null;
                                                        }
                                                        await rtdb().ref().update(updates);
                                                      }
                                                    : null,
                                              ),
                                      child: Column(
                                        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                        children: [
                                          Align(
                                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                              decoration: BoxDecoration(
                                                color: color,
                                                borderRadius: BorderRadius.circular(widget.settings.bubbleRadius),
                                                border: mentioned ? Border.all(color: Colors.amber, width: 2) : null,
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  if (hasReply)
                                                    Container(
                                                      margin: const EdgeInsets.only(bottom: 8),
                                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black26,
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(color: Colors.white24),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          const Icon(Icons.subdirectory_arrow_right, size: 14, color: Colors.white70),
                                                          const SizedBox(width: 6),
                                                          Flexible(
                                                            child: Text(
                                                              '@$replyToFrom • $replyToPreview',
                                                              maxLines: 2,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: TextStyle(fontSize: widget.settings.chatTextSize - 2, color: Colors.white70),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  if (attachment != null)
                                                    _attachmentBubble(
                                                      payload: attachment,
                                                      cacheKey: 'dm:$loginLower:$key',
                                                      maxWidth: MediaQuery.of(context).size.width * 0.62,
                                                      radius: widget.settings.bubbleRadius,
                                                    )
                                                  else if (codePayload != null)
                                                    InkWell(
                                                      onTap: () => _openCodeSnippetSheet(codePayload),
                                                      borderRadius: BorderRadius.circular(8),
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                        decoration: BoxDecoration(
                                                          color: Colors.white10,
                                                          borderRadius: BorderRadius.circular(8),
                                                          border: Border.all(color: Colors.white24),
                                                        ),
                                                        child: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            const Icon(Icons.code, size: 16),
                                                            const SizedBox(width: 8),
                                                            Flexible(
                                                              child: Text(
                                                                codePayload.previewLabel(),
                                                                maxLines: 2,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: TextStyle(fontSize: widget.settings.chatTextSize, color: tcolor),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    )
                                                  else
                                                    _RichMessageText(
                                                      text: text,
                                                      fontSize: widget.settings.chatTextSize,
                                                      textColor: tcolor,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (reactionChips.isNotEmpty)
                                            Wrap(
                                              alignment: WrapAlignment.end,
                                              children: reactionChips,
                                            ),
                                          if (timeLabel.isNotEmpty || isMe)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 4),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                                children: [
                                                  if (timeLabel.isNotEmpty)
                                                    Text(
                                                      timeLabel,
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                                      ),
                                                    ),
                                                  if (isMe) ...[
                                                    if (timeLabel.isNotEmpty) const SizedBox(width: 6),
                                                    _statusChecks(
                                                      message: m,
                                                      otherUid: _activeOtherUid,
                                                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                      if (!blocked && _activeOtherUid != null && _activeOtherUid!.isNotEmpty)
                        StreamBuilder<DatabaseEvent>(
                          stream: rtdb().ref('typing/${_activeOtherUid!}/${current.uid}').onValue,
                          builder: (context, tSnap) {
                            final tval = tSnap.data?.snapshot.value;
                            final typing = (tval is Map) ? (tval['typing'] == true) : false;
                            if (!typing) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _typingPill(),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${AppLanguage.tr(context, 'Píše', 'Typing')} @$login',
                                      style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      if (_replyToPreview != null && _replyToPreview!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.subdirectory_arrow_right, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '@${_replyToFrom ?? ''} • ${_replyToPreview ?? ''}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: _clearReplyTarget,
                                  tooltip: AppLanguage.tr(context, 'Zrušit odpověď', 'Cancel reply'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (!blocked &&
                          _activeOtherUid != null &&
                          _activeOtherUid!.isNotEmpty &&
                          _peerHasPublishedKey[loginLower] == false &&
                          !_inlineKeyRequestSent.contains(loginLower))
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: FilledButton.tonalIcon(
                            onPressed: (_sendingInlineKeyRequest || myGithub.trim().isEmpty)
                                ? null
                                : () async {
                                    setState(() => _sendingInlineKeyRequest = true);
                                    try {
                                      await _sendDmRequest(
                                        myUid: current.uid,
                                        myLogin: myGithub.trim(),
                                        otherUid: _activeOtherUid!,
                                        otherLogin: login,
                                        messageText: AppLanguage.tr(context, '🔐 Prosím povol sdílení E2EE klíče, ať se naváže šifrovaná komunikace.', '🔐 Please allow E2EE key sharing so encrypted communication can start.'),
                                      );
                                      if (!mounted) return;
                                      setState(() {
                                        _inlineKeyRequestSent.add(loginLower);
                                      });
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            dmAccepted
                                                ? AppLanguage.tr(context, 'Žádost o sdílení klíče odeslána.', 'Key sharing request sent.')
                                                : AppLanguage.tr(context, 'Invajt + žádost o sdílení klíče odeslána.', 'Invite + key sharing request sent.'),
                                          ),
                                        ),
                                      );
                                    } catch (e) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('${AppLanguage.tr(context, 'Chyba', 'Error')}: $e')),
                                      );
                                    } finally {
                                      if (mounted) setState(() => _sendingInlineKeyRequest = false);
                                    }
                                  },
                            icon: _sendingInlineKeyRequest
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.key_outlined),
                            label: Text(
                              dmAccepted
                                  ? AppLanguage.tr(context, 'Poprosit sdílet klíč', 'Ask to share key')
                                  : AppLanguage.tr(context, 'Poslat invajt + požádat o klíč', 'Send invite + ask for key'),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _messageController,
                                decoration: InputDecoration(labelText: AppLanguage.tr(context, 'Zpráva / Markdown', 'Message / Markdown')),
                                enabled: !blocked && canSend,
                                minLines: 1,
                                maxLines: 6,
                                onSubmitted: (!blocked && canSend) ? (_) => _send() : null,
                                onChanged: (!blocked && canSend)
                                    ? (text) {
                                        if (_pendingCodePayload != null && !text.trim().startsWith('<> kód')) {
                                          setState(() => _pendingCodePayload = null);
                                        }
                                        _onTypingChanged(text);
                                      }
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<String>(
                              tooltip: AppLanguage.tr(context, 'Více', 'More'),
                              enabled: (!blocked && canSend),
                              onSelected: (value) async {
                                if (value == 'image') {
                                  final otherUid = await _ensureActiveOtherUid();
                                  if (otherUid == null || otherUid.isEmpty) return;
                                  await _sendImageDm(
                                    current: current,
                                    login: login,
                                    myLogin: myGithub.trim(),
                                    otherUid: otherUid,
                                    canSend: canSend,
                                  );
                                  return;
                                }
                                if (value == 'code') {
                                  await _insertCodeBlockTemplate();
                                  return;
                                }
                                if (value.startsWith('ttl:')) {
                                  final ttl = int.tryParse(value.split(':').last);
                                  if (ttl != null) {
                                    setState(() => _dmTtlMode = ttl);
                                  }
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem<String>(
                                  value: 'image',
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.image_outlined),
                                    title: Text(AppLanguage.tr(context, 'Poslat obrázek', 'Send image')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'code',
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.code),
                                    title: Text(AppLanguage.tr(context, 'Vložit kód', 'Insert code')),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const PopupMenuDivider(),
                                for (final ttl in const [0, 1, 2, 3, 4, 5])
                                  PopupMenuItem<String>(
                                    value: 'ttl:$ttl',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(
                                        _dmTtlMode == ttl ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                      ),
                                      title: Text('${AppLanguage.tr(context, 'Ničení', 'TTL')}: ${ttlLabel(ttl)}'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                              ],
                              icon: const Icon(Icons.more_vert),
                            ),
                            IconButton(
                              icon: const Icon(Icons.send),
                              onPressed: (!blocked && canSend) ? _send : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
                  ],
                );
          },
        );
      },
    );
  }
}
