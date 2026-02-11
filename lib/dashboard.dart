import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:gitmit/e2ee.dart';
import 'package:gitmit/group_invites.dart';
import 'package:gitmit/github_api.dart';
import 'package:gitmit/join_group_via_link_qr_page.dart';
import 'package:gitmit/plaintext_cache.dart';
import 'package:gitmit/rtdb.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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

Future<String?> _myGithubUsernameFromRtdb(String myUid) async {
  final snap = await rtdb().ref('users/$myUid/githubUsername').get();
  final v = snap.value;
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

Future<String?> _myAvatarUrlFromRtdb(String myUid) async {
  final snap = await rtdb().ref('users/$myUid/avatarUrl').get();
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
  const _UserProfilePage({required this.login, required this.avatarUrl});

  final String login;
  final String avatarUrl;

  @override
  State<_UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<_UserProfilePage> {
  String _loginLower() => widget.login.trim().toLowerCase();

  Future<String?> _myGithubUsername(String myUid) async {
    final snap = await rtdb().ref('users/$myUid/githubUsername').get();
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Pokračovat')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hotovo.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    }
  }

  Future<void> _confirmAndRunThenPop({
    required String title,
    required String message,
    required Future<void> Function() action,
    required String popResult,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Pokračovat')),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return const Scaffold(body: Center(child: Text('Nejsi přihlášen.')));
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
                future: _fetchGithubProfileData(widget.login),
                builder: (context, ghSnap) {
                  final gh = ghSnap.data;
                  final fetchedAvatar = gh?['avatarUrl'] as String?;
                  final activitySvg = gh?['contributions'] as String?;
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

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(child: avatarWidget),
                      const SizedBox(height: 16),
                      StreamBuilder<DatabaseEvent>(
                        stream: hasOtherUid ? otherUserRef.child(otherUid).onValue : const Stream.empty(),
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
                      if (!hasOtherUid) const Text('Účet není propojený v databázi.'),

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
                                          const Text('E2EE Fingerprint (anti-MITM)', style: TextStyle(fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 8),
                                          if (peerFp != null && peerFp.isNotEmpty)
                                            ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title: const Text('Fingerprint protějšku'),
                                              subtitle: SelectableText(peerFp),
                                              trailing: IconButton(
                                                icon: const Icon(Icons.copy),
                                                onPressed: () => Clipboard.setData(ClipboardData(text: peerFp)),
                                              ),
                                            )
                                          else
                                            const Text('Fingerprint protějšku není dostupný (uživatel ještě nezveřejnil klíč).'),
                                          if (myFp != null && myFp.isNotEmpty)
                                            ListTile(
                                              contentPadding: EdgeInsets.zero,
                                              title: const Text('Můj fingerprint'),
                                              subtitle: SelectableText(myFp),
                                              trailing: IconButton(
                                                icon: const Icon(Icons.copy),
                                                onPressed: () => Clipboard.setData(ClipboardData(text: myFp)),
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
                      const Text('Aktivita na GitHubu',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      if (activitySvg != null)
                        SizedBox(height: 120, child: _SvgWidget(svg: activitySvg))
                      else
                        const Text('Načítání aktivity...'),
                      const SizedBox(height: 24),
                      const Text('Top repozitáře',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
                        const Text('Načítání repozitářů...'),
                      const SizedBox(height: 24),
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
                  title: blocked ? 'Odblokovat uživatele?' : 'Zablokovat uživatele?',
                  message: blocked
                      ? 'Znovu povolíš zprávy a zobrazování chatu.'
                      : 'Zabráníš odesílání zpráv a chat se skryje v přehledu.',
                  action: () => _toggleBlock(myUid: myUid, currentlyBlocked: blocked),
                ),
                child: Text(blocked ? 'Odblokovat' : 'Zablokovat'),
              );
            },
          ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: () => _confirmAndRunThenPop(
              title: 'Smazat chat u mě?',
              message: 'Smaže zprávy a přehled konverzace jen u tebe.',
              action: () => _deleteChatForMe(myUid: myUid),
              popResult: 'deleted_chat_for_me',
            ),
            child: const Text('Smazat chat u mě'),
          ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: () => _confirmAndRunThenPop(
              title: 'Smazat chat u obou?',
              message: 'Pokusí se smazat konverzaci u obou uživatelů. Funguje jen pokud je druhá strana propojená v databázi.',
              action: () => _deleteChatForBoth(myUid: myUid),
              popResult: 'deleted_chat_for_both',
            ),
            child: const Text('Smazat chat u obou'),
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
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final title = _title.text.trim();
    final desc = _description.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vyplň název skupiny.')));
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
              SnackBar(content: Text('Logo se nepodařilo nahrát (skupina se vytvoří i tak): $e')),
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
          SnackBar(content: Text('Nenalezeno v aplikaci: ${missing.map((e) => '@$e').join(', ')}')),
        );
      }

      Navigator.of(context).pop(groupId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vytvořit skupinu')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Název'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Popis'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _logoUrl,
            decoration: const InputDecoration(labelText: 'Logo URL (volitelné)'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: (_saving || _pickingLogo) ? null : _pickLogo,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(_pickedLogoBytes == null ? 'Vybrat logo z galerie' : 'Změnit logo'),
                ),
              ),
              const SizedBox(width: 12),
              if (_pickedLogoBytes != null)
                OutlinedButton(
                  onPressed: _saving ? null : () => setState(() => _pickedLogoBytes = null),
                  child: const Text('Odebrat'),
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
          const Text('Permissions', style: TextStyle(fontWeight: FontWeight.bold)),
          SwitchListTile(
            value: _sendMessages,
            onChanged: (v) => setState(() => _sendMessages = v),
            title: const Text('Send new messages'),
          ),
          SwitchListTile(
            value: _allowMembersToAdd,
            onChanged: (v) => setState(() => _allowMembersToAdd = v),
            title: const Text('Přidávat uživatele'),
          ),
          SwitchListTile(
            value: _inviteLinkEnabled,
            onChanged: (v) => setState(() => _inviteLinkEnabled = v),
            title: const Text('Invite via link / QR'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _members,
            decoration: const InputDecoration(
              labelText: 'Přidat lidi podle username',
              hintText: '@user1, @user2',
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
            child: _saving ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator()) : const Text('Vytvořit'),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Logo se nepodařilo nahrát: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return const Scaffold(body: Center(child: Text('Nepřihlášen.')));

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
                  appBar: AppBar(title: const Text('Skupina')),
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
                                Text(isAdmin ? 'Admin' : 'Member', style: Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      if (isAdmin) ...[
                        TextField(controller: _title, decoration: const InputDecoration(labelText: 'Název')),
                        const SizedBox(height: 12),
                        TextField(controller: _description, decoration: const InputDecoration(labelText: 'Popis'), maxLines: 3),
                        const SizedBox(height: 12),
                        TextField(controller: _logoUrl, decoration: const InputDecoration(labelText: 'Logo URL')),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: () => _pickAndUploadLogo(groupId: widget.groupId),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Vybrat logo z galerie'),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () => _update(widget.groupId, {
                            'title': _title.text.trim(),
                            'description': _description.text.trim(),
                            'logoUrl': _logoUrl.text.trim(),
                          }),
                          child: const Text('Uložit'),
                        ),
                        const Divider(height: 32),
                        const Text('Permissions', style: TextStyle(fontWeight: FontWeight.bold)),
                        SwitchListTile(
                          value: sendMessages,
                          onChanged: (v) => _update(widget.groupId, {
                            'permissions/sendMessages': v,
                          }),
                          title: const Text('Send new messages'),
                        ),
                        SwitchListTile(
                          value: allowMembersToAdd,
                          onChanged: (v) => _update(widget.groupId, {
                            'permissions/allowMembersToAdd': v,
                          }),
                          title: const Text('Přidávat uživatele'),
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
                          title: const Text('Invite via link / QR'),
                        ),
                      ] else ...[
                        ListTile(title: Text(title), subtitle: desc.isNotEmpty ? Text(desc) : null),
                        const Divider(height: 32),
                      ],

                      if (inviteLinkEnabled) ...[
                        const Text('Invite link / QR', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        FutureBuilder<String?>(
                          future: _inviteCodeFuture,
                          builder: (context, codeSnap) {
                            final code = (codeSnap.data ?? '').trim();
                            if (code.isEmpty) {
                              return const ListTile(
                                leading: Icon(Icons.link),
                                title: Text('Link není dostupný'),
                                subtitle: Text('Zkus to za chvilku znovu.'),
                              );
                            }
                            final link = buildGroupInviteLink(groupId: widget.groupId, code: code);
                            final qrPayload = buildGroupInviteQrPayload(groupId: widget.groupId, code: code);

                            return Column(
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.link),
                                  title: const Text('Pozvánka'),
                                  subtitle: Text(link, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.copy),
                                    onPressed: () async {
                                      await Clipboard.setData(ClipboardData(text: link));
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Link zkopírován.')),
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
                                    label: const Text('Regenerovat pozvánku'),
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
                        title: const Text('Přidat uživatele'),
                        subtitle: Text(
                          allowMembersToAdd ? 'Pošle se žádost adminům (pokud nejsi admin).' : 'Může jen admin.',
                        ),
                        onTap: (!allowMembersToAdd && !isAdmin)
                            ? null
                            : () async {
                                final picked = await showModalBottomSheet<GithubUser>(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (context) => const _GithubUserSearchSheet(title: 'Přidat uživatele'),
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
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pozvánka odeslána.')));
                                    }
                                  } else {
                                    await _requestAddMember(
                                      groupId: widget.groupId,
                                      targetLogin: normalized,
                                      requestedByGithub: myGithub,
                                    );
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Žádost odeslána adminům.')));
                                    }
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
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
                                title: const Text('Odejít ze skupiny?'),
                                content: const Text('Skupinu opustíš a zmizí ti ze seznamu.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Odejít')),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            await _leaveGroupAsMember(groupId: widget.groupId, uid: current.uid);
                            if (!mounted) return;
                            Navigator.of(context).pop('left');
                          },
                          icon: const Icon(Icons.logout),
                          label: const Text('Odejít ze skupiny'),
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
                                    title: const Text('Jsi admin'),
                                    content: const Text('Před odchodem musíš předat admina, nebo smazat celou skupinu.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zrušit')),
                                      TextButton(onPressed: () => Navigator.pop(context, 'transfer'), child: const Text('Předat admina')),
                                      FilledButton(onPressed: () => Navigator.pop(context, 'delete'), child: const Text('Smazat skupinu')),
                                    ],
                                  ),
                                );
                                if (action == null) return;
                                if (action == 'delete') {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Smazat skupinu?'),
                                      content: const Text('Tohle smaže skupinu pro všechny.'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
                                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Smazat')),
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
                                    const SnackBar(content: Text('Ve skupině není nikdo další. Můžeš ji jen smazat.')),
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
                                          const ListTile(
                                            title: Text('Vyber nového admina', style: TextStyle(fontWeight: FontWeight.w700)),
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
                              label: const Text('Odejít / smazat'),
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
  late final _AppLifecycleObserver _lifecycleObserver;

  final GlobalKey<_ChatsTabState> _chatsKey = GlobalKey<_ChatsTabState>();

  static const _titles = <String>[
    'Jobs',
    'Chaty',
    'Kontakty',
    'Nastavení',
    'Profil',
  ];

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
    final title = _titles[_index];
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
    const items = <({IconData icon, String label})>[
      (icon: Icons.dashboard, label: 'Jobs'),
      (icon: Icons.chat_bubble_outline, label: 'Chaty'),
      (icon: Icons.people_outline, label: 'Kontakty'),
      (icon: Icons.settings_outlined, label: 'Nastavení'),
      (icon: Icons.person_outline, label: 'Profil'),
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

  Future<void> _logout() async {
    // Reset E2EE scope immediately so any late async tasks won't read/write
    // keys/sessions under the wrong user after logout.
    E2ee.setActiveUser(null);
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

  void _openChat({required String login, required String avatarUrl}) {
    final key = login.trim().toLowerCase();
    if (key.isEmpty) return;

    () async {
      final snap = await rtdb().ref('usernames/$key').get();
      final v = snap.value;
      final uid = (v == null) ? '' : v.toString().trim();
      if (!mounted) return;

      if (uid.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uživatel @$login nepoužívá GitMit (nelze zjistit UID).')),
        );
        return;
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _connectedSub?.cancel();
    _presenceEnabledSub?.cancel();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    if (!_presenceEnabled) return;
    final presenceRef = rtdb().ref('presence/${current.uid}');

    if (state == AppLifecycleState.resumed) {
      final online = _presenceStatus != 'hidden';
      presenceRef.update({'enabled': true, 'status': _presenceStatus, 'online': online, 'lastChangedAt': ServerValue.timestamp});
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      presenceRef.update({'enabled': true, 'status': _presenceStatus, 'online': false, 'lastChangedAt': ServerValue.timestamp});
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
        rtdb().ref('presence/${current.uid}').set({
          'enabled': false,
          'status': _presenceStatus,
          'online': false,
          'lastChangedAt': ServerValue.timestamp,
        });
      } else {
        _initPresence();
      }
    });
  }

  void _initPresence() {
    if (_presenceInitialized) return;
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    if (!_presenceEnabled) return;
    _presenceInitialized = true;

    final connectedRef = rtdb().ref('.info/connected');
    final presenceRef = rtdb().ref('presence/${current.uid}');

    _connectedSub = connectedRef.onValue.listen((event) async {
      final connected = event.snapshot.value == true;
      if (!connected) return;

      final online = _presenceStatus != 'hidden';

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
          const _PlaceholderTab(text: 'Jobs'),
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

        return WillPopScope(
          onWillPop: _onWillPop,
          child: Scaffold(
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
                  decoration: const InputDecoration(
                    labelText: 'Hledat na GitHubu',
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
      language: readString('language', 'cs'),
    );
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

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(text));
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
    if (u == null) return const Center(child: Text('Nepřihlášen.'));
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
              title: 'Účet',
              subtitle: 'Telefon, narozeniny, bio, účty',
              onTap: () => _open(context, _SettingsAccountPage(onLogout: onLogout)),
            ),
            _SettingsSectionTile(
              icon: Icons.chat_bubble_outline,
              title: 'Nastavení chatů',
              subtitle: 'Obrázek na pozadí, barvy, velikost textu',
              onTap: () => _open(context, const _SettingsChatPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.lock_outline,
              title: 'Soukromí',
              subtitle: 'Auto-delete, status, presence, dárky',
              onTap: () => _open(context, const _SettingsPrivacyPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.notifications_none,
              title: 'Upozornění',
              subtitle: 'Zvuky a vibrace',
              onTap: () => _open(context, const _SettingsNotificationsPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.storage_outlined,
              title: 'Data a paměť',
              subtitle: 'Zatím základní',
              onTap: () => _open(context, const _SettingsDataPage()),
            ),
            _SettingsSectionTile(
              icon: Icons.devices_outlined,
              title: 'Zařízení',
              subtitle: 'Aktivní sezení (brzy)',
              onTap: () => _open(context, _SettingsDevicesPage(onLogout: onLogout)),
            ),
            _SettingsSectionTile(
              icon: Icons.language,
              title: 'Jazyk',
              subtitle: 'Čeština / English',
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
        const SnackBar(content: Text('Nepodařilo se otevřít GitHub logout.')),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Účet')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _phone,
            decoration: const InputDecoration(labelText: 'Telefon (volitelné)'),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _birthday,
            decoration: const InputDecoration(labelText: 'Narozeniny (např. 2000-01-31)'),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Bio'),
            onChanged: (_) => _autoSave(),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: widget.onLogout,
            child: const Text('Odhlásit se'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _openGitHubLogout,
            child: const Text('Odhlásit z GitHubu'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _reset,
            child: const Text('Reset'),
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
  final _wallpaper = TextEditingController();
  final _debouncer = _Debouncer(const Duration(milliseconds: 600));

  @override
  void dispose() {
    _debouncer.dispose();
    _wallpaper.dispose();
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
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return const Scaffold(body: Center(child: Text('Nepřihlášen.')));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final settings = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        if (_wallpaper.text != settings.wallpaperUrl) {
          _wallpaper.text = settings.wallpaperUrl;
          _wallpaper.selection = TextSelection.fromPosition(TextPosition(offset: _wallpaper.text.length));
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Nastavení chatů')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                title: const Text('Velikost textu'),
                subtitle: Slider(
                  min: 12,
                  max: 24,
                  value: settings.chatTextSize.clamp(12, 24),
                  onChanged: (v) => _updateSetting(u.uid, {'chatTextSize': v}),
                ),
                trailing: Text(settings.chatTextSize.toStringAsFixed(0)),
              ),
              ListTile(
                title: const Text('Zaoblení bublin'),
                subtitle: Slider(
                  min: 4,
                  max: 28,
                  value: settings.bubbleRadius.clamp(4, 28),
                  onChanged: (v) => _updateSetting(u.uid, {'bubbleRadius': v}),
                ),
                trailing: Text(settings.bubbleRadius.toStringAsFixed(0)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _wallpaper,
                decoration: const InputDecoration(labelText: 'Wallpaper URL (volitelné)'),
                onChanged: (_) => _debouncer.run(() => _updateSetting(u.uid, {'wallpaperUrl': _wallpaper.text.trim()})),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: settings.bubbleIncoming,
                      decoration: const InputDecoration(labelText: 'Příchozí bublina'),
                      items: const [
                        DropdownMenuItem(value: 'surface', child: Text('Surface')),
                        DropdownMenuItem(value: 'surfaceVariant', child: Text('Surface Variant')),
                        DropdownMenuItem(value: 'primaryContainer', child: Text('Primary Container')),
                      ],
                      onChanged: (v) => _updateSetting(u.uid, {'bubbleIncoming': v ?? 'surface'}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: settings.bubbleOutgoing,
                      decoration: const InputDecoration(labelText: 'Odchozí bublina'),
                      items: const [
                        DropdownMenuItem(value: 'secondaryContainer', child: Text('Secondary Container')),
                        DropdownMenuItem(value: 'primaryContainer', child: Text('Primary Container')),
                        DropdownMenuItem(value: 'surface', child: Text('Surface')),
                      ],
                      onChanged: (v) => _updateSetting(u.uid, {'bubbleOutgoing': v ?? 'secondaryContainer'}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ChatPreview(settings: settings),
              const SizedBox(height: 12),
              SwitchListTile(
                value: settings.reactionsEnabled,
                onChanged: (v) => _updateSetting(u.uid, {'reactionsEnabled': v}),
                title: const Text('Reakce na zprávy'),
                subtitle: const Text('Dlouhé podržení na zprávě'),
              ),
              SwitchListTile(
                value: settings.stickersEnabled,
                onChanged: (v) => _updateSetting(u.uid, {'stickersEnabled': v}),
                title: const Text('Stickers'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: const Text('Reset'),
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
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return const Center(child: Text('Nepřihlášen.'));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: const Text('Soukromí')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<int>(
                value: s.autoDeleteSeconds,
                decoration: const InputDecoration(labelText: 'Auto-delete zpráv'),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Vypnuto')),
                  DropdownMenuItem(value: 86400, child: Text('24 hodin')),
                  DropdownMenuItem(value: 604800, child: Text('7 dní')),
                  DropdownMenuItem(value: 2592000, child: Text('30 dní')),
                ],
                onChanged: (v) => _update(u.uid, {'autoDeleteSeconds': v ?? 0}),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: s.presenceEnabled,
                onChanged: (v) => _update(u.uid, {'presenceEnabled': v}),
                title: const Text('Presence (online/offline)'),
              ),
              DropdownButtonFormField<String>(
                value: s.presenceStatus,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'online', child: Text('Online')),
                  DropdownMenuItem(value: 'dnd', child: Text('DND')),
                  DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                ],
                onChanged: (v) => _update(u.uid, {'presenceStatus': v ?? 'online'}),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: s.giftsVisible,
                onChanged: (v) => _update(u.uid, {'giftsVisible': v}),
                title: const Text('Dárky viditelné'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: const Text('Reset'),
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
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return const Center(child: Text('Nepřihlášen.'));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: const Text('Upozornění')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SwitchListTile(
                value: s.notificationsEnabled,
                onChanged: (v) => _update(u.uid, {'notificationsEnabled': v}),
                title: const Text('Notifikace'),
                subtitle: const Text('Push upozornění a upozornění v aplikaci'),
              ),
              SwitchListTile(
                value: s.vibrationEnabled,
                onChanged: (v) => _update(u.uid, {'vibrationEnabled': v}),
                title: const Text('Vibrace'),
              ),
              SwitchListTile(
                value: s.soundsEnabled,
                onChanged: (v) => _update(u.uid, {'soundsEnabled': v}),
                title: const Text('Zvuky'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: const Text('Reset'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsDataPage extends StatelessWidget {
  const _SettingsDataPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data a paměť')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Zatím tu nejsou další volby. (Nechám připravené pro další funkce.)'),
      ),
    );
  }
}

class _SettingsDevicesPage extends StatelessWidget {
  const _SettingsDevicesPage({required this.onLogout});
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zařízení')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Aktivní sezení zatím není implementované.'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onLogout,
              child: const Text('Odhlásit se'),
            ),
          ],
        ),
      ),
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
  }

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return const Center(child: Text('Nepřihlášen.'));
    final settingsRef = rtdb().ref('settings/${u.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: settingsRef.onValue,
      builder: (context, snap) {
        final s = UserSettings.fromSnapshot(snap.data?.snapshot.value);
        return Scaffold(
          appBar: AppBar(title: const Text('Jazyk')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              DropdownButtonFormField<String>(
                value: s.language,
                decoration: const InputDecoration(labelText: 'Jazyk'),
                items: const [
                  DropdownMenuItem(value: 'cs', child: Text('Čeština')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (v) => _update(u.uid, {'language': v ?? 'cs'}),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _reset(u.uid),
                child: const Text('Reset'),
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

  Color _bubbleColor(BuildContext context, String key, {required bool outgoing}) {
    final cs = Theme.of(context).colorScheme;
    switch (key) {
      case 'surfaceVariant':
        return cs.surfaceVariant;
      case 'primaryContainer':
        return cs.primaryContainer;
      case 'secondaryContainer':
        return cs.secondaryContainer;
      case 'surface':
      default:
        return cs.surface;
    }
  }

  Color _bubbleTextColor(BuildContext context, String key) {
    final cs = Theme.of(context).colorScheme;
    switch (key) {
      case 'surfaceVariant':
        return cs.onSurfaceVariant;
      case 'primaryContainer':
        return cs.onPrimaryContainer;
      case 'secondaryContainer':
        return cs.onSecondaryContainer;
      case 'surface':
      default:
        return cs.onSurface;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = settings.wallpaperUrl.trim();
    final decoration = (bg.isEmpty)
        ? null
        : BoxDecoration(
            image: DecorationImage(
              image: NetworkImage(bg),
              fit: BoxFit.cover,
              opacity: 0.35,
            ),
          );

    final inColor = _bubbleColor(context, settings.bubbleIncoming, outgoing: false);
    final outColor = _bubbleColor(context, settings.bubbleOutgoing, outgoing: true);
    final inText = _bubbleTextColor(context, settings.bubbleIncoming);
    final outText = _bubbleTextColor(context, settings.bubbleOutgoing);

    Widget bubble({required bool outgoing, required String text}) {
      final color = outgoing ? outColor : inColor;
      final tcolor = outgoing ? outText : inText;
      return Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(settings.bubbleRadius),
          ),
          child: Text(text, style: TextStyle(fontSize: settings.chatTextSize, color: tcolor)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: decoration,
      child: Column(
        children: [
          bubble(outgoing: false, text: 'Ahoj! Tohle je preview.'),
          bubble(outgoing: true, text: 'Super, vidím změny hned.'),
        ],
      ),
    );
  }
}

// -------------------- Ověření (verified) --------------------

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

String _statusText(String? status) {
  switch (status) {
    case 'pending':
      return 'Čeká se na moderátora';
    case 'approved':
      return 'Schváleno';
    case 'declined':
      return 'Zamítnuto';
    default:
      return 'Bez žádosti';
  }
}

bool _isModeratorFromUserMap(Map? userMap) {
  return userMap?['isModerator'] == true;
}

Future<Map<String, dynamic>?> _fetchGithubProfileData(String? username) async {
  if (username == null || username.isEmpty) return null;

  String? extractFirstSvg(String html) {
    final re = RegExp(r'(<svg[^>]*>[\s\S]*?<\/svg>)', caseSensitive: false);
    final m = re.firstMatch(html);
    return m?.group(1);
  }

  String sanitizeContributionsSvg(String svg) {
    // GitHub's SVG often includes dark text labels that are unreadable on dark background.
    // Keep only the grid; remove <text> and <title> elements.
    var s = svg;
    s = s.replaceAll(RegExp(r'<text[^>]*>[\s\S]*?<\/text>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<title[^>]*>[\s\S]*?<\/title>', caseSensitive: false), '');
    return s;
  }

  try {
    // Avatar
    String? avatarUrl;
    final userRes = await http.get(
      Uri.https('api.github.com', '/users/$username'),
      headers: githubApiHeaders(),
    );
    if (userRes.statusCode == 200) {
      final decoded = jsonDecode(userRes.body);
      if (decoded is Map) {
        avatarUrl = (decoded['avatar_url'] ?? '').toString();
        if (avatarUrl.isEmpty) avatarUrl = null;
      }
    }

    // Aktivita SVG (contributions calendar)
    // Prefer GitHub official public endpoint to avoid relying on third-party services.
    String? svg;
    final ghSvgRes = await http.get(
      Uri.parse('https://github.com/users/$username/contributions'),
      headers: const {
        'Accept': 'image/svg+xml,text/html;q=0.9,*/*;q=0.8',
        'User-Agent': 'gitmit',
      },
    );
    if (ghSvgRes.statusCode == 200) {
      final body = ghSvgRes.body.trim();
      if (body.startsWith('<svg')) {
        svg = sanitizeContributionsSvg(body);
      } else {
        final extracted = extractFirstSvg(body);
        if (extracted != null && extracted.isNotEmpty) {
          svg = sanitizeContributionsSvg(extracted);
        }
      }
    }

    // Fallback: legacy third-party API if GitHub endpoint changes or is blocked.
    if (svg == null || svg.isEmpty) {
      final svgRes = await http.get(
        Uri.parse('https://github-contributions-api.jogruber.de/v4/$username?format=svg'),
      );
      if (svgRes.statusCode == 200 && svgRes.body.trim().startsWith('<svg')) {
        svg = sanitizeContributionsSvg(svgRes.body);
      }
    }

    // Top repozitáře (podle hvězdiček)
    final repoRes = await http.get(
      Uri.https('api.github.com', '/users/$username/repos', {
        'sort': 'stars',
        'per_page': '5',
      }),
      headers: githubApiHeaders(),
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
      'contributions': svg,
      'topRepos': topRepos,
    };
  } catch (_) {
    return null;
  }
}

void _openRepoUrl(BuildContext context, String? url) {
  if (url == null || url.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Otevři v prohlížeči: $url')),
  );
}

class _SvgWidget extends StatelessWidget {
  final String svg;
  const _SvgWidget({required this.svg});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SvgPicture.string(
              svg,
              height: 120,
              fit: BoxFit.none,
              alignment: Alignment.centerLeft,
            ),
          ),
        ),
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

  @override
  void dispose() {
    _verifiedReason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(child: Text('Nepřihlášen.'));
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
            final activitySvg = gh?['contributions'] as String?;
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
                  const Divider(height: 32),
                  const Text('Aktivita na GitHubu', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (activitySvg != null && activitySvg.trim().isNotEmpty) _SvgWidget(svg: activitySvg),
                  if (snap.connectionState == ConnectionState.done && (activitySvg == null || activitySvg.trim().isEmpty))
                    const Text('Aktivitu se nepodařilo načíst.', style: TextStyle(color: Colors.white60)),
                  const SizedBox(height: 24),
                  const Text('Top repozitáře', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
                  const Text('Ověření', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  StreamBuilder<DatabaseEvent>(
                    stream: reqRef.onValue,
                    builder: (context, reqSnap) {
                      final v = reqSnap.data?.snapshot.value;
                      final req = (v is Map) ? v : null;
                      final status = req?['status']?.toString();
                      final statusText = _statusText(status);
                      final pending = status == 'pending';
                      final approved = status == 'approved';
                      final declined = status == 'declined';

                      if (approved) {
                        return Text('Stav: $statusText');
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Stav: $statusText'),
                          const SizedBox(height: 8),
                          if (!pending && !declined) ...[
                            TextField(
                              controller: _verifiedReason,
                              minLines: 2,
                              maxLines: 5,
                              decoration: const InputDecoration(
                                labelText: 'Proč chceš ověření?'
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
                                            const SnackBar(content: Text('Žádost odeslána, čeká se na moderátora.')),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _sending = false);
                                      }
                                    },
                              child: const Text('Získat ověření'),
                            ),
                          ] else if (pending) ...[
                            const Text('Žádost byla odeslána. Odpověď najdeš v Chatech v položce „Ověření účtu“.'),
                          ] else if (declined) ...[
                            const Text('Žádost byla zamítnuta. Můžeš poslat novou žádost.'),
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
                                            const SnackBar(content: Text('Žádost odeslána, čeká se na moderátora.')),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _sending = false);
                                      }
                                    },
                              child: const Text('Poslat novou žádost'),
                            ),
                          ],
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 24),
                  const Text('Dárky', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Container(
                    height: 60,
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const Text('Dárky (brzy)'),
                  ),
                  const SizedBox(height: 24),
                  const Text('Aktivita v GitMitu', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Container(
                    height: 60,
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const Text('Aktivita v GitMitu (brzy)'),
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
                        tooltip: 'Profil',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await Navigator.of(this.context).push(
                            MaterialPageRoute(builder: (_) => _UserProfilePage(login: otherLogin, avatarUrl: avatarUrl)),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Tenhle uživatel zatím nemá účet v GitMitu (není v databázi), takže nejde poslat DM invajt.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
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

    final acceptedSnap = await rtdb().ref('dmContacts/${current.uid}/$otherLower').get();
    final accepted = acceptedSnap.exists && acceptedSnap.value != false;
    if (accepted) {
      widget.onStartChat(login: otherLogin, avatarUrl: avatarUrl);
      return;
    }

    if (!mounted) return;
    final msgCtrl = TextEditingController();
    bool sending = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> sendInvite() async {
              if (sending) return;
              var didPop = false;
              setSheetState(() => sending = true);
              try {
                final myLogin = await _myGithubUsernameFromRtdb(current.uid);
                if (myLogin == null || myLogin.trim().isEmpty) {
                  throw Exception('Nepodařilo se zjistit tvůj GitHub username.');
                }
                final myAvatar = await _myAvatarUrlFromRtdb(current.uid);
                await _sendDmRequestCore(
                  myUid: current.uid,
                  myLogin: myLogin,
                  myAvatarUrl: myAvatar,
                  otherUid: otherUid,
                  otherLogin: otherLogin,
                  otherAvatarUrl: avatarUrl,
                  messageText: msgCtrl.text,
                );
                if (!mounted) return;
                if (context.mounted) {
                  didPop = true;
                  Navigator.of(context).pop();
                }
                // Switch tabs only after the sheet is fully closed.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  widget.onStartChat(login: otherLogin, avatarUrl: avatarUrl);
                });
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
                }
              } finally {
                if (!didPop && context.mounted) setSheetState(() => sending = false);
              }
            }

            final bottomInset = MediaQuery.of(context).viewInsets.bottom;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
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
                          tooltip: 'Profil + fingerprint',
                          icon: const Icon(Icons.fingerprint),
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await Navigator.of(this.context).push(
                              MaterialPageRoute(builder: (_) => _UserProfilePage(login: otherLogin, avatarUrl: avatarUrl)),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Pošli invajt. Můžeš přidat jednu zprávu – odešle se šifrovaně a chat se odemkne až po přijetí.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: msgCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Zpráva (volitelné)',
                        hintText: 'Napiš jednu zprávu…',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: sending ? null : sendInvite,
                            child: Text(sending ? 'Odesílám…' : 'Poslat invajt'),
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
      },
    );
    msgCtrl.dispose();
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
            decoration: const InputDecoration(
              labelText: 'Hledat na GitHubu',
              prefixText: '@',
              helperText: 'Stiskni Enter pro hledání (šetří to GitHub API).',
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
                  label: Text(_loading ? 'Hledám…' : 'Hledat'),
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
                        const Text('Kamarádi', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                        const Text('Doporučené', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        const Text(
                          'Lidi z tvých skupin (podle počtu společných skupin).',
                          style: TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 8),
                        ..._recommended.map(
                          (u) => _recommendedTile(
                            u,
                            subtitle: 'Společné skupiny: ${u.score}',
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
                        const Text('Lokálně', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                      const Text('GitHub', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      if (_lastSearchedQuery.toLowerCase() != qLower || _results.isEmpty)
                        const Text('Stiskni Enter nebo tlačítko "Hledat" pro dotaz na GitHub.'),
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

class _ChatsTabState extends State<_ChatsTab> {
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
        title: const Text('Otisky klíčů (anti‑MITM)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Porovnejte fingerprint přes jiný kanál (např. osobně / Signal).'),
            if (changed == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Pozor: fingerprint protějšku se změnil od minula. Může jít o reinstalaci, nebo MITM.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Text('Protějšek (@$peerLogin):', style: const TextStyle(fontWeight: FontWeight.bold)),
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
              const Text('Není dostupné (uživatel ještě nezveřejnil klíč).'),
            const SizedBox(height: 12),
            const Text('Můj klíč:', style: TextStyle(fontWeight: FontWeight.bold)),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Zavřít')),
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
      });
      return true;
    }
    if (_activeGroupId != null) {
      setState(() => _activeGroupId = null);
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
    _activeLogin = widget.initialOpenLogin;
    _activeAvatarUrl = widget.initialOpenAvatarUrl;
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
      });
      return;
    }

    if (widget.openChatToken != oldWidget.openChatToken && widget.initialOpenLogin != null) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
      });
      return;
    }

    if (widget.initialOpenLogin != null && widget.initialOpenLogin != oldWidget.initialOpenLogin) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
        _activeOtherUid = null;
        _activeOtherUidLoginLower = null;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
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

  Future<String?> _ensureActiveOtherUid() async {
    final login = _activeLogin;
    if (login == null || login.trim().isEmpty) return null;
    final loginLower = login.trim().toLowerCase();
    if (_activeOtherUid != null && _activeOtherUidLoginLower == loginLower) {
      return _activeOtherUid;
    }
    final uid = await _lookupUidForLoginLower(loginLower);
    if (!mounted) return uid;
    setState(() {
      _activeOtherUid = uid;
      _activeOtherUidLoginLower = loginLower;
    });
    return uid;
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
              const ListTile(
                title: Text('Přesunout do složky', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              ListTile(
                leading: const Icon(Icons.inbox_outlined),
                title: const Text('Priváty'),
                onTap: () => Navigator.of(context).pop(null),
              ),
              const Divider(height: 1),
              ...folders.map((f) {
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f['name'] ?? 'Složka'),
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
    final cs = Theme.of(context).colorScheme;
    switch (key) {
      case 'surfaceVariant':
        return cs.surfaceVariant;
      case 'primaryContainer':
        return cs.primaryContainer;
      case 'secondaryContainer':
        return cs.secondaryContainer;
      case 'surface':
      default:
        return cs.surface;
    }
  }

  Color _bubbleTextColor(BuildContext context, String key) {
    final cs = Theme.of(context).colorScheme;
    switch (key) {
      case 'surfaceVariant':
        return cs.onSurfaceVariant;
      case 'primaryContainer':
        return cs.onPrimaryContainer;
      case 'secondaryContainer':
        return cs.onSecondaryContainer;
      case 'surface':
      default:
        return cs.onSurface;
    }
  }

  Future<void> _send() async {
    final current = FirebaseAuth.instance.currentUser;
    final login = _activeLogin;
    final text = _messageController.text.trim();
    if (current == null || login == null || text.isEmpty) return;

    final otherUid = await _ensureActiveOtherUid();
    if (otherUid == null || otherUid.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('E2EE: nelze zjistit UID uživatele.')),
        );
      }
      return;
    }

    try {
      await E2ee.publishMyPublicKey(uid: current.uid);
    } catch (_) {
      // best-effort
    }

    final myLogin = await _myGithubUsername(current.uid);
    if (myLogin == null || myLogin.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nelze zjistit tvůj GitHub username.')),
        );
      }
      return;
    }

    final otherLoginLower = login.trim().toLowerCase();
    final accepted = await _isDmAccepted(myUid: current.uid, otherLoginLower: otherLoginLower);
    if (!accepted) {
      try {
        await _sendDmRequest(
          myUid: current.uid,
          myLogin: myLogin,
          otherUid: otherUid,
          otherLogin: login,
          messageText: text,
        );
        _messageController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Žádost o chat byla odeslána.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Nelze odeslat žádost: $e')),
          );
        }
      }
      return;
    }

    Map<String, Object?> encrypted;
    try {
      encrypted = await E2ee.encryptForUser(otherUid: otherUid, plaintext: text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('E2EE: šifrování selhalo: $e')),
        );
      }
      return;
    }

    _messageController.clear();
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
      setState(() => _decryptedCache[key] = text);
      PlaintextCache.putDm(otherLoginLower: otherLoginLower, messageKey: key, plaintext: text);
    }

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

  Future<void> _showReactionsMenu({required String login, required String messageKey}) async {
    if (!widget.settings.reactionsEnabled) return;
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        const items = ['👍', '❤️', '😂', '😮', '😢'];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: items
                  .map(
                    (e) => TextButton(
                      onPressed: () => Navigator.of(context).pop(e),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
      },
    );
    if (emoji == null) return;
    await _reactToMessage(login: login, messageKey: messageKey, emoji: emoji);
  }

  Future<void> _openUserProfile({required String login, required String avatarUrl}) async {
    final res = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _UserProfilePage(login: login, avatarUrl: avatarUrl),
      ),
    );

    if (!mounted) return;
    if (res == 'deleted_chat_for_me' || res == 'deleted_chat_for_both') {
      setState(() {
        _activeLogin = null;
        _activeAvatarUrl = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat byl smazán.')),
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
      return const Center(child: Text('Nepřihlášen.'));
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
                stream: isModerator ? allVerifyReqsRef.onValue : const Stream.empty(),
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
                              title: const Text('Ověření účtu'),
                              subtitle: Text(_statusText(myStatus)),
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
                                    title: const Text('Pozvánky do skupin'),
                                    subtitle: Text('Čeká: ${invites.length}'),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: acceptAll,
                                            child: const Text('Přijmout všechny'),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: declineAll,
                                            child: const Text('Odmítnout všechny'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ...invites.map((inv) {
                                    final key = (inv['__key'] ?? '').toString();
                                    final groupTitle = (inv['groupTitle'] ?? 'Skupina').toString();
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
                                      subtitle: invitedBy.isNotEmpty ? Text('Pozval: @$invitedBy') : (groupId.isNotEmpty ? Text(groupId) : null),
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
                                    title: const Text('Žádosti do skupin'),
                                    subtitle: Text('Čeká: ${items.length}'),
                                  ),
                                  ...items.map((item) {
                                    final groupId = (item['groupId'] ?? '').toString();
                                    final targetLogin = (item['targetLogin'] ?? '').toString();
                                    final requestedBy = (item['requestedByGithub'] ?? '').toString();
                                    return StreamBuilder<DatabaseEvent>(
                                      stream: (groupId.isEmpty) ? const Stream.empty() : rtdb().ref('groups/$groupId').onValue,
                                      builder: (context, gSnap) {
                                        final gv = gSnap.data?.snapshot.value;
                                        final gm = (gv is Map) ? gv : null;
                                        if (gm == null) return const SizedBox.shrink();
                                        final title = (gm['title'] ?? '').toString();
                                        return ListTile(
                                          leading: const Icon(Icons.group),
                                          title: Text(title),
                                          subtitle: Text(
                                            'Přidat: @${targetLogin.isEmpty ? 'uživatel' : targetLogin}${requestedBy.isNotEmpty ? ' • od @$requestedBy' : ''}',
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
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
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
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Chyba: $e')));
                                  }
                                }
                              }

                              return Column(
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.mail_lock_outlined),
                                    title: const Text('Žádosti o chat'),
                                    subtitle: Text('Čeká: ${items.length}'),
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
                                      subtitle: hasEncryptedText ? const Text('Zpráva: 🔒 (šifrovaně)') : const Text('Invajt do privátu'),
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
                                  label: const Text('Priváty'),
                                  selected: _overviewMode == 0,
                                  onSelected: (_) => setState(() {
                                    _overviewMode = 0;
                                    _activeFolderId = null;
                                  }),
                                ),
                                ChoiceChip(
                                  label: const Text('Skupiny'),
                                  selected: _overviewMode == 1,
                                  onSelected: (_) => setState(() {
                                    _overviewMode = 1;
                                    _activeFolderId = null;
                                  }),
                                ),
                                ChoiceChip(
                                  label: const Text('Složky'),
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
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                              child: Text('Žádosti o ověření', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            if (pendingReqs.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                child: Text('Žádné čekající žádosti.'),
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
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Text('Zatím žádné chaty. Napiš někomu zprávu.'),
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
                              title: const Text('Vytvořit skupinu'),
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
                                    const SnackBar(content: Text('Skupina vytvořena.')),
                                  );
                                }
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.qr_code_scanner),
                              title: const Text('Připojit se přes link / QR'),
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
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    child: Text('Zatím nejsi v žádné skupině.'),
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
                                                    title: const Text('Nová složka'),
                                                    content: TextField(
                                                      controller: ctrl,
                                                      decoration: const InputDecoration(labelText: 'Název'),
                                                    ),
                                                    actions: [
                                                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Zrušit')),
                                                      FilledButton(
                                                        onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
                                                        child: const Text('Vytvořit'),
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
                                                  title: const Text('Smazat složku?'),
                                                  content: Text('Složka "$folderName" se smaže a všechny položky se vrátí zpět do privátů/skupin.'),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Zrušit')),
                                                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Smazat')),
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
                                                          title: const Text('Přidat privát'),
                                                          onTap: () => Navigator.of(context).pop('chat'),
                                                        ),
                                                        ListTile(
                                                          leading: const Icon(Icons.group_add),
                                                          title: const Text('Přidat skupinu'),
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
                                                          const ListTile(
                                                            title: Text('Vyber privát', style: TextStyle(fontWeight: FontWeight.w700)),
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
                                                          const ListTile(
                                                            title: Text('Vyber skupinu', style: TextStyle(fontWeight: FontWeight.w700)),
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
                                                  ? 'Priváty'
                                                  : (folders.firstWhere(
                                                          (e) => e['id'] == fid,
                                                          orElse: () => {'name': 'Složka'},
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
                                                          ? 'Chaty: ${filteredChats.length}'
                                                          : 'Chaty: ${filteredChats.length} • Skupiny: ${filteredGroups.length}',
                                                    ),
                                                    trailing: (fid == '__privates__')
                                                        ? null
                                                        : Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              IconButton(
                                                                tooltip: 'Přidat',
                                                                icon: const Icon(Icons.add),
                                                                onPressed: () {
                                                                  _hapticSelect();
                                                                  addToFolder(fid);
                                                                },
                                                              ),
                                                              IconButton(
                                                                tooltip: 'Smazat složku',
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
                                                    const Padding(
                                                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                      child: Text('Ve složce zatím nic není.'),
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
                                                    const Padding(
                                                      padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                                                      child: Align(
                                                        alignment: Alignment.centerLeft,
                                                        child: Text('Skupiny', style: TextStyle(fontWeight: FontWeight.w700)),
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
                                                    title: const Text('Vytvořit složku'),
                                                    onTap: () {
                                                      _hapticSelect();
                                                      createFolder();
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(Icons.inbox_outlined),
                                                    title: const Text('Priváty'),
                                                    subtitle: Text('Chaty: ${countChatsForFolder(null)}'),
                                                    onTap: () {
                                                      _hapticSelect();
                                                      setState(() => _activeFolderId = '__privates__');
                                                    },
                                                  ),
                                                  const Divider(height: 1),
                                                  if (folders.isEmpty)
                                                    const Padding(
                                                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                                      child: Text('Zatím nemáš žádné složky.'),
                                                    )
                                                  else
                                                    ...folders.map((f) {
                                                      final fid = (f['id'] ?? '').toString();
                                                      final name = (f['name'] ?? 'Složka').toString();
                                                      return ListTile(
                                                        leading: const Icon(Icons.folder_outlined),
                                                        title: Text(name),
                                                        subtitle: Text('Chaty: ${countChatsForFolder(fid)} • Skupiny: ${countGroupsForFolder(fid)}'),
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
                    subtitle: Text(_statusText(status)),
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
                              child: const Text('Accept'),
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
                              child: const Text('Decline'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile(
                      value: _moderatorAnonymous,
                      onChanged: (v) => setState(() => _moderatorAnonymous = v),
                      title: const Text('Odpovídat anonymně'),
                      subtitle: Text(
                        _moderatorAnonymous
                            ? 'U druhé strany bude „Moderátor“'
                            : 'U druhé strany bude @$myGithub',
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
                          return const Center(child: Text('Zatím žádné zprávy.'));
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
                                ? 'Systém'
                                : (from == 'moderator'
                                    ? (anonymous ? 'Moderátor' : '@$moderatorGithub')
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
                            decoration: const InputDecoration(labelText: 'Zpráva'),
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

                  Future<void> showAdminMenu(String key) async {
                    if (!isAdmin) return;
                    final action = await showModalBottomSheet<String>(
                      context: context,
                      builder: (context) {
                        return SafeArea(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.delete_outline),
                                title: const Text('Smazat zprávu'),
                                onTap: () => Navigator.of(context).pop('delete'),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                    if (action == 'delete') {
                      await deleteMessage(key);
                    }
                  }

                  Future<void> send() async {
                    final text = _messageController.text.trim();
                    if (text.isEmpty || !canSend) return;
                    _messageController.clear();

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

                    // Prefer stronger v2 group encryption (Signal-like sender key) when possible.
                    Map<String, Object?>? encrypted;
                    try {
                      encrypted = await E2ee.encryptForGroupSignalLike(groupId: groupId, myUid: current.uid, plaintext: text);
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
                              const SnackBar(content: Text('E2EE: skupina není připravená (chybí klíč).')),
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
                              SnackBar(content: Text('E2EE: nelze nastavit skupinový klíč: $e')),
                            );
                          }
                          return;
                        }
                      }

                      if (gk == null) return;
                      _groupKeyCache[groupId] = gk;

                      try {
                        encrypted = await E2ee.encryptForGroup(groupKey: gk, plaintext: text);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('E2EE: šifrování selhalo: $e')),
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
                      if (expiresAt != null) 'expiresAt': expiresAt,
                      if (burnAfterRead) 'burnAfterRead': true,
                    });

                    // Show our own message immediately (avoid "🔒 …" placeholder).
                    if (newKey != null && newKey.isNotEmpty && mounted) {
                      setState(() => _decryptedCache['g:$groupId:$newKey'] = text);
                      PlaintextCache.putGroup(groupId: groupId, messageKey: newKey, plaintext: text);
                    }
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
                        subtitle: Text(isAdmin ? 'Admin' : 'Member'),
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
                              return const Center(child: Text('Zatím žádné zprávy.'));
                            }
                            final now = DateTime.now().millisecondsSinceEpoch;
                            final items = <Map<String, dynamic>>[];
                            for (final e in v.entries) {
                              if (e.value is! Map) continue;
                              final m = Map<String, dynamic>.from(e.value as Map);
                              m['__key'] = e.key.toString();
                              final expiresAt = (m['expiresAt'] is int) ? m['expiresAt'] as int : null;
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

                                final mentioned = myGithubLower.isNotEmpty && text.toLowerCase().contains('@$myGithubLower');

                                final bubbleKey = isMe ? widget.settings.bubbleOutgoing : widget.settings.bubbleIncoming;
                                final color = _bubbleColor(context, bubbleKey);
                                final tcolor = _bubbleTextColor(context, bubbleKey);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Column(
                                    crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                    children: [
                                      if (fromGh.isNotEmpty)
                                        Text('@$fromGh', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                      GestureDetector(
                                        onLongPress: isAdmin ? () => showAdminMenu(key) : null,
                                        child: Align(
                                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                            decoration: BoxDecoration(
                                              color: color,
                                              borderRadius: BorderRadius.circular(widget.settings.bubbleRadius),
                                              border: mentioned ? Border.all(color: Colors.amber, width: 2) : null,
                                            ),
                                            child: Text(text, style: TextStyle(fontSize: widget.settings.chatTextSize, color: tcolor)),
                                          ),
                                        ),
                                      ),
                                    ],
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
                                decoration: const InputDecoration(labelText: 'Zpráva'),
                                enabled: canSend,
                                onSubmitted: (_) => send(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<int>(
                              tooltip: 'Ničení zpráv',
                              initialValue: _dmTtlMode,
                              onSelected: (v) => setState(() => _dmTtlMode = v),
                              itemBuilder: (context) => [
                                PopupMenuItem(value: 0, child: Text('Ničení: ${ttlLabel(0)}')),
                                PopupMenuItem(value: 1, child: Text('Ničení: ${ttlLabel(1)}')),
                                PopupMenuItem(value: 2, child: Text('Ničení: ${ttlLabel(2)}')),
                                PopupMenuItem(value: 3, child: Text('Ničení: ${ttlLabel(3)}')),
                                PopupMenuItem(value: 4, child: Text('Ničení: ${ttlLabel(4)}')),
                                PopupMenuItem(value: 5, child: Text('Ničení: ${ttlLabel(5)}')),
                              ],
                              icon: const Icon(Icons.timer_outlined),
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
    final blockedRef = rtdb().ref('blocked/${current.uid}/$loginLower');
    final dmContactRef = _dmContactRef(myUid: current.uid, otherLoginLower: loginLower);
    final dmReqRef = _dmRequestRef(myUid: current.uid, fromLoginLower: loginLower);

    final bg = widget.settings.wallpaperUrl.trim();
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
            final accepted = cSnap.data?.snapshot.exists == true && (cSnap.data?.snapshot.value != false);

            return StreamBuilder<DatabaseEvent>(
              stream: dmReqRef.onValue,
              builder: (context, rSnap) {
                final hasIncomingReq = rSnap.data?.snapshot.exists == true;

                Future<void> acceptReq() async {
                  try {
                    await _acceptDmRequest(myUid: current.uid, otherLogin: login);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Žádost přijata.')));
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nelze přijmout: $e')));
                  }
                }

                Future<void> rejectReq() async {
                  await dmReqRef.remove();
                  await rtdb().ref('savedChats/${current.uid}/$login').remove();
                  if (!mounted) return;
                  setState(() {
                    _activeLogin = null;
                    _activeAvatarUrl = null;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Žádost odmítnuta.')));
                }

                final lockedIncoming = hasIncomingReq && !accepted;
                final lockedOutgoing = !accepted && !hasIncomingReq;

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
                    tooltip: 'Fingerprint klíčů',
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
              onTap: () => _openUserProfile(login: login, avatarUrl: _activeAvatarUrl ?? ''),
            ),
            const Divider(height: 1),
            if (lockedIncoming)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: Theme.of(context).colorScheme.surface,
                child: Row(
                  children: [
                    const Expanded(child: Text('Žádost o chat. Přijmout?')),
                    TextButton(onPressed: acceptReq, child: const Text('Přijmout')),
                    TextButton(onPressed: rejectReq, child: const Text('Odmítnout')),
                  ],
                ),
              ),
            if (lockedOutgoing)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: Theme.of(context).colorScheme.surface,
                child: const Text('Chat čeká na potvrzení. První zpráva odešle žádost.'),
              ),
            StreamBuilder<DatabaseEvent>(
              stream: blockedRef.onValue,
              builder: (context, bSnap) {
                final blocked = bSnap.data?.snapshot.value == true;

                final canSend = accepted && !lockedIncoming;

                return Expanded(
                  child: Column(
                    children: [
                      if (blocked)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          color: Theme.of(context).colorScheme.surface,
                          child: const Text('Uživatel je zablokovaný. Zprávy nelze odesílat.'),
                        ),
                      Expanded(
                        child: Container(
                          decoration: bg.isEmpty
                              ? null
                              : BoxDecoration(
                                  image: DecorationImage(
                                    image: NetworkImage(bg),
                                    fit: BoxFit.cover,
                                    opacity: 0.35,
                                  ),
                                ),
                          child: StreamBuilder<DatabaseEvent>(
                            stream: messagesRef.onValue,
                            builder: (context, snapshot) {
                              final value = snapshot.data?.snapshot.value;
                              if (value is! Map) {
                                return const Center(child: Text('Napiš první zprávu.'));
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

                                  final mentioned = myGithubLower.isNotEmpty && text.toLowerCase().contains('@$myGithubLower');

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
                                    child: Column(
                                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                      children: [
                                        GestureDetector(
                                          onLongPress: blocked ? null : () => _showReactionsMenu(login: login, messageKey: key),
                                          child: Align(
                                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                              decoration: BoxDecoration(
                                                color: color,
                                                borderRadius: BorderRadius.circular(widget.settings.bubbleRadius),
                                                border: mentioned ? Border.all(color: Colors.amber, width: 2) : null,
                                              ),
                                              child: Text(text, style: TextStyle(fontSize: widget.settings.chatTextSize, color: tcolor)),
                                            ),
                                          ),
                                        ),
                                        if (reactionChips.isNotEmpty)
                                          Wrap(
                                            alignment: WrapAlignment.end,
                                            children: reactionChips,
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
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
                                decoration: const InputDecoration(labelText: 'Zpráva'),
                                enabled: !blocked && canSend,
                                onSubmitted: (!blocked && canSend) ? (_) => _send() : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<int>(
                              tooltip: 'Ničení zpráv',
                              initialValue: _dmTtlMode,
                              onSelected: (v) => setState(() => _dmTtlMode = v),
                              itemBuilder: (context) => [
                                PopupMenuItem(value: 0, child: Text('Ničení: ${ttlLabel(0)}')),
                                PopupMenuItem(value: 1, child: Text('Ničení: ${ttlLabel(1)}')),
                                PopupMenuItem(value: 2, child: Text('Ničení: ${ttlLabel(2)}')),
                                PopupMenuItem(value: 3, child: Text('Ničení: ${ttlLabel(3)}')),
                                PopupMenuItem(value: 4, child: Text('Ničení: ${ttlLabel(4)}')),
                                PopupMenuItem(value: 5, child: Text('Ničení: ${ttlLabel(5)}')),
                              ],
                              icon: const Icon(Icons.timer_outlined),
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
      },
    );
  }
}
