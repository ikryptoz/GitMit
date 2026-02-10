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
            onPressed: () => _confirmAndRun(
              title: 'Smazat chat u mě?',
              message: 'Smaže zprávy a přehled konverzace jen u tebe.',
              action: () => _deleteChatForMe(myUid: myUid),
            ),
            child: const Text('Smazat chat u mě'),
          ),
          const SizedBox(height: 12),

          FilledButton.tonal(
            onPressed: () => _confirmAndRun(
              title: 'Smazat chat u obou?',
              message: 'Pokusí se smazat konverzaci u obou uživatelů. Funguje jen pokud je druhá strana propojená v databázi.',
              action: () => _deleteChatForBoth(myUid: myUid),
            ),
            child: const Text('Smazat chat u obou'),
          ),
        ],
      ),
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
      _openChatToken++;
    });
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
          const _PlaceholderTab(text: 'Dashboard'),
          _ChatsTab(
            initialOpenLogin: _openChatLogin,
            initialOpenAvatarUrl: _openChatAvatarUrl,
            settings: settings,
            openChatToken: _openChatToken,
            overviewToken: _chatsOverviewToken,
          ),
          _ContactsTab(onStartChat: _openChat),
          _SettingsTab(onLogout: _logout, settings: settings),
          const _ProfileTab(),
        ];

        return Scaffold(
          appBar: AppBar(title: Text(_titles[_index])),
          body: pages[_index],
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _index,
            onTap: (value) {
              setState(() {
                if (value == 1 && _index != 1) {
                  // Ruční přepnutí na Chaty vždy otevře přehled.
                  _openChatLogin = null;
                  _openChatAvatarUrl = null;
                  _chatsOverviewToken++;
                }
                _index = value;
              });
            },
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
      },
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
          dotColor = Theme.of(context).colorScheme.outlineVariant;
        } else if (status == 'dnd') {
          dotColor = Theme.of(context).colorScheme.error;
        } else if (status == 'hidden') {
          dotColor = Theme.of(context).colorScheme.outlineVariant;
        } else {
          dotColor = online ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.outlineVariant;
        }
        final dotBorder = Theme.of(context).colorScheme.surface;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            baseAvatar,
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
            child: const Text('Přepnout GitHub účet'),
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
    // Neukládej chat jen klikem z kontaktů – uloží se až při první zprávě.
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
  const _ChatsTab({
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

    if (widget.overviewToken != oldWidget.overviewToken) {
      setState(() {
        _activeLogin = null;
        _activeAvatarUrl = null;
        _activeVerifiedUid = null;
        _activeVerifiedGithub = null;
      });
      return;
    }

    if (widget.openChatToken != oldWidget.openChatToken && widget.initialOpenLogin != null) {
      setState(() {
        _activeLogin = widget.initialOpenLogin;
        _activeAvatarUrl = widget.initialOpenAvatarUrl;
      });
      return;
    }

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
    final expiresAt = (widget.settings.autoDeleteSeconds > 0)
        ? DateTime.now().millisecondsSinceEpoch + (widget.settings.autoDeleteSeconds * 1000)
        : null;
    await rtdb().ref('messages/${current.uid}/$login').push().set({
      'text': text,
      'fromUid': current.uid,
      'createdAt': ServerValue.timestamp,
      if (expiresAt != null) 'expiresAt': expiresAt,
    });

    // Chat se "uloží" až po první zprávě.
    await rtdb().ref('savedChats/${current.uid}/$login').update({
      'login': login,
      if (_activeAvatarUrl != null && _activeAvatarUrl!.isNotEmpty) 'avatarUrl': _activeAvatarUrl,
      'lastMessageText': text,
      'lastMessageAt': ServerValue.timestamp,
      'savedAt': ServerValue.timestamp,
    });
  }

  Future<void> _reactToMessage({required String login, required String messageKey, required String emoji}) async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) return;
    await rtdb().ref('messages/${current.uid}/$login/$messageKey/reactions/$emoji/${current.uid}').set(true);
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

  void _openUserProfile({required String login, required String avatarUrl}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _UserProfilePage(login: login, avatarUrl: avatarUrl),
      ),
    );
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
      final chatsMetaRef = rtdb().ref('savedChats/${current.uid}');
      final chatsMessagesRef = rtdb().ref('messages/${current.uid}');
      final blockedRef = rtdb().ref('blocked/${current.uid}');
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

                                  rows.add({
                                    'login': login,
                                    'avatarUrl': avatarUrl,
                                    'lastAt': lastAt,
                                    'lastText': lastText,
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
                              return ListTile(
                                leading: _ChatLoginAvatar(login: login, avatarUrl: avatarUrl, radius: 20),
                                title: Text('@$login'),
                                subtitle: lastText.isNotEmpty
                                    ? Text(lastText, maxLines: 1, overflow: TextOverflow.ellipsis)
                                    : null,
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

    final login = _activeLogin!;
    final messagesRef = rtdb().ref('messages/${current.uid}/$login');
    final loginLower = login.trim().toLowerCase();
    final blockedRef = rtdb().ref('blocked/${current.uid}/$loginLower');

    Color bubbleColor(BuildContext context, String key) {
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

    Color bubbleTextColor(BuildContext context, String key) {
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

    final bg = widget.settings.wallpaperUrl.trim();
    return Column(
      children: [
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _activeLogin = null),
          ),
          title: Text('@$login'),
          trailing: _ChatLoginAvatar(
            login: login,
            avatarUrl: _activeAvatarUrl ?? '',
            radius: 18,
          ),
          onTap: () => _openUserProfile(login: login, avatarUrl: _activeAvatarUrl ?? ''),
        ),
        const Divider(height: 1),
        StreamBuilder<DatabaseEvent>(
          stream: blockedRef.onValue,
          builder: (context, bSnap) {
            final blocked = bSnap.data?.snapshot.value == true;

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
                            if (expiresAt != null && expiresAt <= now) continue;
                            items.add(msg);
                          }

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
                              final key = (m['__key'] ?? '').toString();
                              final text = (m['text'] ?? '').toString();
                              final fromUid = (m['fromUid'] ?? '').toString();
                              final isMe = fromUid == current.uid;

                              final bubbleKey = isMe ? widget.settings.bubbleOutgoing : widget.settings.bubbleIncoming;
                              final color = bubbleColor(context, bubbleKey);
                              final tcolor = bubbleTextColor(context, bubbleKey);

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
                            enabled: !blocked,
                            onSubmitted: blocked ? null : (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: blocked ? null : _send,
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
  }
}
