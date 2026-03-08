import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:gitmit/app_language.dart';
import 'package:gitmit/register.dart';
import 'package:gitmit/dashboard.dart';
import 'package:gitmit/notifications_service.dart';
import 'package:gitmit/deep_links.dart';
import 'package:gitmit/rtdb.dart';
import 'package:gitmit/github_api.dart';
import 'package:gitmit/e2ee.dart';
import 'package:gitmit/plaintext_cache.dart';
import 'package:gitmit/data_usage.dart';
import 'package:gitmit/firebase_options.dart';
import 'dart:async';
import 'dart:convert';

// ignore: uri_does_not_exist

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlaintextCache.init();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AppNotifications.initialize();
  await DeepLinks.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    const ghBg = Color(0xFF0D1117);
    const ghCanvas = Color(0xFF010409);
    const ghCard = Color(0xFF161B22);
    const ghBorder = Color(0xFF30363D);
    const ghText = Color(0xFFC9D1D9);
    const ghGreen = Color(0xFF238636);
    const ghBlue = Color(0xFF316DCA);
    const uiRadius = 12.0;
    const uiSheetRadius = 18.0;
    const uiMinTapHeight = 52.0;

    return ValueListenableBuilder<String>(
      valueListenable: AppLanguage.code,
      builder: (context, lang, _) {
        return MaterialApp(
          navigatorKey: DeepLinks.navigatorKey,
          title: 'GitMit',
          locale: AppLanguage.locale,
          supportedLocales: const [
            Locale('cs'),
            Locale('en'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: ghBg,
            canvasColor: ghCanvas,
            dividerColor: ghBorder,
            appBarTheme: const AppBarTheme(
              backgroundColor: ghBg,
              foregroundColor: ghText,
              elevation: 0,
              iconTheme: IconThemeData(color: ghText),
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: ghGreen,
              onPrimary: Colors.white,
              secondary: ghBlue,
              onSecondary: Colors.white,
              error: Color(0xFFDA3633),
              onError: Colors.white,
              background: ghBg,
              onBackground: ghText,
              surface: ghCard,
              onSurface: ghText,
            ),
            inputDecorationTheme: const InputDecorationTheme(
              filled: true,
              fillColor: ghCard,
              labelStyle: TextStyle(color: Color(0xFF8B949E)),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(uiRadius)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(uiRadius)),
                borderSide: BorderSide(color: ghBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(uiRadius)),
                borderSide: BorderSide(color: ghBlue, width: 2),
              ),
            ),
            cardTheme: CardThemeData(
              color: ghCard,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: ghBorder),
              ),
            ),
            dividerTheme: const DividerThemeData(
              color: ghBorder,
              space: 1,
              thickness: 1,
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: ghCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(uiRadius),
                side: const BorderSide(color: ghBorder),
              ),
            ),
            bottomSheetTheme: const BottomSheetThemeData(
              backgroundColor: ghCard,
              modalBackgroundColor: ghCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(uiSheetRadius),
                ),
              ),
            ),
            listTileTheme: ListTileThemeData(
              iconColor: Color(0xFF8B949E),
              textColor: ghText,
              tileColor: ghCard,
              minTileHeight: uiMinTapHeight,
              minVerticalPadding: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(uiRadius),
                side: const BorderSide(color: ghBorder),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: const Color(0xFF161B22),
              contentTextStyle: const TextStyle(color: ghText),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: ghBorder),
              ),
              behavior: SnackBarBehavior.floating,
            ),
            switchTheme: SwitchThemeData(
              thumbColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.disabled)) return Colors.white24;
                return states.contains(MaterialState.selected) ? Colors.white : Colors.white70;
              }),
              trackColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.disabled)) return Colors.white10;
                return states.contains(MaterialState.selected)
                    ? const Color(0xAA238636)
                    : Colors.white24;
              }),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ButtonStyle(
                backgroundColor: const MaterialStatePropertyAll(Color(0xFF238636)),
                foregroundColor: const MaterialStatePropertyAll(Colors.white),
                textStyle: MaterialStatePropertyAll(TextStyle(fontWeight: FontWeight.bold)),
                minimumSize: const MaterialStatePropertyAll(
                  Size.fromHeight(uiMinTapHeight),
                ),
                shape: MaterialStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(uiRadius)),
                )),
                side: const MaterialStatePropertyAll(
                  BorderSide(color: Color(0x22F0F6FC)),
                ),
                padding: MaterialStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: ButtonStyle(
                foregroundColor: const MaterialStatePropertyAll(ghText),
                backgroundColor: const MaterialStatePropertyAll(Color(0xFF21262D)),
                side: MaterialStatePropertyAll(BorderSide(color: ghBorder)),
                minimumSize: const MaterialStatePropertyAll(
                  Size.fromHeight(uiMinTapHeight),
                ),
                shape: MaterialStatePropertyAll(RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(uiRadius)),
                )),
                padding: MaterialStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                ),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF58A6FF),
                minimumSize: const Size(0, uiMinTapHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(uiRadius),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, uiMinTapHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(uiRadius),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
            chipTheme: ChipThemeData(
              backgroundColor: const Color(0xFF0D1117),
              selectedColor: const Color(0xFF1B2230),
              labelStyle: const TextStyle(color: ghText),
              side: const BorderSide(color: ghBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
            ),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: ghCard,
              indicatorColor: const Color(0x22316DCA),
              iconTheme: const WidgetStatePropertyAll(
                IconThemeData(color: Color(0xFF8B949E)),
              ),
              labelTextStyle: const WidgetStatePropertyAll(
                TextStyle(color: ghText, fontWeight: FontWeight.w600),
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
      },
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
  String? _githubGateUid;
  int _githubGateStartedAt = 0;
  bool _githubRepairInFlight = false;

  void _resetGithubGate(String uid) {
    if (_githubGateUid == uid && _githubGateStartedAt > 0) return;
    _githubGateUid = uid;
    _githubGateStartedAt = DateTime.now().millisecondsSinceEpoch;
  }

  Duration _githubGateAge() {
    if (_githubGateStartedAt <= 0) return Duration.zero;
    final now = DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: (now - _githubGateStartedAt).clamp(0, 1 << 30));
  }

  bool _looksLikeGithubLogin(String value) {
    final v = value.trim();
    if (v.isEmpty || v.length > 39) return false;
    if (v.startsWith('-') || v.endsWith('-')) return false;
    return RegExp(r'^[A-Za-z0-9-]+$').hasMatch(v);
  }

  void _kickGithubRepair({required User user, required Map? profile}) {
    if (_githubRepairInFlight) return;
    _githubRepairInFlight = true;
    () async {
      try {
        var username = (profile?['githubUsername'] ?? '').toString().trim();

        if (username.isEmpty) {
          for (final p in user.providerData) {
            if (p.providerId != 'github.com') continue;
            final candidate = (p.displayName ?? '').trim();
            if (_looksLikeGithubLogin(candidate)) {
              username = candidate;
              break;
            }
          }
        }

        if (username.isNotEmpty) {
          final lower = username.toLowerCase();
          final mapRef = rtdb().ref('usernames/$lower');
          final mapSnap = await mapRef.get();
          final mapped = mapSnap.value?.toString();
          if (mapped == null || mapped.isEmpty || mapped == user.uid) {
            await mapRef.set(user.uid);
          }
          await rtdb().ref('users/${user.uid}').update({
            'githubUsername': username,
            'provider': 'github',
            'email': user.email,
            'lastLoginAt': ServerValue.timestamp,
            if ((user.photoURL ?? '').trim().isNotEmpty) 'avatarUrl': user.photoURL,
          });
        }
      } catch (_) {
        // best-effort self-heal only
      } finally {
        _githubRepairInFlight = false;
      }
    }();
  }

  @override
  void initState() {
    super.initState();
    _sub = FirebaseAuth.instance.authStateChanges().listen((u) {
      _user = u;
      _ready = true;
      // Scope all local E2EE state to the active Firebase UID.
      // This prevents cross-account key/session mixups when switching accounts.
      E2ee.setActiveUser(u?.uid);
      DataUsageTracker.setActiveUser(u?.uid);
      () async {
        try {
          await PlaintextCache.setActiveUser(u?.uid);
        } catch (_) {
          // ignore
        }
      }();
      AppNotifications.setUser(u);
      AppLanguage.bindUser(u?.uid);
      DeepLinks.onAuthChanged(u);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    AppLanguage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final user = _user;
    if (user == null) return const LoginPage();

    _resetGithubGate(user.uid);

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
          final gateAge = _githubGateAge();
          if (githubUsername.isEmpty) {
            _kickGithubRepair(user: user, profile: m);
            if (gateAge > const Duration(seconds: 20)) {
              // Prevent infinite spinner on older Android devices with delayed
              // RTDB profile propagation.
              return const DashboardPage();
            }
            return _AccountSetupScreen(
              title: AppLanguage.tr(context, 'Dokončuji registraci…', 'Finishing registration…'),
              message: AppLanguage.tr(context, 'Načítám profil a připravuji účet.', 'Loading profile and preparing your account.'),
              showSignOut: gateAge > const Duration(seconds: 8),
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
                if (gateAge > const Duration(seconds: 20)) {
                  return const DashboardPage();
                }
                return _AccountSetupScreen(
                  title: AppLanguage.tr(context, 'Dokončuji registraci…', 'Finishing registration…'),
                  message: AppLanguage.tr(
                    context,
                    'Nastavuji mapování @${githubUsername.toLowerCase()} → UID.',
                    'Setting mapping @${githubUsername.toLowerCase()} → UID.',
                  ),
                  showSignOut: gateAge > const Duration(seconds: 8),
                );
              }

              if (mapped != user.uid) {
                return _AccountSetupScreen(
                  title: AppLanguage.tr(context, 'Chyba registrace', 'Registration error'),
                  message: AppLanguage.tr(
                    context,
                    'Username @$githubUsername už je spárovaný s jiným účtem. Odhlas se a zkus to znovu.',
                    'Username @$githubUsername is already linked to another account. Sign out and try again.',
                  ),
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D1117), Color(0xFF0A1422), Color(0xFF0E1D17)],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 540),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xCC161B22),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Text(message, style: const TextStyle(color: Color(0xFF8B949E)), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  if (!showSignOut) const CircularProgressIndicator(),
                  if (showSignOut) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      child: Text(AppLanguage.tr(context, 'Odhlásit', 'Sign out')),
                    ),
                  ],
                ],
              ),
            ),
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
  static bool _githubLoginInFlight = false;
  static int _githubLoginStartedAtMs = 0;

  String? _errorMessage;
  bool _loading = false;

  Future<void> _loginWithGitHub() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Guard against duplicated provider launches across quick taps/rebuilds.
    if (_githubLoginInFlight) {
      final age = now - _githubLoginStartedAtMs;
      if (age < 45000) {
        if (mounted) {
          setState(
            () => _errorMessage = AppLanguage.tr(
              context,
              'Přihlášení už běží. Chvilku počkej prosím.',
              'Sign-in is already in progress. Please wait a moment.',
            ),
          );
        }
        return;
      }
      // Stale lock fallback.
      _githubLoginInFlight = false;
    }
    if (_loading) return;
    _githubLoginInFlight = true;
    _githubLoginStartedAtMs = now;
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final provider = GithubAuthProvider()..addScope('read:user');
      UserCredential credential;

      if (kIsWeb) {
        try {
          credential = await FirebaseAuth.instance.signInWithPopup(provider);
        } on FirebaseAuthException catch (_) {
          await FirebaseAuth.instance.signInWithRedirect(provider);
          if (mounted) {
            setState(() => _errorMessage = AppLanguage.tr(
                  context,
                  'Probíhá přesměrování na GitHub přihlášení…',
                  'Redirecting to GitHub sign-in…',
                ));
          }
          return;
        }
      } else {
        credential = await FirebaseAuth.instance.signInWithProvider(provider);
      }

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
        final res = await DataUsageTracker.trackedGet(
          uri,
          headers: {
            'Accept': 'application/vnd.github+json',
            'Authorization': 'token $accessToken',
          },
          category: 'api',
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
        final res = await DataUsageTracker.trackedGet(
          uri,
          headers: githubApiHeaders(),
          category: 'api',
        );
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
          setState(
            () => _errorMessage = AppLanguage.tr(
              context,
              'Nepodařilo se zjistit GitHub username. Zkus to prosím znovu.',
              'Could not resolve GitHub username. Please try again.',
            ),
          );
        }
      }
      // Navigation is handled by AuthGate reacting to authStateChanges.
      // Avoid pushing a second Dashboard route (can lead to odd initial state).
    } on FirebaseAuthException catch (e) {
      final msg = (e.message ?? '').toLowerCase();
      if (msg.contains('operation is already in progress') ||
          msg.contains('headful operation is already in progress')) {
        if (mounted) {
          setState(
            () => _errorMessage = AppLanguage.tr(
              context,
              'Přihlášení už běží. Zavři prosím okno GitHubu a zkus to za pár sekund znovu.',
              'Sign-in is already in progress. Close the GitHub window and try again in a few seconds.',
            ),
          );
        }
      } else {
      if (mounted) {
        setState(
          () => _errorMessage = e.message ?? AppLanguage.tr(
            context,
            'Přihlášení přes GitHub selhalo. Zkontroluj, že je GitHub provider povolený ve Firebase Authentication.',
            'GitHub sign-in failed. Check that the GitHub provider is enabled in Firebase Authentication.',
          ),
        );
      }
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      _githubLoginInFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.data != null) {
          return const AuthGate();
        }

        final signInTitle = AppLanguage.tr(context, 'Přihlásit do GitMit', 'Sign in to GitMit');
        final signInWithGithub = AppLanguage.tr(context, 'Přihlásit přes GitHub', 'Sign in with GitHub');
        final badge = AppLanguage.tr(
          context,
          'E2EE MESSENGER PRO GITHUB TVURCE',
          'E2EE MESSENGER FOR GITHUB CREATORS',
        );
        final heroText = AppLanguage.tr(
          context,
          'Code, Chat a Keep it Private.',
          'Code, Chat, and Keep it Private.',
        );
        final description = AppLanguage.tr(
          context,
          'Bezpecna komunikace pro GitHub tymy. End-to-end sifrovani, rychle DM a skupiny na jednom miste.',
          'Secure communication for GitHub teams. End-to-end encryption, fast DMs, and groups in one place.',
        );

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
            child: Stack(
              children: [
                const Positioned(top: -90, left: -40, child: _GlowOrb(size: 220, color: Color(0x332CA7FF))),
                const Positioned(bottom: -120, right: -20, child: _GlowOrb(size: 280, color: Color(0x3335D07F))),
                SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 980),
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final compact = c.maxWidth < 860;
                            final brandSection = _BrandPanel(
                              badge: badge,
                              headline: heroText,
                              description: description,
                            );
                            final loginSection = _LoginPanel(
                              title: signInTitle,
                              buttonLabel: signInWithGithub,
                              loading: _loading,
                              errorMessage: _errorMessage,
                              onLogin: _loginWithGitHub,
                            );

                            if (compact) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [brandSection, const SizedBox(height: 18), loginSection],
                              );
                            }

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 11, child: brandSection),
                                const SizedBox(width: 18),
                                Expanded(flex: 9, child: loginSection),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, Colors.transparent],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({
    required this.badge,
    required this.headline,
    required this.description,
  });

  final String badge;
  final String headline;
  final String description;

  @override
  Widget build(BuildContext context) {
    final parts = headline.split('Private.');
    final first = parts.first.trim();

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0x88101820),
        border: Border.all(color: const Color(0x3349D3A6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A5D93)),
              color: const Color(0xFF17324A),
            ),
            child: Text(
              badge,
              style: const TextStyle(
                color: Color(0xFF8DC4FF),
                letterSpacing: 0.6,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            first,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 44,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
          ShaderMask(
            shaderCallback: (rect) {
              return const LinearGradient(
                colors: [Color(0xFF37D07F), Color(0xFF2F91FF)],
              ).createShader(rect);
            },
            child: const Text(
              'Private.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 44,
                fontWeight: FontWeight.w800,
                height: 1.05,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            description,
            style: const TextStyle(
              color: Color(0xFFB3BDC9),
              fontSize: 18,
              height: 1.42,
            ),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _TagChip(text: '[STAR] Open Source'),
              _TagChip(text: '[LOCK] E2EE X25519 + Ratchet'),
              _TagChip(text: '[TEAM] DM + Group Chat'),
              _TagChip(text: '[FAST] Flutter + Firebase'),
            ],
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC0C131D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x333A4C62)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFAAB8C8),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.25,
        ),
      ),
    );
  }
}

class _LoginPanel extends StatelessWidget {
  const _LoginPanel({
    required this.title,
    required this.buttonLabel,
    required this.loading,
    required this.errorMessage,
    required this.onLogin,
  });

  final String title;
  final String buttonLabel;
  final bool loading;
  final String? errorMessage;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xCC0F1723),
        border: Border.all(color: const Color(0x33406387)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
              color: Color(0xFF121D2D),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2CA36B),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'GM',
                    style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD83E4A),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'SECURE',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          Container(
            constraints: const BoxConstraints(minHeight: 200),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  r'$ init GitMit.session --e2ee',
                  style: TextStyle(color: Color(0xFF3FE17D), fontFamily: 'monospace', fontSize: 13),
                ),
                SizedBox(height: 8),
                Text(
                  r'$ connect github.identity',
                  style: TextStyle(color: Color(0xFF9FB3CC), fontFamily: 'monospace', fontSize: 13),
                ),
                SizedBox(height: 8),
                Text(
                  r'$ handshake complete',
                  style: TextStyle(color: Color(0xFF9FB3CC), fontFamily: 'monospace', fontSize: 13),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ElevatedButton(
              onPressed: loading ? null : onLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF238636),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      buttonLabel,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
            ),
          ),
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                errorMessage!,
                style: const TextStyle(color: Color(0xFFFF6B6B), fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
