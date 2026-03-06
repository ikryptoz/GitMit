import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/app_language.dart';
import 'package:gitmit/rtdb.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  String? _errorMessage;
  bool _loading = false;

  Future<void> _register() async {
    setState(() => _loading = true);
    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      final user = credential.user;
      if (user != null) {
        final userRef = rtdb().ref('users/${user.uid}');
        await userRef.set({
          'email': _emailController.text.trim(),
          'createdAt': ServerValue.timestamp,
          'avatarUrl': '',
          'verified': false,
          'isModerator': false,
        });
        // Přidat achievement 'first_login'
        await userRef.child('achievements/first_login').set({
          'unlockedAt': ServerValue.timestamp,
          'label': 'První přihlášení',
        });
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/dashboard');
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } on FirebaseException catch (e) {
      setState(() => _errorMessage = e.message ?? e.code);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = AppLanguage.tr(context, 'Registrace do GitMit', 'Register to GitMit');
    final emailLabel = AppLanguage.tr(context, 'Email', 'Email');
    final passwordLabel = AppLanguage.tr(context, 'Heslo', 'Password');
    final registerLabel = AppLanguage.tr(context, 'Registrovat', 'Register');
    final hasAccount = AppLanguage.tr(context, 'Už máš účet? Přihlásit se', 'Already have an account? Sign in');

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF061628),
              Color(0xFF0A1C2E),
              Color(0xFF0F2C26),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: const Color(0xCC101B28),
                    border: Border.all(color: const Color(0x334A678A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 30,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        r'$ create account --secure --github-ready',
                        style: TextStyle(
                          color: Color(0xFF8AA8C8),
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _emailController,
                        decoration: InputDecoration(labelText: emailLabel),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _passwordController,
                        decoration: InputDecoration(labelText: passwordLabel),
                        obscureText: true,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _loading ? null : _register,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF238636),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(fontWeight: FontWeight.w700),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(registerLabel),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Text(_errorMessage!, style: const TextStyle(color: Color(0xFFFF6B6B))),
                      ],
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.of(context).pushReplacementNamed('/login'),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF9ED2FF)),
                        child: Text(hasAccount),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
