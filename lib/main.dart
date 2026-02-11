import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/register.dart';
import 'package:gitmit/dashboard.dart';
import 'package:gitmit/notifications_service.dart';
import 'package:gitmit/deep_links.dart';
import 'package:gitmit/rtdb.dart';
import 'package:gitmit/github_api.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AppNotifications.initialize();
  await DeepLinks.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    // Barvy z palety
    const gray5 = Color(0xFF232925); // #232925
    const gray6 = Color(0xFF101411); // #101411

    return MaterialApp(
      navigatorKey: DeepLinks.navigatorKey,
      title: 'GitMit',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: gray6,
        appBarTheme: const AppBarTheme(
          backgroundColor: gray5,
          foregroundColor: Colors.white,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.white),
        ),
        colorScheme: const ColorScheme(
          brightness: Brightness.dark,
          primary: Colors.white,
          onPrimary: Colors.black,
          secondary: Colors.white,
          onSecondary: Colors.black,
          error: Colors.redAccent,
          onError: Colors.white,
          background: gray6,
          onBackground: Colors.white,
          surface: gray5,
          onSurface: Colors.white,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: gray5,
          labelStyle: TextStyle(color: Colors.white),
          border: OutlineInputBorder(),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white, width: 2),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) return Colors.white24;
            return states.contains(MaterialState.selected) ? Colors.white : Colors.white70;
          }),
          trackColor: MaterialStateProperty.resolveWith((states) {
            if (states.contains(MaterialState.disabled)) return Colors.white10;
            return states.contains(MaterialState.selected) ? Colors.white38 : Colors.white24;
          }),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: MaterialStatePropertyAll(Colors.white),
            foregroundColor: MaterialStatePropertyAll(Colors.black),
            textStyle: MaterialStatePropertyAll(TextStyle(fontWeight: FontWeight.bold)),
            shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            )),
            padding: MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            foregroundColor: const MaterialStatePropertyAll(Colors.white),
            side: MaterialStatePropertyAll(BorderSide(color: Colors.white38)),
            shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            )),
            padding: MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white),
        ),
      ),
      routes: {
        '/login': (context) => const LoginPage(),
        '/register': (context) => const RegisterPage(),
        '/dashboard': (context) => const DashboardPage(),
      },
      home: const AuthGate(),
    );
  }
}

// AuthGate widget rozhoduje, kam uživatele pustit podle přihlášení
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<User?>? _sub;
  User? _user;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _sub = FirebaseAuth.instance.authStateChanges().listen((u) {
      _user = u;
      _ready = true;
      AppNotifications.setUser(u);
      DeepLinks.onAuthChanged(u);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final user = _user;
    if (user == null) return const LoginPage();

    final userRef = rtdb().ref('users/${user.uid}');
    return StreamBuilder<DatabaseEvent>(
      stream: userRef.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        final m = (v is Map) ? v : null;
        final githubUsername = (m?['githubUsername'] ?? '').toString().trim();
        final provider = (m?['provider'] ?? '').toString().trim();

        // If this is a GitHub user, wait until RTDB profile + username mapping exist.
        if (provider == 'github') {
          if (githubUsername.isEmpty) {
            return _AccountSetupScreen(
              title: 'Dokončuji registraci…',
              message: 'Načítám profil a připravuji účet.',
            );
          }
          final lower = githubUsername.toLowerCase();
          final mapRef = rtdb().ref('usernames/$lower');
          return StreamBuilder<DatabaseEvent>(
            stream: mapRef.onValue,
            builder: (context, mapSnap) {
              final mapped = mapSnap.data?.snapshot.value?.toString();

              if (mapped == null || mapped.isEmpty) {
                // Best-effort: fill mapping once it's known.
                mapRef.set(user.uid);
                return _AccountSetupScreen(
                  title: 'Dokončuji registraci…',
                  message: 'Nastavuji mapování @${githubUsername.toLowerCase()} → UID.',
                );
              }

              if (mapped != user.uid) {
                return _AccountSetupScreen(
                  title: 'Chyba registrace',
                  message: 'Username @$githubUsername už je spárovaný s jiným účtem. Odhlas se a zkus to znovu.',
                  showSignOut: true,
                );
              }

              return const DashboardPage();
            },
          );
        }

        // Non-GitHub users: proceed as before.
        return const DashboardPage();
      },
    );
  }
}

class _AccountSetupScreen extends StatelessWidget {
  const _AccountSetupScreen({
    required this.title,
    required this.message,
    this.showSignOut = false,
  });

  final String title;
  final String message;
  final bool showSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Text(message, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (!showSignOut) const CircularProgressIndicator(),
              if (showSignOut) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  child: const Text('Odhlásit'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _errorMessage;
  bool _loading = false;

  // ...existing code...

  Future<void> _loginWithGitHub() async {
    if (_loading) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final provider = GithubAuthProvider()..addScope('read:user');
      final credential = await FirebaseAuth.instance.signInWithProvider(provider);

      final user = credential.user;
      String? githubUsername = credential.additionalUserInfo?.username;
      String? avatarUrl;

      // Some platforms/providers occasionally return null additionalUserInfo.username.
      // In that case, resolve it using the GitHub OAuth access token.
      String? accessToken;
      final authCred = credential.credential;
      if (authCred is OAuthCredential) {
        accessToken = authCred.accessToken;
      }

      if ((githubUsername == null || githubUsername.isEmpty) && accessToken != null && accessToken.isNotEmpty) {
        final uri = Uri.https('api.github.com', '/user');
        final res = await http.get(
          uri,
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'token $accessToken',
          },
        );
        if (res.statusCode == 200) {
          final data = Map<String, dynamic>.from(jsonDecode(res.body));
          githubUsername = data['login']?.toString();
          avatarUrl = data['avatar_url']?.toString();
        }
      }

      // Fetch avatar if still missing (PAT fallback; might be rate-limited).
      if ((avatarUrl == null || avatarUrl.isEmpty) && githubUsername != null && githubUsername.isNotEmpty) {
        final uri = Uri.https('api.github.com', '/users/$githubUsername');
        final res = await http.get(uri, headers: githubApiHeaders());
        if (res.statusCode == 200) {
          final data = Map<String, dynamic>.from(jsonDecode(res.body));
          avatarUrl = data['avatar_url']?.toString();
        }
      }

      // Fallback: když GitHub API avatar nevrátí, vezmi photoURL z Firebase (pokud existuje)
      avatarUrl ??= user?.photoURL;

      if (user != null && githubUsername != null && githubUsername.isNotEmpty) {
        await rtdb().ref('users/${user.uid}').update({
          'githubUsername': githubUsername,
          'provider': 'github',
          'email': user.email,
          'lastLoginAt': ServerValue.timestamp,
          if (avatarUrl != null) 'avatarUrl': avatarUrl,
        });

        // Mapování @username -> uid (pro lookup kontaktů, statusů a presence)
        final lower = githubUsername.toLowerCase();
        await rtdb().ref('usernames/$lower').set(user.uid);

        // Pokud chybí `isModerator`, nastav default false (bez přepsání existující true)
        final modSnap = await rtdb().ref('users/${user.uid}/isModerator').get();
        if (!modSnap.exists) {
          await rtdb().ref('users/${user.uid}').update({'isModerator': false});
        }
      } else {
        // Avoid leaving the app in a "half-logged-in" state where AuthGate waits forever.
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          setState(() => _errorMessage = 'Nepodařilo se zjistit GitHub username. Zkus to prosím znovu.');
        }
      }
      // Navigation is handled by AuthGate reacting to authStateChanges.
      // Avoid pushing a second Dashboard route (can lead to odd initial state).
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'Sign in to GitMit',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 28,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              OutlinedButton(
                onPressed: _loading ? null : _loginWithGitHub,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
                child: const Text(
                  'Sign in with GitHub',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
