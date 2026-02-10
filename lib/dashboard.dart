import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/github_api.dart';
import 'package:gitmit/rtdb.dart';

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

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(child: Text('Nepřihlášen.'));
    }

    final ref = rtdb().ref('users/${user.uid}');

    return StreamBuilder<DatabaseEvent>(
      stream: ref.onValue,
      builder: (context, snapshot) {
        final data = snapshot.data?.snapshot.value;
        final map = (data is Map) ? data : null;

        final githubUsername = map?['githubUsername']?.toString();
        final githubAt = (githubUsername != null && githubUsername.isNotEmpty)
            ? '@$githubUsername'
            : '@(není nastaveno)';

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                githubAt,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text('UID: ${user.uid}'),
              const SizedBox(height: 8),
              Text('Email: ${user.email ?? "-"}'),
            ],
          ),
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

  @override
  Widget build(BuildContext context) {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      return const Center(child: Text('Nepřihlášen.'));
    }

    if (_activeLogin == null) {
      final ref = rtdb().ref('savedChats/${current.uid}');
      return StreamBuilder<DatabaseEvent>(
        stream: ref.onValue,
        builder: (context, snapshot) {
          final value = snapshot.data?.snapshot.value;
          final map = (value is Map) ? value : null;
          final entries = map?.entries.toList() ?? const [];

          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
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
