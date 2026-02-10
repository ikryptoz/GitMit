import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gitmit/github_api.dart';
import 'package:gitmit/rtdb.dart';
import 'package:http/http.dart' as http;

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _index = 0;
  String? _openChatLogin;
  String? _openChatAvatarUrl;

  static const _titles = <String>[
    'Dashboard',
    'Chaty',
    'Kontakty',
    'Nastavení',
    'Profil',
  ];

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  void _openChat({required String login, required String avatarUrl}) {
    setState(() {
      _index = 1; // Chaty tab
      _openChatLogin = login;
      _openChatAvatarUrl = avatarUrl;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const _PlaceholderTab(text: 'Dashboard'),
      _ChatsTab(
        initialOpenLogin: _openChatLogin,
        initialOpenAvatarUrl: _openChatAvatarUrl,
      ),
      _ContactsTab(onStartChat: _openChat),
      _SettingsTab(onLogout: _logout),
      const _ProfileTab(),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (value) => setState(() => _index = value),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline), label: 'Chaty'),
          BottomNavigationBarItem(icon: Icon(Icons.people_outline), label: 'Kontakty'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'Nastavení'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Profil'),
        ],
      ),
    );
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
  const _SettingsTab({required this.onLogout});
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        onPressed: onLogout,
        child: const Text('Odhlásit se'),
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
  final flag = userMap?['isModerator'] == true;
  final gh = userMap?['githubUsername']?.toString() ?? '';
  return flag || gh.toLowerCase() == 'ikryptoz';
}

Future<Map<String, dynamic>?> _fetchGithubProfileData(String? username) async {
  if (username == null || username.isEmpty) return null;
  try {
    // Avatar
    String? avatarUrl;
    final userRes = await http.get(
      Uri.https('api.github.com', '/users/$username'),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'gitmit',
      },
    );
    if (userRes.statusCode == 200) {
      final decoded = jsonDecode(userRes.body);
      if (decoded is Map) {
        avatarUrl = (decoded['avatar_url'] ?? '').toString();
        if (avatarUrl.isEmpty) avatarUrl = null;
      }
    }

    // Aktivita SVG (contributions calendar)
    final svgRes = await http.get(
      Uri.parse('https://github-contributions-api.jogruber.de/v4/$username?format=svg'),
    );
    final svg = svgRes.statusCode == 200 ? svgRes.body : null;

    // Top repozitáře (podle hvězdiček)
    final repoRes = await http.get(
      Uri.https('api.github.com', '/users/$username/repos', {
        'sort': 'stars',
        'per_page': '5',
      }),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'gitmit',
      },
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
    return SvgPicture.string(svg, fit: BoxFit.contain);
  }
}

class _ProfileTab extends StatefulWidget {
  const _ProfileTab();

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  final _verifiedReason = TextEditingController();
  bool _sending = false;

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

        return FutureBuilder<Map<String, dynamic>?>(
          future: _fetchGithubProfileData(githubUsername),
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
                  if (avatar != null && avatar.isNotEmpty)
                    CircleAvatar(radius: 48, backgroundImage: NetworkImage(avatar))
                  else
                    const CircleAvatar(radius: 48, child: Icon(Icons.person, size: 48)),
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
                  if (activitySvg != null)
                    SizedBox(height: 120, child: _SvgWidget(svg: activitySvg))
                  else
                    const Text('Načítání aktivity...'),
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
                          leading: const Icon(Icons.book, color: Colors.green),
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
  const _ContactsTab({required this.onStartChat});
  final void Function({required String login, required String avatarUrl}) onStartChat;

  @override
  State<_ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<_ContactsTab> {
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

  Future<void> _addToChats(GithubUser user) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;

    final savedRef = rtdb().ref('savedChats/${current.uid}/${user.login}');
    await savedRef.set({
      'login': user.login,
      'avatarUrl': user.avatarUrl,
      'savedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    widget.onStartChat(login: user.login, avatarUrl: user.avatarUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _controller,
            onChanged: _onChanged,
            decoration: const InputDecoration(
              labelText: 'Hledat na GitHubu',
              prefixText: '@',
            ),
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 12),
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
                  onTap: () => _addToChats(u),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatsTab extends StatefulWidget {
  const _ChatsTab({required this.initialOpenLogin, required this.initialOpenAvatarUrl});
  final String? initialOpenLogin;
  final String? initialOpenAvatarUrl;

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  String? _activeLogin;
  String? _activeAvatarUrl;
  String? _activeVerifiedUid;
  String? _activeVerifiedGithub;
  bool _moderatorAnonymous = true;
  final _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _activeLogin = widget.initialOpenLogin;
    _activeAvatarUrl = widget.initialOpenAvatarUrl;
  }

  @override
  void didUpdateWidget(covariant _ChatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialOpenLogin != null && widget.initialOpenLogin != oldWidget.initialOpenLogin) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
      });
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final current = FirebaseAuth.instance.currentUser;
    final login = _activeLogin;
    final text = _messageController.text.trim();
    if (current == null || login == null || text.isEmpty) return;

    _messageController.clear();
    await rtdb().ref('messages/${current.uid}/$login').push().set({
      'text': text,
      'fromUid': current.uid,
      'createdAt': ServerValue.timestamp,
    });
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

    // Seznam chatů + ověření
    if (_activeLogin == null && _activeVerifiedUid == null) {
      final chatsRef = rtdb().ref('savedChats/${current.uid}');
      final myVerifyReqRef = _verifiedRequestRef(current.uid);
      final allVerifyReqsRef = rtdb().ref('verifiedRequests');

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
                    stream: chatsRef.onValue,
                    builder: (context, snapshot) {
                      final value = snapshot.data?.snapshot.value;
                      final map = (value is Map) ? value : null;
                      final entries = map?.entries.toList() ?? const [];

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
                                  leading: CircleAvatar(
                                    backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
                                  ),
                                  title: Text('@$gh'),
                                  subtitle: Text(reason, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () {
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

                          ...entries.map((e) {
                            final login = e.key.toString();
                            final data = (e.value is Map) ? (e.value as Map) : null;
                            final avatarUrl = data?['avatarUrl']?.toString() ?? '';
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                              ),
                              title: Text('@$login'),
                              onTap: () {
                                setState(() {
                                  _activeLogin = login;
                                  _activeAvatarUrl = avatarUrl;
                                });
                              },
                            );
                          }),
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
                      subtitle: Text(_moderatorAnonymous ? 'U druhé strany bude „Moderátor“' : 'U druhé strany bude @ikryptoz'),
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

    final login = _activeLogin!;
    final messagesRef = rtdb().ref('messages/${current.uid}/$login');
    return Column(
      children: [
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _activeLogin = null),
          ),
          title: Text('@$login'),
          trailing: CircleAvatar(
            backgroundImage:
                (_activeAvatarUrl != null && _activeAvatarUrl!.isNotEmpty) ? NetworkImage(_activeAvatarUrl!) : null,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: messagesRef.onValue,
            builder: (context, snapshot) {
              final value = snapshot.data?.snapshot.value;
              if (value is! Map) {
                return const Center(child: Text('Napiš první zprávu.'));
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(text),
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
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: _send,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
