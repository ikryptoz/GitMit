import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/rtdb.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  int _index = 0;

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

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const _PlaceholderTab(text: 'Dashboard'),
      const _PlaceholderTab(text: 'Chaty'),
      const _PlaceholderTab(text: 'Kontakty'),
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
