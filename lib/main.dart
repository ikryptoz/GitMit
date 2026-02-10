import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/register.dart';
import 'package:gitmit/dashboard.dart';
import 'package:gitmit/rtdb.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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
    const green3 = Color(0xFF08872B); // #08872B (GREEN 5, tmavší)
    const green4 = Color(0xFF0A241B); // #0A241B (GREEN 6, tmavší)

    return MaterialApp(
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
          primary: green4,
          onPrimary: Colors.white,
          secondary: green3,
          onSecondary: Colors.white,
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
            borderSide: BorderSide(color: green4),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: green3, width: 2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: MaterialStatePropertyAll(green4),
            foregroundColor: MaterialStatePropertyAll(Colors.white),
            textStyle: MaterialStatePropertyAll(TextStyle(fontWeight: FontWeight.bold)),
            shape: MaterialStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            )),
            padding: MaterialStatePropertyAll(EdgeInsets.symmetric(horizontal: 32, vertical: 16)),
          ),
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
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.active) {
          final user = snapshot.data;
          if (user == null) {
            return const LoginPage();
          } else {
            return const DashboardPage();
          }
        }
        return const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        );
      },
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
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final provider = GithubAuthProvider()..addScope('read:user');
      final credential = await FirebaseAuth.instance.signInWithProvider(provider);

      final user = credential.user;
      final githubUsername = credential.additionalUserInfo?.username;
      String? avatarUrl;

      // Fetch avatar and verification from GitHub API
      if (githubUsername != null && githubUsername.isNotEmpty) {
        final uri = Uri.https('api.github.com', '/users/$githubUsername');
        final res = await http.get(uri, headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'gitmit',
        });
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
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/dashboard');
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _loading = false);
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
                    color: Color(0xFF08872B),
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
                  foregroundColor: const Color(0xFF08872B),
                  side: const BorderSide(color: Color(0xFF0A241B)),
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
