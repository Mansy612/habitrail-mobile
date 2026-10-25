import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter, MaskFilter, BlurStyle, ImageByteFormat;
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:share_plus/share_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'core.dart';
import 'ai.dart';
import 'auth.dart';
import 'backend.dart';
import 'friends.dart';
import 'ui/hr_tokens.dart';
import 'ui/hr_theme.dart';
import 'ui/hr_widgets.dart';

/// Single shared state object for the whole app (loads immediately).
// Loaded eagerly in main() before the app renders — see main(). (Must NOT
// auto-load here: appState is a lazily-initialized top-level, so a new user's
// first access during sign-up would start load() AFTER the fresh-start reset
// and clobber it with the old saved state.)
final appState = AppState();

// The animated particle background was removed in the redesign — the ground is
// a static black (HrColors.bg). See docs/design/.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On desktop, constrain the window to phone proportions so every screen and
  // popup renders phone-shaped (mobile/web already size themselves).
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(400, 860),
      minimumSize: Size(340, 640),
      center: true,
      title: 'Habitrail',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  // Load persisted state before the first frame so it can't finish mid-session
  // and overwrite a fresh-account reset.
  await initBackend();
  if (backendEnabled) auth.useService(SupabaseAuthService());
  await appState.load();
  await friends.load();
  if (backendEnabled) _startBackendSync();
  runApp(const HabitrailApp());
}

// When the backend is on, keep the user's public profile stats fresh (debounced)
// and reload friends after a sign-in so the leaderboard reflects real data.
void _startBackendSync() {
  void push() => pushProfileStats(
        totalXp: appState.totalXp,
        streak: appState.bestStreak,
        prestige: appState.prestige,
        borderId: appState.selectedBorder,
        name: appState.displayName,
      );
  push();
  Timer? debounce;
  appState.addListener(() {
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), push);
  });
  auth.addListener(() {
    if (auth.isAuthed) {
      push();
      friends.refresh();
    }
  });
}

class HabitrailApp extends StatelessWidget {
  const HabitrailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Habitrail',
      debugShowCheckedModeBanner: false,
      theme: hrTheme().copyWith(
        // Keep the fade + 3.5% slide page transition from the old theme.
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.android: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.iOS: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.macOS: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.windows: _FadeSlidePageTransitionsBuilder(),
          TargetPlatform.linux: _FadeSlidePageTransitionsBuilder(),
        }),
      ),
      // Static black ground (the animated particle background was removed).
      builder: (context, child) =>
          ColoredBox(color: HrColors.bg, child: child),
      home: const AuthGate(),
    );
  }
}

class _FadeSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.035, 0), end: Offset.zero)
            .animate(eased),
        child: child,
      ),
    );
  }
}

// ── Auth gate: Welcome (signed out) → app (signed in or guest) ──────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    auth.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (auth.status == AuthStatus.unknown) {
          return Scaffold(
            body: Center(
                child: CircularProgressIndicator(color: kPlasmaBright)),
          );
        }
        final enter = auth.status == AuthStatus.signedIn || auth.guest;
        return enter ? const HomeShell() : const WelcomeScreen();
      },
    );
  }
}

// ── Welcome ──────────────────────────────────────────────────────────────────
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 28),
                      Center(
                        child: Container(
                          width: 104,
                          height: 104,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _kAccentGradient),
                            boxShadow: [
                              BoxShadow(
                                  color: kPlasma.withValues(alpha: 0.5),
                                  blurRadius: 40,
                                  spreadRadius: 2),
                            ],
                          ),
                          child:
                              const Text('🔥', style: TextStyle(fontSize: 50)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text('Habitrail',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.spaceGrotesk(
                              color: kTextPrimary,
                              fontSize: 42,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      const Text('Build habits. Earn XP. Level up your life.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: kTextSecondary, fontSize: 15)),
                      const SizedBox(height: 28),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: glassDecoration(radius: 18),
                        child: Column(children: [
                          _welcomeFeature('⚡', 'Earn XP & level up',
                              'Check off habits, build streaks and combos.'),
                          _welcomeFeature(
                              '🏆',
                              'Quests, bosses & Victory Score',
                              'Daily quests, a weekly boss, and a score to beat.'),
                          _welcomeFeature('🐾', 'Companions & rewards',
                              'Adopt companions and spend coins in the shop.'),
                        ]),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              GradientButton(
                label: 'Create account',
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SignUpScreen())),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    foregroundColor: kPlasmaBright,
                    side: BorderSide(color: kPlasma.withValues(alpha: 0.5))),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen())),
                child: const Text('Log in'),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => auth.continueAsGuest(),
                child: const Text('Continue without an account',
                    style: TextStyle(color: kTextTertiary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// A feature highlight row on the welcome screen (emoji badge + title + blurb).
Widget _welcomeFeature(String emoji, String title, String subtitle) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  kPlasma.withValues(alpha: 0.30),
                  kCyan.withValues(alpha: 0.18)
                ]),
            border: Border.all(color: kBorder),
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 20)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: kTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: kTextTertiary, fontSize: 12, height: 1.3)),
            ],
          ),
        ),
      ]),
    );

// ── Sign up ──────────────────────────────────────────────────────────────────
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;
  Timer? _unameDebounce;
  int _unameSeq = 0;
  bool _unameChecking = false;
  bool? _unameAvailable; // null = unknown/invalid, true/false = checked

  @override
  void dispose() {
    _unameDebounce?.cancel();
    _username.dispose();
    _email.dispose();
    _pw.dispose();
    super.dispose();
  }

  void _onUsernameChanged(String v) {
    _unameDebounce?.cancel();
    final u = v.trim();
    if (u.isEmpty || !isValidUsername(u)) {
      setState(() {
        _unameChecking = false;
        _unameAvailable = null;
      });
      return;
    }
    setState(() {
      _unameChecking = true;
      _unameAvailable = null;
    });
    final seq = ++_unameSeq;
    _unameDebounce = Timer(const Duration(milliseconds: 400), () async {
      final ok = await auth.isUsernameAvailable(u);
      if (!mounted || seq != _unameSeq) return;
      setState(() {
        _unameChecking = false;
        _unameAvailable = ok;
      });
    });
  }

  Widget _usernameStatus() {
    final u = _username.text.trim();
    if (u.isEmpty) return const SizedBox.shrink();
    if (!isValidUsername(u)) {
      return _unameStatusLine(kTextTertiary, Icons.info_outline_rounded,
          '3–20 letters, numbers, or underscores');
    }
    if (_unameChecking) {
      return const Padding(
        padding: EdgeInsets.only(left: 4, bottom: 10),
        child: Row(children: [
          SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Checking…', style: TextStyle(color: kTextTertiary, fontSize: 12)),
        ]),
      );
    }
    if (_unameAvailable == true) {
      return _unameStatusLine(kGreen, Icons.check_circle_rounded, 'Available');
    }
    if (_unameAvailable == false) {
      return _unameStatusLine(kRed, Icons.cancel_rounded, 'Unavailable');
    }
    return const SizedBox.shrink();
  }

  Widget _unameStatusLine(Color c, IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Row(children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: c, fontSize: 12)),
        ]),
      );

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await auth.signUp(_username.text, _email.text, _pw.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      // New account → wipe any guest/previous progress and start at Level 1,
      // then introduce the app with the onboarding flow.
      appState.startFreshForAccount(auth.user?.name ?? '');
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const OnboardingQuizScreen()));
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _authScaffold(
      context,
      title: 'Create account',
      subtitle: 'Start earning XP for your habits.',
      children: [
        _authField(_username, 'Username',
            hint: 'e.g. sam_92', onChanged: _onUsernameChanged),
        _usernameStatus(),
        _authField(_email, 'Email',
            keyboard: TextInputType.emailAddress, hint: 'you@example.com'),
        _authField(_pw, 'Password',
            obscure: true, hint: 'At least 6 characters'),
        if (_error != null) _authError(_error!),
        const SizedBox(height: 4),
        _authSubmit('Create account', _busy, _submit),
        const SizedBox(height: 16),
        _authDivider(),
        const SizedBox(height: 16),
        _appleButton(),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (_) => const LoginScreen())),
            child: Text('Already have an account? Log in',
                style: TextStyle(color: kPlasmaBright)),
          ),
        ),
        _authNote(),
      ],
    );
  }
}

// ── Log in ───────────────────────────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await auth.signIn(_email.text, _pw.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      final u = auth.user;
      if (u != null) appState.setDisplayName(u.name);
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _authScaffold(
      context,
      title: 'Welcome back',
      subtitle: 'Log in to pick up where you left off.',
      children: [
        _authField(_email, 'Email',
            keyboard: TextInputType.emailAddress, hint: 'you@example.com'),
        _authField(_pw, 'Password', obscure: true, hint: 'Your password'),
        if (_error != null) _authError(_error!),
        const SizedBox(height: 4),
        _authSubmit('Log in', _busy, _submit),
        const SizedBox(height: 16),
        _authDivider(),
        const SizedBox(height: 16),
        _appleButton(),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () => Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (_) => const SignUpScreen())),
            child: Text("New here? Create an account",
                style: TextStyle(color: kPlasmaBright)),
          ),
        ),
        _authNote(),
      ],
    );
  }
}

// ── Account (signed in) ──────────────────────────────────────────────────────
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([auth, appState]),
      builder: (context, _) {
        final u = auth.user;
        if (u == null) return const SizedBox.shrink();
        final ld = levelFromXp(appState.totalXp);
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: kTextPrimary,
            title: Text('Account',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                  gradient: _kGlassSheen,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder)),
              child: Column(children: [
                GestureDetector(
                  onTap: () => _pickProfilePhoto(context),
                  child: Stack(children: [
                    _Avatar(size: 76),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kPlasma,
                            border: Border.all(color: kCard, width: 2)),
                        child: const Icon(Icons.camera_alt_rounded,
                            size: 12, color: Colors.white),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
                _photoActions(context),
                const SizedBox(height: 12),
                Text(u.name,
                    style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(u.email,
                    style: const TextStyle(color: kTextTertiary, fontSize: 13)),
                if (u.username.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('@${u.username}',
                      style: TextStyle(
                          color: kPlasmaBright,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
                if (_memberSince(u.createdAt).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(_memberSince(u.createdAt),
                      style:
                          const TextStyle(color: kTextTertiary, fontSize: 11)),
                ],
              ]),
            ),
            const SizedBox(height: 4),
            _sectionLabel('LIFETIME'),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _statChip('Level', '${ld.level}'),
              _statChip('Total XP', '${appState.totalXp}'),
              _statChip('Best streak', '${appState.bestStreak}'),
              _statChip('Habits', '${appState.habits.length}'),
              _statChip('Prestige', '${appState.prestige}'),
            ]),
            const SizedBox(height: 16),
            GradientButton(
              label: 'Share my progress',
              icon: Icons.ios_share_rounded,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ShareCardScreen())),
            ),
            const SizedBox(height: 4),
            _sectionLabel('ACCOUNT'),
            _settingsTile(Icons.edit_rounded, 'Edit name', u.name,
                () => _editAccountName(context)),
            if (!auth.isRemote)
              _settingsTile(Icons.cloud_off_rounded, 'Cloud sync',
                  'On this device for now — Supabase wires in later', null),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () => _confirmDeleteAccount(context),
              icon: const Icon(Icons.delete_forever_rounded,
                  size: 18, color: kRed),
              label:
                  const Text('Delete account', style: TextStyle(color: kRed)),
            ),
          ]),
        );
      },
    );
  }
}

// ── Onboarding (first run, right after creating an account) ─────────────────
class _OnbSlide {
  const _OnbSlide(this.emoji, this.title, this.body, this.accent);
  final String emoji;
  final String title;
  final String body;
  final Color accent;
}

const _onbSlides = [
  _OnbSlide(
      '🔥',
      'Welcome to Habitrail',
      'Turn your daily habits into a game you actually want to play.',
      Color(0xFFFF8A4C)),
  _OnbSlide(
      '⚡',
      'Earn XP, level up',
      'Every habit you check off earns XP. Build streaks and combos for big multipliers, and climb from Level 1 to God-Tier.',
      Color(0xFF3DE7FF)),
  _OnbSlide(
      '🏆',
      'Quests, bosses & Victory Score',
      'Take on daily quests, defeat the weekly boss, and track each day with a 4-pillar Victory Score.',
      Color(0xFFFFD23F)),
  _OnbSlide(
      '🐾',
      'Companions & more',
      'Adopt a companion, log nutrition, prestige, and make every single day count.',
      Color(0xFF4ADE80)),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _finish() => Navigator.of(context).popUntil((r) => r.isFirst);

  void _next() {
    if (_page >= _onbSlides.length - 1) {
      _finish();
    } else {
      _pc.nextPage(
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _onbSlides.length - 1;
    return Scaffold(
      body: Stack(children: [
        SafeArea(
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child:
                    const Text('Skip', style: TextStyle(color: kTextTertiary)),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pc,
                itemCount: _onbSlides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final s = _onbSlides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 128,
                          height: 128,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(colors: [
                              s.accent.withValues(alpha: 0.35),
                              s.accent.withValues(alpha: 0.04)
                            ]),
                            border: Border.all(
                                color: s.accent.withValues(alpha: 0.45)),
                            boxShadow: [
                              BoxShadow(
                                  color: s.accent.withValues(alpha: 0.3),
                                  blurRadius: 44,
                                  spreadRadius: 4)
                            ],
                          ),
                          child: Text(s.emoji,
                              style: const TextStyle(fontSize: 60)),
                        ),
                        const SizedBox(height: 32),
                        Text(s.title,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.spaceGrotesk(
                                color: kTextPrimary,
                                fontSize: 26,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
                        Text(s.body,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: kTextSecondary,
                                fontSize: 15,
                                height: 1.5)),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_onbSlides.length, (i) {
                final on = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: on ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: on ? _onbSlides[_page].accent : kBorder,
                      borderRadius: BorderRadius.circular(4)),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.all(28),
              child: GradientButton(
                label: last ? 'Get started' : 'Next',
                onPressed: _next,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── ONBOARDING QUIZ (personalize a new account) ──────────────────────────────
const List<(String, String, String)> _kAreas = [
  ('fitness', 'Fitness', '🏋️'),
  ('nutrition', 'Nutrition', '🥗'),
  ('mind', 'Mindfulness', '🧘'),
  ('sleep', 'Sleep', '😴'),
  ('learning', 'Learning', '📖'),
  ('productivity', 'Productivity', '💻'),
];

String _areaLabel(String id) =>
    _kAreas.firstWhere((a) => a.$1 == id, orElse: () => (id, id, '')).$2;

class OnboardingQuizScreen extends StatefulWidget {
  const OnboardingQuizScreen({super.key});
  @override
  State<OnboardingQuizScreen> createState() => _OnboardingQuizScreenState();
}

class _OnboardingQuizScreenState extends State<OnboardingQuizScreen> {
  final _pc = PageController();
  int _page = 0;
  static const _last = 6; // pages 0..6 (6 = summary)

  final Set<String> _areas = {};
  String _gender = 'male';
  final _age = TextEditingController();
  final _height = TextEditingController();
  final _weight = TextEditingController();
  String _activity = 'moderate';
  String _goal = 'maintain';

  @override
  void dispose() {
    _pc.dispose();
    _age.dispose();
    _height.dispose();
    _weight.dispose();
    super.dispose();
  }

  bool get _canAdvance {
    switch (_page) {
      case 0:
        return _areas.isNotEmpty;
      case 2:
        return (int.tryParse(_age.text.trim()) ?? 0) > 0;
      case 3:
        return (double.tryParse(_height.text.trim()) ?? 0) > 0 &&
            (double.tryParse(_weight.text.trim()) ?? 0) > 0;
      default:
        return true;
    }
  }

  void _skip() => Navigator.of(context).popUntil((r) => r.isFirst);

  void _finish() {
    final a = int.tryParse(_age.text.trim()) ?? 0;
    final h = double.tryParse(_height.text.trim()) ?? 0;
    final w = double.tryParse(_weight.text.trim()) ?? 0;
    if (a > 0 && h > 0 && w > 0) {
      appState.setBodyProfile(BodyProfile(
          weight: w,
          height: h,
          age: a,
          gender: _gender,
          activity: _activity,
          goal: _goal));
    }
    appState.seedHabitsForAreas(_areas);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _next() {
    if (_page >= _last) {
      _finish();
    } else {
      _pc.nextPage(
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _last;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(children: [
              SizedBox(
                width: 44,
                child: _page > 0
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: kTextTertiary),
                        onPressed: () => _pc.previousPage(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOut))
                    : null,
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_page + 1) / (_last + 1),
                    minHeight: 6,
                    backgroundColor: kBorder,
                    valueColor: AlwaysStoppedAnimation(kPlasma),
                  ),
                ),
              ),
              SizedBox(
                width: 54,
                child: last
                    ? null
                    : TextButton(
                        onPressed: _skip,
                        child: const Text('Skip',
                            style: TextStyle(color: kTextTertiary))),
              ),
            ]),
          ),
          Expanded(
            child: PageView(
              controller: _pc,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _areasPage(),
                _genderPage(),
                _agePage(),
                _bodyPage(),
                _activityPage(),
                _goalPage(),
                _summaryPage(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: GradientButton(
              label: last ? "Let's go!" : 'Continue',
              onPressed: _canAdvance ? _next : null,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _quizPage(String title, String? subtitle, Widget content) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        children: [
          Text(title,
              style: GoogleFonts.spaceGrotesk(
                  color: kTextPrimary,
                  fontSize: 26,
                  height: 1.15,
                  fontWeight: FontWeight.w800)),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle,
                style: const TextStyle(
                    color: kTextSecondary, fontSize: 14, height: 1.4)),
          ],
          const SizedBox(height: 24),
          content,
        ],
      );

  Widget _areasPage() => _quizPage(
        'What do you want to work on?',
        "Pick a few — we'll set up starter habits for each.",
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final a in _kAreas) _areaChip(a.$1, a.$2, a.$3)],
        ),
      );

  Widget _areaChip(String id, String label, String emoji) {
    final on = _areas.contains(id);
    return GestureDetector(
      onTap: () => setState(() => on ? _areas.remove(id) : _areas.add(id)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: on
              ? const LinearGradient(colors: _kAccentGradient)
              : _kGlassSheen,
          border: Border.all(color: on ? Colors.transparent : kBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  color: on ? Colors.white : kTextPrimary,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _genderPage() => _quizPage(
        'How do you identify?',
        'Used only to personalize your nutrition targets.',
        Column(children: [
          _choiceRow(
              'male', 'Male', '♂️', _gender, (v) => setState(() => _gender = v)),
          _choiceRow('female', 'Female', '♀️', _gender,
              (v) => setState(() => _gender = v)),
          _choiceRow('other', 'Other / prefer not to say', '⚧️', _gender,
              (v) => setState(() => _gender = v)),
        ]),
      );

  Widget _agePage() =>
      _quizPage('How old are you?', null, _numberField(_age, 'Age', 'years'));

  Widget _bodyPage() => _quizPage(
        'Your height & weight',
        'We use these for your calorie & macro targets.',
        Column(children: [
          _numberField(_height, 'Height', 'cm'),
          const SizedBox(height: 14),
          _numberField(_weight, 'Weight', 'kg'),
        ]),
      );

  Widget _activityPage() => _quizPage(
        'How active are you?',
        null,
        Column(children: [
          _choiceRow('sedentary', 'Sedentary — little exercise', '🪑',
              _activity, (v) => setState(() => _activity = v)),
          _choiceRow('light', 'Lightly active — 1–3 days/wk', '🚶', _activity,
              (v) => setState(() => _activity = v)),
          _choiceRow('moderate', 'Moderately active — 3–5 days/wk', '🏃',
              _activity, (v) => setState(() => _activity = v)),
          _choiceRow('active', 'Very active — 6–7 days/wk', '🏋️', _activity,
              (v) => setState(() => _activity = v)),
          _choiceRow('very_active', 'Athlete — intense daily', '🔥', _activity,
              (v) => setState(() => _activity = v)),
        ]),
      );

  Widget _goalPage() => _quizPage(
        "What's your goal?",
        'This sets your daily calorie target.',
        Column(children: [
          _choiceRow('cut', 'Lose weight', '📉', _goal,
              (v) => setState(() => _goal = v)),
          _choiceRow('maintain', 'Maintain', '⚖️', _goal,
              (v) => setState(() => _goal = v)),
          _choiceRow('bulk', 'Build muscle', '📈', _goal,
              (v) => setState(() => _goal = v)),
        ]),
      );

  Widget _summaryPage() {
    final a = int.tryParse(_age.text.trim()) ?? 0;
    final h = double.tryParse(_height.text.trim()) ?? 0;
    final w = double.tryParse(_weight.text.trim()) ?? 0;
    final hasBody = a > 0 && h > 0 && w > 0;
    final cals = hasBody
        ? computeMacroTargets(BodyProfile(
                weight: w,
                height: h,
                age: a,
                gender: _gender,
                activity: _activity,
                goal: _goal))
            .calories
            .round()
        : null;
    return _quizPage(
      "You're all set!",
      'Your plan is personalized — tap below to start.',
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _summaryTile(Icons.local_fire_department_rounded, 'Daily calorie target',
            hasBody ? '$cals kcal' : 'Add body stats later'),
        const SizedBox(height: 12),
        _summaryTile(
            Icons.checklist_rounded,
            'Focus areas',
            _areas.isEmpty
                ? 'Default starter habits'
                : _areas.map(_areaLabel).join(' · ')),
      ]),
    );
  }

  Widget _summaryTile(IconData icon, String title, String value) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            gradient: _kGlassSheen,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Row(children: [
          Icon(icon, color: kPlasmaBright, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: kTextTertiary, fontSize: 12)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ]),
      );

  Widget _numberField(TextEditingController c, String hint, String suffix) =>
      TextField(
        controller: c,
        keyboardType: TextInputType.number,
        onChanged: (_) => setState(() {}),
        style: GoogleFonts.spaceGrotesk(
            color: kTextPrimary, fontSize: 20, fontWeight: FontWeight.w700),
        decoration: InputDecoration(hintText: hint, suffixText: suffix),
      );

  Widget _choiceRow(String id, String label, String emoji, String group,
      ValueChanged<String> onTap) {
    final on = group == id;
    return GestureDetector(
      onTap: () => onTap(id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: _kGlassSheen,
          border:
              Border.all(color: on ? kPlasma : kBorder, width: on ? 1.5 : 1),
        ),
        child: Row(children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
          if (on)
            Icon(Icons.check_circle_rounded, color: kPlasmaGlow, size: 22),
        ]),
      ),
    );
  }
}

// ── Auth UI helpers ──────────────────────────────────────────────────────────
Widget _authScaffold(BuildContext context,
    {required String title,
    required String subtitle,
    required List<Widget> children}) {
  return Scaffold(
    appBar:
        AppBar(backgroundColor: Colors.transparent, foregroundColor: kTextPrimary),
    body: Stack(children: [
      SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Text(title,
                style: GoogleFonts.spaceGrotesk(
                    color: kTextPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(subtitle,
                style: const TextStyle(color: kTextSecondary, fontSize: 14)),
            const SizedBox(height: 24),
            ...children,
          ],
        ),
      ),
    ]),
  );
}

Widget _authField(TextEditingController c, String label,
    {bool obscure = false,
    TextInputType? keyboard,
    String? hint,
    ValueChanged<String>? onChanged}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label,
              style: const TextStyle(color: kTextTertiary, fontSize: 12)),
        ),
        TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: keyboard,
          onChanged: onChanged,
          style: const TextStyle(color: kTextPrimary),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: kElevated,
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: kBorder)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: kPlasma)),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    ),
  );
}

Widget _authSubmit(String label, bool busy, VoidCallback onTap) => busy
    ? Container(
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(colors: _kAccentGradient)),
        child: const SizedBox(
            width: 20,
            height: 20,
            child:
                CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
      )
    : GradientButton(label: label, onPressed: onTap);

Widget _authError(String msg) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
          color: kRed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kRed.withValues(alpha: 0.4))),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded, color: kRed, size: 17),
        const SizedBox(width: 8),
        Expanded(
            child: Text(msg,
                style: const TextStyle(color: kRed, fontSize: 12.5))),
      ]),
    );

Widget _authDivider() => Row(children: [
      Expanded(child: Container(height: 1, color: kBorder)),
      const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text('or', style: TextStyle(color: kTextTertiary, fontSize: 12))),
      Expanded(child: Container(height: 1, color: kBorder)),
    ]);

Widget _appleButton() => Column(children: [
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            foregroundColor: kTextSecondary,
            side: BorderSide(color: kBorder)),
        onPressed: null, // Sign in with Apple is wired on iOS later.
        icon: const Icon(Icons.apple, size: 20),
        label: const Text('Continue with Apple'),
      ),
      const SizedBox(height: 6),
      const Text('Available on iOS',
          style: TextStyle(color: kTextTertiary, fontSize: 11)),
    ]);

Widget _authNote() {
  if (auth.isRemote) return const SizedBox.shrink();
  return const Padding(
    padding: EdgeInsets.only(top: 18),
    child: Text(
      'Accounts are stored on this device for now — cloud sync turns on when Supabase is connected.',
      textAlign: TextAlign.center,
      style: TextStyle(color: kTextTertiary, fontSize: 11, height: 1.4),
    ),
  );
}

Widget _statChip(String label, String value) => Container(
      width: 104,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(children: [
        Text(value,
            style: GoogleFonts.spaceGrotesk(
                color: kTextPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: kTextTertiary, fontSize: 11)),
      ]),
    );

String _memberSince(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return 'Member since ${months[d.month - 1]} ${d.year}';
}

Future<void> _editAccountName(BuildContext context) async {
  final c = TextEditingController(text: auth.user?.name ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Your name', style: TextStyle(color: kTextPrimary)),
      content: TextField(
        controller: c,
        autofocus: true,
        style: const TextStyle(color: kTextPrimary),
        decoration: const InputDecoration(hintText: 'Display name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name != null && name.isNotEmpty) {
    await auth.updateName(name);
    appState.setDisplayName(name);
  }
}

Future<void> _confirmDeleteAccount(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title:
          const Text('Delete account?', style: TextStyle(color: kTextPrimary)),
      content: const Text(
          'This removes your account and signs you out. Your habits and progress stay on this device — use "Reset all progress" to clear those. This cannot be undone.',
          style: TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kRed, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await auth.deleteAccount();
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }
}

// ── Shell: bottom nav + the 5 screens ───────────────────────────────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _briefingChecked = false;
  Timer? _reminderTimer;
  final Set<String> _firedReminders = {}; // "date|habitId" already nudged today

  @override
  void initState() {
    super.initState();
    _reminderTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkReminders());
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkReminders());
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    super.dispose();
  }

  // In-app reminders while the app is open: nudge once per habit per day when
  // its time has passed and it isn't done. (OS-level notifications on iOS get
  // wired on top of the same reminderMinutes later.)
  void _checkReminders() {
    if (!mounted) return;
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    final day = dateKey(now);
    for (final h in appState.habits) {
      final rm = h.reminderMinutes;
      if (rm == null || nowMin < rm || appState.doneToday(h)) continue;
      final key = '$day|${h.id}';
      if (_firedReminders.contains(key)) continue;
      _firedReminders.add(key);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('⏰ Time for: ${h.name}'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
            label: 'Done',
            onPressed: () {
              if (!appState.doneToday(h)) appState.toggle(h);
            }),
      ));
    }
  }

  Widget? _fab() {
    if (_index == 0) {
      return GradientButton(
          label: 'Add habit',
          icon: Icons.add,
          expand: false,
          onPressed: () => showHabitEditor(context));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (appState.loading) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!_briefingChecked && appState.needsBriefing) {
          _briefingChecked = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const _DailyBriefing(),
            );
          });
        }
        // Build fresh instances each time so the screens reflect state changes.
        // (A const list would canonicalize them and Flutter would skip rebuilds,
        // which is why completed habits weren't showing their checked state.)
        // ignore: prefer_const_constructors, prefer_const_literals_to_create_immutables
        final screens = <Widget>[HomeScreen(), FocusScreen(), ProgressScreen(), FriendsScreen(), SettingsScreen()];
        return Scaffold(
          body: IndexedStack(index: _index, children: screens),
          floatingActionButton: _fab(),
          bottomNavigationBar: HrTabBar(
            index: _index,
            onTap: (i) => setState(() => _index = i),
          ),
        );
      },
    );
  }
}

// _BottomNav and _NavItem were replaced by HrTabBar (the 5-tab redesign).

// ── Reusable app bar with the coins pill ────────────────────────────────────
// A circular profile picture (or the user's initial) wrapped in the selected
// border. Used in the app bar and on the account/settings screens.
class _Avatar extends StatelessWidget {
  const _Avatar({this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = borderById(appState.selectedBorder);
    final hasBorder = b.id != 'none';
    // Thicker, glowing ring with a thin dark gap so the colour reads as a
    // distinct border against both the avatar and the cosmic background.
    final ringW = hasBorder
        ? (size * 0.11).clamp(3.0, 7.0)
        : (size * 0.06).clamp(2.0, 4.0);
    final gapW = hasBorder ? (size * 0.03).clamp(1.5, 3.0) : 0.0;
    final inner = size - (ringW + gapW) * 2;
    final name = appState.displayName;
    final Widget pic = appState.pfpBytes != null
        ? Image.memory(appState.pfpBytes!,
            width: inner, height: inner, fit: BoxFit.cover, gaplessPlayback: true)
        : Container(
            width: inner,
            height: inner,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                gradient: LinearGradient(colors: [kPlasma, kBlue])),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: inner * 0.42,
                    fontWeight: FontWeight.w800)),
          );
    Widget avatar = ClipOval(child: pic);
    // Dark separator ring between the colour and the avatar.
    if (gapW > 0) {
      avatar = Container(
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: Color(0xFF140B2B)),
        padding: EdgeInsets.all(gapW),
        child: avatar,
      );
    }
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ringW),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: b.colors.length == 1 ? b.colors.first : null,
        gradient: b.colors.length > 1
            ? SweepGradient(colors: [...b.colors, b.colors.first])
            : null,
        boxShadow: b.glow
            ? [
                BoxShadow(
                    color: b.colors.first.withValues(alpha: 0.75),
                    blurRadius: size * 0.3,
                    spreadRadius: 1.0)
              ]
            : null,
      ),
      child: avatar,
    );
  }
}

// A preview ring of a specific border (for the Shop), independent of the
// currently-selected one.
Widget _borderPreview(BorderDef b, {double size = 42}) {
  final ringW = (size * 0.1).clamp(2.0, 5.0);
  return Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(ringW),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: b.colors.length == 1 ? b.colors.first : null,
      gradient: b.colors.length > 1
          ? SweepGradient(colors: [...b.colors, b.colors.first])
          : null,
      boxShadow: b.glow
          ? [BoxShadow(color: b.colors.first.withValues(alpha: 0.5), blurRadius: 8)]
          : null,
    ),
    child: const DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: kElevated)),
  );
}

// Pick a photo, center-crop + downscale to a tiny JPEG, and store it.
Future<void> _pickProfilePhoto(BuildContext context) async {
  try {
    final x = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      if (context.mounted) _toast(context, "Couldn't read that image.");
      return;
    }
    final side = decoded.width < decoded.height ? decoded.width : decoded.height;
    final cropped = img.copyCrop(decoded,
        x: (decoded.width - side) ~/ 2,
        y: (decoded.height - side) ~/ 2,
        width: side,
        height: side);
    final resized = img.copyResize(cropped, width: 256, height: 256);
    appState.setPfp(base64Encode(img.encodeJpg(resized, quality: 82)));
  } catch (_) {
    if (context.mounted) _toast(context, "Couldn't pick a photo.");
  }
}

// "Change photo" / "Remove" actions shown under the account avatar.
Widget _photoActions(BuildContext context) => Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _secondaryPill('Change photo', () => _pickProfilePhoto(context)),
        if (appState.pfpBase64.isNotEmpty) ...[
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => appState.setPfp(''),
            child:
                const Text('Remove', style: TextStyle(color: kTextTertiary)),
          ),
        ],
      ],
    );

// Coins pill (→ Shop).
Widget _coinsPill(BuildContext context) => GestureDetector(
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ShopScreen())),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: kElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kBorder),
        ),
        child: Row(children: [
          if (appState.xpBoostActive) ...[
            Text('2×',
                style: TextStyle(
                    color: kPlasmaGlow,
                    fontWeight: FontWeight.bold,
                    fontSize: 12)),
            const SizedBox(width: 6),
          ],
          const Icon(Icons.bolt, size: 16, color: kGold),
          const SizedBox(width: 5),
          Text('${appState.coins}',
              style: const TextStyle(color: kGold, fontWeight: FontWeight.bold)),
        ]),
      ),
    );

Widget _shopButton(BuildContext context) => IconButton(
      icon:
          const Icon(Icons.storefront_rounded, color: kTextTertiary, size: 20),
      tooltip: 'Shop',
      onPressed: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ShopScreen())),
    );

// ── Glass phase-2 helpers ───────────────────────────────────────────────────

// Glass surface with a top sheen (brighter top → darker bottom), luminous edge,
// and soft shadow. Drop-in for a card's BoxDecoration.
const LinearGradient _kGlassSheen = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xE02A1B4F), Color(0xCC170B2E)],
);

BoxDecoration glassDecoration({double radius = 18, Color? border}) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: _kGlassSheen,
      border: Border.all(color: border ?? kBorder),
      boxShadow: const [
        BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8)),
      ],
    );

const List<Color> _kAccentGradient = [Color(0xFF8B5CF6), Color(0xFF22D3EE)];

// Violet → cyan gradient primary button.
class GradientButton extends StatelessWidget {
  const GradientButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 52,
    this.expand = true,
    super.key,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: expand ? 0 : 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(colors: _kAccentGradient),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Luminous gradient progress bar.
class GlowBar extends StatelessWidget {
  const GlowBar({required this.value, this.height = 8, this.colors, super.key});
  final double value; // 0..1
  final double height;
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final c = colors ?? _kAccentGradient;
    final v = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: v),
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Color(0x22FFFFFF))),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: c),
                  boxShadow: [
                    BoxShadow(color: c.last.withValues(alpha: 0.5), blurRadius: 6),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// Luminous gradient progress ring.
class GlowRing extends StatelessWidget {
  const GlowRing(
      {required this.value,
      required this.size,
      this.stroke = 6,
      this.colors,
      super.key});
  final double value;
  final double size;
  final double stroke;
  final List<Color>? colors;
  @override
  Widget build(BuildContext context) {
    final target = value.clamp(0.0, 1.0).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, _) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(animatedValue, stroke, colors ?? _kAccentGradient),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.stroke, this.colors);
  final double value;
  final double stroke;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = const Color(0x1FFFFFFF));
    if (value <= 0) return;
    final sweep = 2 * pi * value;
    final ring = colors.length > 1 ? colors : [colors.first, colors.first];
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [...ring, ring.first],
        transform: const GradientRotation(-pi / 2),
      ).createShader(rect);
    canvas.drawArc(
        rect,
        -pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = ring.last.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawArc(rect, -pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.colors != colors || old.stroke != stroke;
}

// Dashboard app bar: profile picture + level on the LEFT, coins + shop RIGHT.
PreferredSizeWidget _dashboardBar() {
  return AppBar(
    backgroundColor: Colors.transparent,
    automaticallyImplyLeading: false,
    titleSpacing: 14,
    title: Builder(
      builder: (context) => GestureDetector(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        child: ListenableBuilder(
          listenable: appState,
          builder: (_, _) {
            final ld = levelFromXp(appState.totalXp);
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _Avatar(size: 38),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lv.${ld.level}',
                      style: GoogleFonts.spaceGrotesk(
                          color: kTextPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          height: 1.1)),
                  const SizedBox(height: 3),
                  SizedBox(
                    width: 96,
                    child: GlowBar(
                        value: ld.progress.clamp(0.0, 1.0).toDouble(),
                        height: 6),
                  ),
                ],
              ),
            ]);
          },
        ),
      ),
    ),
    actions: [
      Builder(builder: (context) => _coinsPill(context)),
      Builder(builder: (context) => _shopButton(context)),
      const SizedBox(width: 8),
    ],
  );
}

// Standard app bar for the other tabs: title left; coins + shop + avatar right.
PreferredSizeWidget _titleBar(String title) {
  return AppBar(
    backgroundColor: Colors.transparent,
    title: title.isEmpty
        ? null
        : Text(title,
            style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
                color: kTextPrimary)),
    actions: [
      Builder(builder: (context) => _coinsPill(context)),
      Builder(builder: (context) => _shopButton(context)),
      Builder(
        builder: (context) => Padding(
          padding: const EdgeInsets.only(right: 12, left: 2),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: ListenableBuilder(
                listenable: appState,
                builder: (_, _) => _Avatar(size: 34)),
          ),
        ),
      ),
    ],
  );
}

// ── HOME ────────────────────────────────────────────────────────────────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void onToggle(Habit h) {
      final old = appState.level;
      final oldStreak = h.streak;
      final doneBefore = appState.doneTodayCount;
      final total = appState.habits.length;
      final wasDone = appState.doneToday(h);
      appState.toggle(h);
      if (!wasDone) {
        HapticFeedback.selectionClick();
        final reward = h.todayAwardXp;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(milliseconds: 1100),
            content: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.bolt_rounded, color: kGold, size: 18),
              const SizedBox(width: 8),
              Text('Habit complete  ·  +$reward XP',
                  style: const TextStyle(color: kTextPrimary,
                      fontWeight: FontWeight.w600)),
            ]),
          ));
      }
      final who = appState.activeCompanion;
      bool shownMajor = false;
      if (appState.consumeBossDefeat()) {
        appState.setCompanionLine(companionLine(who, 'boss_defeat'));
        celebrate(context);
        if (appState.consumeSeasonIntro()) {
          _showSeasonIntro(context);
        } else {
          _showBossDefeat(context);
        }
        shownMajor = true;
      } else if (appState.level > old) {
        appState.setCompanionLine(companionLine(who, 'level_up'));
        celebrate(context);
        _showLevelUp(context, appState.level);
        shownMajor = true;
      } else {
        if (h.streak == 30 && oldStreak != 30) {
          appState.setCompanionLine(companionLine(who, 'streak_30'));
        } else if (h.streak == 7 && oldStreak != 7) {
          appState.setCompanionLine(companionLine(who, 'streak_7'));
        } else if (appState.victory().score >= 90) {
          appState.setCompanionLine(companionLine(who, 'elite_day'));
        }
        // A perfect day just completed → a little confetti.
        if (total > 0 && doneBefore < total && appState.doneTodayCount == total) {
          celebrate(context);
        }
      }
      // Celebrate any freshly-unlocked achievements — unless a bigger popup is
      // already showing, in which case they stay queued for the next toggle.
      if (!shownMajor) {
        final newAch = appState.consumeNewAchievements();
        if (newAch.isNotEmpty) {
          celebrate(context);
          _showAchievementUnlocked(context, newAch);
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _dashboardBar(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const _DashboardHero(),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Row(children: [
              Expanded(
                child: Text('TODAY’S HABITS',
                    style: TextStyle(color: kTextTertiary, fontSize: 12,
                        letterSpacing: 1.5, fontWeight: FontWeight.bold)),
              ),
              Text('Tap to complete',
                  style: TextStyle(color: kTextTertiary, fontSize: 11)),
            ]),
          ),
          if (appState.habits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: _EmptyState(
                  emoji: '🌱',
                  title: 'No habits yet',
                  subtitle: 'Tap “Add habit” to start.'),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: appState.habits.length,
              onReorderItem: appState.reorderHabits,
              itemBuilder: (ctx, i) {
                final h = appState.habits[i];
                return Padding(
                  key: ValueKey('habit-${h.id}'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _HabitTile(
                    habit: h,
                    done: appState.doneToday(h),
                    onToggle: () => onToggle(h),
                    onDelete: () => appState.deleteHabit(h),
                    onEdit: () => showHabitEditor(context, h),
                    reorderIndex: i,
                  ),
                );
              },
            ),
          const SizedBox(height: 12),
          const _VictoryCard(),
          const _CompanionCard(),
          const _NutritionCard(),
          const _BossCard(),
          const _QuestsPanel(),
          const _PrestigeCard(),
        ],
      ),
    );
  }
}

// Greeting hero at the top of the dashboard: time-aware greeting, name,
// today's completion ring, streak chip, and a motivating nudge.
class _DashboardHero extends StatelessWidget {
  const _DashboardHero();
  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    final name = appState.displayName;
    final total = appState.habits.length;
    final done = appState.doneTodayCount;
    final pct = total == 0 ? 0.0 : done / total;
    final allDone = total > 0 && done == total;
    final streak = appState.bestStreak;
    final sub = total == 0
        ? 'Add your first habit to begin.'
        : allDone
            ? 'Perfect day — every habit done!'
            : done == 0
                ? "Let's get the first one done."
                : '${total - done} to go — finish strong.';
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF301C62), Color(0xFF1A0F38)]),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
              color: kPlasma.withValues(alpha: 0.18),
              blurRadius: 26,
              offset: const Offset(0, 10)),
        ],
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(greeting,
                  style: const TextStyle(color: kTextTertiary, fontSize: 13)),
              const SizedBox(height: 2),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                      color: kTextPrimary,
                      fontSize: 24,
                      height: 1.05,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              if (streak > 0) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: kGold.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: kGold.withValues(alpha: 0.35)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('🔥', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 5),
                    Text('$streak day streak',
                        style: const TextStyle(
                            color: kGold,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              Text(sub,
                  style: const TextStyle(
                      color: kTextSecondary, fontSize: 13, height: 1.3)),
            ],
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 78,
          height: 78,
          child: Stack(alignment: Alignment.center, children: [
            GlowRing(
              value: pct,
              size: 78,
              stroke: 7,
              colors: allDone
                  ? [kGreen, const Color(0xFF8BF0C0)]
                  : [kPlasma, kCyan],
            ),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$done/$total',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 18,
                      height: 1,
                      fontWeight: FontWeight.w800)),
              const Text('today',
                  style: TextStyle(
                      color: kTextTertiary, fontSize: 9, letterSpacing: 0.5)),
            ]),
          ]),
        ),
      ]),
        ),
      ),
    );
  }
}

class _VictoryCard extends StatelessWidget {
  const _VictoryCard();
  @override
  Widget build(BuildContext context) {
    final v = appState.victory();
    final color = victoryColor(v.score);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(children: [
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(alignment: Alignment.center, children: [
            GlowRing(
              value: v.score / 100,
              size: 64,
              stroke: 6,
              colors: [color, Color.lerp(color, Colors.white, 0.35)!],
            ),
            Text('${v.score}',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('VICTORY SCORE',
                  style: TextStyle(
                      color: kTextTertiary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(victoryLabel(v.score),
                  style: TextStyle(
                      color: color, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                  'Habits ${v.habits} · Nutr ${v.nutrition} · Focus ${v.focus} · Sleep ${v.sleep}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11)),
            ],
          ),
        ),
      ]),
    );
  }
}

class _BossCard extends StatelessWidget {
  const _BossCard();
  @override
  Widget build(BuildContext context) {
    final count = appState.perfectDaysThisWeek().clamp(0, kBossGoal);
    final defeated = count >= kBossGoal;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration:
          glassDecoration(radius: 16, border: defeated ? kGold : kBorder),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.shield_rounded, color: kGold, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(kBossTitle,
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            Text(defeated ? 'DEFEATED' : '$count/$kBossGoal',
                style: TextStyle(
                    color: defeated ? kGold : kTextSecondary,
                    fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 10),
          GlowBar(
              value: (count / kBossGoal).clamp(0.0, 1.0).toDouble(),
              height: 8,
              colors: const [Color(0xFFFBBF24), Color(0xFFFCD34D)]),
          const SizedBox(height: 8),
          Text(
              defeated
                  ? 'Reward claimed: +$kBossXp XP · +$kBossCoins coins'
                  : '$kBossDesc  (+$kBossXp XP, +$kBossCoins coins)',
              style: const TextStyle(color: kTextTertiary, fontSize: 11)),
          const SizedBox(height: 8),
          Text(
              'Season ${appState.currentSeason + 1} · ${appState.seasonBossDefeats}/4 bosses',
              style: const TextStyle(
                  color: kCyan, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _QuestsPanel extends StatelessWidget {
  const _QuestsPanel();
  @override
  Widget build(BuildContext context) {
    final claimed = appState.questClaimedIds;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('DAILY QUESTS',
                  style: TextStyle(
                      color: kTextTertiary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              Text('${claimed.length}/${kQuests.length}',
                  style:
                      const TextStyle(color: kCyan, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          ...kQuests.map((q) {
            final on = claimed.contains(q.id);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 18, color: on ? kGreen : kTextTertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(q.title,
                      style: TextStyle(
                        color: on ? kTextTertiary : kTextPrimary,
                        fontSize: 13,
                        decoration: on ? TextDecoration.lineThrough : null,
                      )),
                ),
                Text('+${q.xp}',
                    style: TextStyle(
                        color: on ? kGreen : kPlasmaGlow,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

void _showBossDefeat(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF3A2A08), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kGold),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_rounded, color: kGold, size: 44),
            const SizedBox(height: 10),
            const Text('BOSS DEFEATED',
                style: TextStyle(
                    color: kGold,
                    fontSize: 18,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Weekly Sovereignty Challenge',
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 14),
            Text('+$kBossXp XP   ·   +$kBossCoins coins',
                style: TextStyle(
                    color: kPlasmaGlow, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(companionLine(appState.activeCompanion, 'boss_defeat'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Claim'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.habit,
    required this.done,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
    this.reorderIndex,
  });
  final Habit habit;
  final bool done;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final int? reorderIndex; // when set, shows a drag handle for reordering

  @override
  Widget build(BuildContext context) {
    final rc = rarityConfig[habit.rarity];
    final rarityColor = rc?.color ?? kTextTertiary;
    return Dismissible(
      key: ValueKey(habit.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
            color: const Color(0xFF3A1020),
            borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.delete_outline, color: Color(0xFFFB7185)),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: done ? kPlasma : kBorder),
        ),
        child: ListTile(
          onTap: onToggle,
          onLongPress: onEdit,
          leading: AnimatedScale(
            scale: done ? 1 : 0.94,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? kPlasma : Colors.transparent,
                border: Border.all(
                    color: done ? kPlasma : const Color(0x4DFFFFFF), width: 2),
                boxShadow: done
                    ? [BoxShadow(color: kPlasma.withValues(alpha: 0.32), blurRadius: 10)]
                    : null,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 140),
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: done
                    ? const Icon(Icons.check, key: ValueKey('checked'), size: 18, color: Colors.white)
                    : const SizedBox(key: ValueKey('unchecked')),
              ),
            ),
          ),
          title: Text(
              habit.icon.isEmpty ? habit.name : '${habit.icon}  ${habit.name}',
              style: TextStyle(
                color: done ? kTextTertiary : kTextPrimary,
                decoration: done ? TextDecoration.lineThrough : null,
                fontWeight: FontWeight.w500,
              )),
          subtitle: Row(children: [
            Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: rarityColor)),
            const SizedBox(width: 6),
            Text(rc?.label ?? 'Common',
                style: TextStyle(color: rarityColor, fontSize: 11)),
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (habit.reminderMinutes != null)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.notifications_active_rounded,
                    size: 15, color: kTextTertiary),
              ),
            if (habit.streak > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: const Color(0x268B5CF6),
                    borderRadius: BorderRadius.circular(20)),
                child: Text('🔥 ${habit.streak}',
                    style: TextStyle(
                        color: kPlasmaGlow, fontWeight: FontWeight.bold)),
              ),
            if (reorderIndex != null)
              ReorderableDragStartListener(
                index: reorderIndex!,
                child: const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.drag_indicator, color: kTextTertiary),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

// ── FOCUS ───────────────────────────────────────────────────────────────────
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});
  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  int _minutes = 25;
  int _remaining = 25 * 60;
  bool _running = false;
  bool _started = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setMinutes(int m) {
    if (_started) return;
    setState(() {
      _minutes = m;
      _remaining = m * 60;
    });
  }

  void _start() {
    setState(() {
      _running = true;
      _started = true;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        final gain = appState.completeFocus(_minutes);
        setState(() {
          _running = false;
          _started = false;
          _remaining = _minutes * 60;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kElevated,
            content: Text('Focus complete! +$gain XP',
                style: TextStyle(color: kPlasmaGlow)),
          ));
        }
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _running = false);
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _running = false;
      _started = false;
      _remaining = _minutes * 60;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Focus'),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Wrap(
              spacing: 10,
              children: [15, 25, 50].map((m) {
                final sel = m == _minutes;
                return ChoiceChip(
                  label: Text('$m min'),
                  selected: sel,
                  onSelected: _started ? null : (_) => _setMinutes(m),
                  selectedColor: kPlasma,
                  backgroundColor: kCard,
                  labelStyle: TextStyle(
                      color: sel ? Colors.white : kTextSecondary),
                  side: const BorderSide(color: kBorder),
                );
              }).toList(),
            ),
            const SizedBox(height: 32),
            Stack(
              alignment: Alignment.center,
              children: [
                GlowRing(
                  value: 1 - _remaining / (_minutes * 60),
                  size: 250,
                  stroke: 4,
                  colors: _running ? [kCyan, kPlasmaBright] : null,
                ),
                Container(
              width: 230,
              height: 230,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                    colors: [Color(0xFF2A1458), Color(0xFF0B0420)]),
                border: Border.all(color: kPlasma, width: 2),
              ),
              child: Text('$mm:$ss',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 52,
                      fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: kPlasma,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
                onPressed: _running ? _pause : _start,
                icon: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                label: Text(_started ? (_running ? 'Pause' : 'Resume') : 'Start focus'),
              ),
              if (_started) ...[
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Reset session',
                  onPressed: _reset,
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
            ]),
            const SizedBox(height: 10),
            Text(_started ? (_running ? 'Session in progress' : 'Session paused') : 'Finish a session to earn XP',
                style: const TextStyle(color: kTextTertiary, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── STATS ───────────────────────────────────────────────────────────────────
// ── PROGRESS (Stats · Awards · Journal) ─────────────────────────────────────
// Folds the old Stats, Awards and Journal tabs behind one segmented control.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});
  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int _seg = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Progress'),
      floatingActionButton: _seg == 2
          ? GradientButton(
              label: 'Reflect',
              icon: Icons.edit,
              expand: false,
              onPressed: () => showAddReflection(context))
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: HrSegmented(
            items: const ['Stats', 'Awards', 'Journal'],
            index: _seg,
            onChanged: (i) => setState(() => _seg = i),
          ),
        ),
        Expanded(
          // ignore: prefer_const_constructors, prefer_const_literals_to_create_immutables
          child: IndexedStack(index: _seg, children: <Widget>[
            StatsScreen(embedded: true),
            AwardsScreen(embedded: true),
            JournalScreen(embedded: true),
          ]),
        ),
      ]),
    );
  }
}

class StatsScreen extends StatelessWidget {
  const StatsScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final stats = <(String, String, Color, IconData)>[
      ('Level', '${ld.level}', kPlasmaBright, Icons.military_tech_rounded),
      ('Title', levelTitle(ld.level), kCyan, Icons.star_rounded),
      ('Total XP', '${appState.totalXp}', kPlasma, Icons.bolt_rounded),
      ('Coins', '${appState.coins}', kGold, Icons.savings_rounded),
      ('Habits', '${appState.habits.length}', kBlue, Icons.widgets_rounded),
      ('Done today', '${appState.doneTodayCount}', kCyan,
          Icons.check_circle_rounded),
      ('Best streak', '${appState.bestStreak}', const Color(0xFFFB7185),
          Icons.local_fire_department_rounded),
      ('Reflections', '${appState.reflections.length}', kPlasmaGlow,
          Icons.menu_book_rounded),
      ('Perfect days', '${appState.totalPerfectDays}', kGreen,
          Icons.verified_rounded),
      ('Avg score 7d', '${appState.avgScoreLastDays(7).round()}',
          kPlasmaBright, Icons.trending_up_rounded),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: embedded ? null : _titleBar('Stats'),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LegacyScreen())),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      gradient: _kGlassSheen,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kBorder)),
                  child: Row(children: [
                    const Icon(Icons.history_rounded, color: kCyan, size: 22),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text('Legacy Timeline',
                          style: TextStyle(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold)),
                    ),
                    Text('${appState.milestoneLog.length}',
                        style: const TextStyle(
                            color: kCyan, fontWeight: FontWeight.bold)),
                    const Icon(Icons.chevron_right, color: kTextTertiary),
                  ]),
                ),
              ),
            ),
          ),
          const _WeekTrendCard(),
          const _HeatmapCard(),
          const _HabitStreaksCard(),
          GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: stats
                .map((s) => _StatCard(
                    label: s.$1, value: s.$2, color: s.$3, icon: s.$4))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon});
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 22),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              Text(label,
                  style: const TextStyle(color: kTextTertiary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _HabitStreaksCard extends StatelessWidget {
  const _HabitStreaksCard();
  @override
  Widget build(BuildContext context) {
    final habits = [...appState.habits]
      ..sort((a, b) => b.streak.compareTo(a.streak));
    if (habits.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(Icons.local_fire_department_rounded, color: kGold, size: 18),
            SizedBox(width: 8),
            Text('Habit streaks',
                style: TextStyle(
                    color: kTextPrimary, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          ...habits.take(8).map((h) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Text(
                        h.icon.isEmpty ? h.name : '${h.icon}  ${h.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 13)),
                  ),
                  Text(h.streak > 0 ? '🔥 ${h.streak}' : '—',
                      style: TextStyle(
                          color: h.streak > 0 ? kPlasmaGlow : kTextTertiary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ]),
              )),
        ],
      ),
    );
  }
}

// ── SHARE CARD ───────────────────────────────────────────────────────────────
class ShareCardScreen extends StatefulWidget {
  const ShareCardScreen({super.key});
  @override
  State<ShareCardScreen> createState() => _ShareCardScreenState();
}

class _ShareCardScreenState extends State<ShareCardScreen> {
  final GlobalKey _cardKey = GlobalKey();
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final boundary =
          _cardKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final box = context.findRenderObject() as RenderBox?;
      final origin =
          box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ImageByteFormat.png);
      if (data == null) throw 'encode failed';
      final file = File(
          '${Directory.systemTemp.path}/habitrail_progress_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        text:
            "I'm Level ${appState.level} on Habitrail with a ${appState.bestStreak}-day streak! 🔥 Build habits, earn XP, level up.",
        sharePositionOrigin: origin,
      ));
    } catch (_) {
      if (mounted) _toast(context, "Couldn't share right now.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ld = levelFromXp(appState.totalXp);
        final v = appState.victory();
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: _titleBar('Share progress'),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Center(
                child: RepaintBoundary(
                  key: _cardKey,
                  child: Container(
                    width: 340,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF2A1458), Color(0xFF130A2A)]),
                      border: Border.all(color: kBorder),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('🔥', style: TextStyle(fontSize: 22)),
                            const SizedBox(width: 8),
                            Text('Habitrail',
                                style: GoogleFonts.spaceGrotesk(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 22),
                        _Avatar(size: 92),
                        const SizedBox(height: 14),
                        Text(appState.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.spaceGrotesk(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text('Level ${ld.level} · ${levelTitle(ld.level)}',
                            style: const TextStyle(
                                color: kTextTertiary, fontSize: 13)),
                        const SizedBox(height: 22),
                        Row(children: [
                          _shareStat('🔥', 'Streak', '${appState.bestStreak}'),
                          _shareStat('🏆', 'Victory', '${v.score}'),
                          _shareStat('⭐', 'Level', '${ld.level}'),
                        ]),
                        const SizedBox(height: 14),
                        Row(children: [
                          _shareStat('⚡', 'Total XP', '${appState.totalXp}'),
                          _shareStat(
                              '✅', 'Habits', '${appState.habits.length}'),
                          _shareStat('👑', 'Prestige', '${appState.prestige}'),
                        ]),
                        const SizedBox(height: 22),
                        const Text(
                            'Build habits. Earn XP. Level up your life.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: kTextTertiary, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              GradientButton(
                label: _busy ? 'Preparing…' : 'Share',
                icon: Icons.ios_share_rounded,
                onPressed: _busy ? null : _share,
              ),
              const SizedBox(height: 10),
              const Text('Share your card to show off your streak and level.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextTertiary, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

Widget _shareStat(String emoji, String label, String value) => Expanded(
      child: Column(children: [
        Text(emoji, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 4),
        Text(value,
            style: GoogleFonts.spaceGrotesk(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(color: kTextTertiary, fontSize: 10)),
      ]),
    );

// ── FRIENDS & LEADERBOARD ────────────────────────────────────────────────────

// A ranked entry (you or a friend) for the leaderboard.
class _Ranked {
  _Ranked(this.name, this.totalXp, this.streak, this.borderId, this.isMe,
      {this.friendId});
  final String name;
  final int totalXp;
  final int streak;
  final String borderId;
  final bool isMe;
  final String? friendId; // null for the current user
}

class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, friends]),
      builder: (context, _) {
        // Leaderboard = you + your friends, ranked by total XP.
        final board = <_Ranked>[
          _Ranked(appState.displayName, appState.totalXp, appState.bestStreak,
              appState.selectedBorder, true),
          ...friends.friends.map((f) => _Ranked(
              f.name, f.totalXp, f.streak, f.borderId, false,
              friendId: f.id)),
        ]..sort((a, b) => b.totalXp.compareTo(a.totalXp));
        final myRank = board.indexWhere((e) => e.isMe) + 1;
        final suggestions = friends.suggestions();
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: _titleBar('Friends'),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 110),
            children: [
              _friendsRankHero(myRank, board.length),
              const _AddFriendField(),
              _sectionLabel('LEADERBOARD'),
              for (int i = 0; i < board.length; i++)
                _leaderRow(context, i + 1, board[i]),
              _sectionLabel('YOUR FRIENDS'),
              if (friends.friends.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: _EmptyState(
                      emoji: '🧑‍🤝‍🧑',
                      title: 'No friends yet',
                      subtitle:
                          'Add a friend by username to compare progress.'),
                )
              else
                ...friends.friends.map((f) => _friendCard(context, f)),
              if (suggestions.isNotEmpty) ...[
                _sectionLabel('SUGGESTED'),
                ...suggestions.map((f) => _suggestionCard(context, f)),
              ],
            ],
          ),
        );
      },
    );
  }
}

// Avatar for an arbitrary name + border (friends have no photo of their own).
class _FriendAvatar extends StatelessWidget {
  const _FriendAvatar({required this.name, required this.borderId, this.size = 44});
  final String name;
  final String borderId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = borderById(borderId);
    final hasBorder = b.id != 'none';
    final ringW =
        hasBorder ? (size * 0.1).clamp(3.0, 6.0) : (size * 0.06).clamp(2.0, 4.0);
    final inner = size - ringW * 2;
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(ringW),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: b.colors.length == 1 ? b.colors.first : null,
        gradient: b.colors.length > 1
            ? SweepGradient(colors: [...b.colors, b.colors.first])
            : null,
        boxShadow: b.glow
            ? [
                BoxShadow(
                    color: b.colors.first.withValues(alpha: 0.6),
                    blurRadius: size * 0.22)
              ]
            : null,
      ),
      child: ClipOval(
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(gradient: LinearGradient(colors: [kPlasma, kBlue])),
          child: Text(letter,
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: inner * 0.42,
                  fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}

Widget _youTag() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: kPlasma.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(8)),
      child: Text('YOU',
          style: TextStyle(
              color: kPlasmaGlow,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5)),
    );

Widget _friendsRankHero(int rank, int total) {
  final medal = rank == 1
      ? '🥇'
      : rank == 2
          ? '🥈'
          : rank == 3
              ? '🥉'
              : '#$rank';
  return Container(
    margin: const EdgeInsets.fromLTRB(0, 6, 0, 4),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF301C62), Color(0xFF1A0F38)]),
      border: Border.all(color: kBorder),
      boxShadow: [
        BoxShadow(
            color: kPlasma.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 8)),
      ],
    ),
    child: Row(children: [
      _Avatar(size: 54),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('YOUR RANK',
                style: TextStyle(
                    color: kTextTertiary,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Text(rank == 1 ? 'Top of the board! 🎉' : "You're #$rank of $total",
                style: GoogleFonts.spaceGrotesk(
                    color: kTextPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
          ],
        ),
      ),
      Text(medal,
          style: GoogleFonts.spaceGrotesk(
              color: kGold, fontSize: 24, fontWeight: FontWeight.w800)),
    ]),
  );
}

Widget _leaderRow(BuildContext context, int rank, _Ranked e) {
  final ld = levelFromXp(e.totalXp);
  final label = rank == 1
      ? '🥇'
      : rank == 2
          ? '🥈'
          : rank == 3
              ? '🥉'
              : '$rank';
  final row = Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      gradient: _kGlassSheen,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
          color: e.isMe ? kPlasma : kBorder, width: e.isMe ? 1.5 : 1),
    ),
    child: Row(children: [
      SizedBox(
        width: 26,
        child: Text(label,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
                color: rank <= 3 ? kGold : kTextTertiary,
                fontSize: rank <= 3 ? 18 : 14,
                fontWeight: FontWeight.w800)),
      ),
      const SizedBox(width: 8),
      e.isMe
          ? _Avatar(size: 40)
          : _FriendAvatar(name: e.name, borderId: e.borderId, size: 40),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Flexible(
                child: Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: kTextPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
              ),
              if (e.isMe) ...[const SizedBox(width: 6), _youTag()],
            ]),
            const SizedBox(height: 2),
            Text('Lv.${ld.level} · ${levelTitle(ld.level)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kTextTertiary, fontSize: 11)),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${e.totalXp}',
              style: GoogleFonts.spaceGrotesk(
                  color: kGold, fontSize: 15, fontWeight: FontWeight.w800)),
          const Text('XP', style: TextStyle(color: kTextTertiary, fontSize: 9)),
        ],
      ),
    ]),
  );
  return e.friendId == null
      ? row
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FriendProfileScreen(friendId: e.friendId!))),
          child: row,
        );
}

Widget _friendCard(BuildContext context, Friend f) {
  final ld = levelFromXp(f.totalXp);
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FriendProfileScreen(friendId: f.id))),
    child: Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: _kGlassSheen,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: kBorder),
    ),
    child: Row(children: [
      _FriendAvatar(name: f.name, borderId: f.borderId, size: 46),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Flexible(
                child: Text(f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: kTextPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
              if (f.prestige > 0) ...[
                const SizedBox(width: 6),
                Text('★${f.prestige}',
                    style: const TextStyle(
                        color: kGold,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ],
            ]),
            const SizedBox(height: 2),
            Text('@${f.username}',
                style: TextStyle(
                    color: kPlasmaBright,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(children: [
              Text('Lv.${ld.level}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11)),
              const SizedBox(width: 10),
              const Text('🔥', style: TextStyle(fontSize: 11)),
              const SizedBox(width: 3),
              Text('${f.streak}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11)),
            ]),
          ],
        ),
      ),
      IconButton(
        icon: const Icon(Icons.person_remove_rounded,
            color: kTextTertiary, size: 20),
        tooltip: 'Remove',
        onPressed: () => _confirmRemoveFriend(context, f),
      ),
    ]),
    ),
  );
}

Widget _suggestionCard(BuildContext context, Friend f) {
  final ld = levelFromXp(f.totalXp);
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: _kGlassSheen,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: kBorder),
    ),
    child: Row(children: [
      _FriendAvatar(name: f.name, borderId: f.borderId, size: 42),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: kTextPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(height: 2),
            Text('@${f.username} · Lv.${ld.level}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kTextTertiary, fontSize: 11)),
          ],
        ),
      ),
      const SizedBox(width: 8),
      GradientButton(
        label: 'Add',
        expand: false,
        height: 40,
        onPressed: () async {
          final err = await friends.addByUsername(f.username);
          if (!context.mounted) return;
          _toast(context, err ?? 'Added @${f.username}');
        },
      ),
    ]),
  );
}

void _confirmRemoveFriend(BuildContext context, Friend f) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kElevated,
      title: Text('Remove ${f.name}?',
          style: const TextStyle(color: kTextPrimary)),
      content: Text('You can add @${f.username} again any time.',
          style: const TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kRed),
          onPressed: () {
            friends.remove(f.id);
            Navigator.pop(ctx);
          },
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

class _AddFriendField extends StatefulWidget {
  const _AddFriendField();
  @override
  State<_AddFriendField> createState() => _AddFriendFieldState();
}

class _AddFriendFieldState extends State<_AddFriendField> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final u = _c.text.trim();
    final err = await friends.addByUsername(u);
    if (!mounted) return;
    if (err != null) {
      _toast(context, err);
      return;
    }
    _c.clear();
    FocusScope.of(context).unfocus();
    _toast(context, 'Added @$u');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _c,
            onSubmitted: (_) => _add(),
            textInputAction: TextInputAction.done,
            style: const TextStyle(color: kTextPrimary),
            decoration: const InputDecoration(
              hintText: 'Add a friend by username',
              prefixIcon: Icon(Icons.alternate_email_rounded, size: 18),
            ),
          ),
        ),
        const SizedBox(width: 10),
        GradientButton(label: 'Add', expand: false, onPressed: _add),
      ]),
    );
  }
}

// Full profile / stat card for a friend (opened by tapping a friend).
class FriendProfileScreen extends StatelessWidget {
  const FriendProfileScreen({super.key, required this.friendId});
  final String friendId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, friends]),
      builder: (context, _) {
        final matches = friends.friends.where((x) => x.id == friendId).toList();
        final f = matches.isEmpty ? null : matches.first;
        if (f == null) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
                backgroundColor: Colors.transparent,
                foregroundColor: kTextPrimary),
            body: const Center(
                child: Text('This friend was removed.',
                    style: TextStyle(color: kTextTertiary))),
          );
        }
        final ld = levelFromXp(f.totalXp);
        final myXp = appState.totalXp;
        final ranked = [myXp, ...friends.friends.map((x) => x.totalXp)]
          ..sort((a, b) => b.compareTo(a));
        final rank = ranked.indexOf(f.totalXp) + 1;
        final diff = f.totalXp - myXp;
        final cmp = diff == 0
            ? "You're dead even — go break the tie!"
            : diff > 0
                ? '${f.name} leads you by $diff XP.'
                : 'You lead ${f.name} by ${-diff} XP.';
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: kTextPrimary,
            title: Text(f.name,
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2A1458), Color(0xFF160B2E)]),
                  border: Border.all(color: kBorder),
                ),
                child: Column(children: [
                  _FriendAvatar(name: f.name, borderId: f.borderId, size: 96),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(
                      child: Text(f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.spaceGrotesk(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w800)),
                    ),
                    if (f.prestige > 0) ...[
                      const SizedBox(width: 8),
                      Text('★${f.prestige}',
                          style: const TextStyle(
                              color: kGold,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Text('@${f.username}',
                      style: TextStyle(
                          color: kPlasmaBright,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('Level ${ld.level} · ${levelTitle(ld.level)}',
                      style:
                          const TextStyle(color: kTextTertiary, fontSize: 13)),
                  const SizedBox(height: 20),
                  Row(children: [
                    _shareStat('⭐', 'Level', '${ld.level}'),
                    _shareStat('⚡', 'Total XP', '${f.totalXp}'),
                    _shareStat('🔥', 'Streak', '${f.streak}'),
                  ]),
                  const SizedBox(height: 14),
                  Row(children: [
                    _shareStat('👑', 'Prestige', '${f.prestige}'),
                    _shareStat('🏅', 'Rank', '#$rank'),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: _kGlassSheen,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('COMPARED TO YOU',
                        style: TextStyle(
                            color: kTextTertiary,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(cmp,
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 13, height: 1.3)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: kElevated,
                    title: Text('Remove ${f.name}?',
                        style: const TextStyle(color: kTextPrimary)),
                    content: Text('You can add @${f.username} again any time.',
                        style: const TextStyle(color: kTextSecondary)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: kRed),
                        onPressed: () {
                          friends.remove(f.id);
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                ),
                icon: const Icon(Icons.person_remove_rounded,
                    size: 18, color: kRed),
                label:
                    const Text('Remove friend', style: TextStyle(color: kRed)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── AWARDS (achievements) ────────────────────────────────────────────────────
class AwardsScreen extends StatelessWidget {
  const AwardsScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final unlocked =
        kAchievements.where((a) => appState.isAchievementEarned(a)).length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: embedded ? null : _titleBar('Awards'),
      body: Column(
        children: [
          _awardsHero(unlocked, kAchievements.length),
          Expanded(
            child: GridView.count(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.95,
              children:
                  kAchievements.map((a) => _AchievementCard(a)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// Awards progress hero: gold ring + unlocked count.
Widget _awardsHero(int unlocked, int total) {
  final pct = total == 0 ? 0.0 : unlocked / total;
  return Container(
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E1A5C), Color(0xFF1A0F38)]),
      border: Border.all(color: kGold.withValues(alpha: 0.25)),
      boxShadow: [
        BoxShadow(
            color: kGold.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8)),
      ],
    ),
    child: Row(children: [
      SizedBox(
        width: 70,
        height: 70,
        child: Stack(alignment: Alignment.center, children: [
          GlowRing(
              value: pct,
              size: 70,
              stroke: 7,
              colors: [kGold, const Color(0xFFFFE08A)]),
          Text('$unlocked',
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800)),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ACHIEVEMENTS',
                style: TextStyle(
                    color: kTextTertiary,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('$unlocked of $total unlocked',
                style: GoogleFonts.spaceGrotesk(
                    color: kTextPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
                unlocked >= total
                    ? 'Legend — every award earned!'
                    : 'Keep building habits to unlock them all.',
                style: const TextStyle(
                    color: kTextSecondary, fontSize: 12.5, height: 1.3)),
          ],
        ),
      ),
    ]),
  );
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard(this.a);
  final Achievement a;

  @override
  Widget build(BuildContext context) {
    final on = appState.isAchievementEarned(a);
    final cfg = rarityConfig[a.rarity];
    final color = cfg?.color ?? kTextTertiary;
    final rarity = (cfg?.label ?? a.rarity).toUpperCase();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: on ? color.withValues(alpha: 0.7) : kBorder,
            width: on ? 1.5 : 1),
        boxShadow: on
            ? [
                BoxShadow(
                    color: color.withValues(alpha: 0.22),
                    blurRadius: 18,
                    spreadRadius: -2)
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: on
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        color.withValues(alpha: 0.4),
                        color.withValues(alpha: 0.12)
                      ])
                  : null,
              color: on ? null : const Color(0x14FFFFFF),
              border: Border.all(
                  color: on ? color.withValues(alpha: 0.5) : kBorder),
              boxShadow: on
                  ? [
                      BoxShadow(
                          color: color.withValues(alpha: 0.4), blurRadius: 14)
                    ]
                  : null,
            ),
            child: Icon(on ? a.icon : Icons.lock_outline_rounded,
                size: 26, color: on ? color : kTextTertiary),
          ),
          const SizedBox(height: 10),
          Text(a.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: on ? Colors.white : kTextSecondary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5)),
          const SizedBox(height: 6),
          on
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(rarity,
                      style: TextStyle(
                          color: color,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8)),
                )
              : Text(a.description,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: kTextTertiary, fontSize: 10.5)),
        ],
      ),
    );
  }
}

// ── JOURNAL ─────────────────────────────────────────────────────────────────
class JournalScreen extends StatelessWidget {
  const JournalScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final items = appState.reflections;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: embedded ? null : _titleBar('Journal'),
      body: items.isEmpty
          ? const _EmptyState(
              emoji: '📓',
              title: 'No reflections yet',
              subtitle: 'Tap “Reflect” to write one (+20 XP).')
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final r = items[i];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.date,
                          style: const TextStyle(
                              color: kCyan,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(r.text,
                          style: const TextStyle(color: kTextPrimary)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.emoji, required this.title, required this.subtitle});
  final String emoji;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        decoration: glassDecoration(radius: 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: _kAccentGradient),
                boxShadow: [
                  BoxShadow(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
                      blurRadius: 22,
                      spreadRadius: 1),
                ],
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 36)),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: GoogleFonts.spaceGrotesk(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextTertiary, fontSize: 13, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

void _showLevelUp(BuildContext context, int level) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF2A1458), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kPlasmaBright),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('⚡ LEVEL UP',
                style: TextStyle(
                    color: kPlasmaGlow,
                    fontSize: 13,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('$level',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 56,
                    fontWeight: FontWeight.w800)),
            Text(levelTitle(level).toUpperCase(),
                style: const TextStyle(
                    color: kCyan,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(companionLine(appState.activeCompanion, 'level_up'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPlasma),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showAchievementUnlocked(BuildContext context, List<Achievement> items) {
  if (items.isEmpty) return;
  final a = items.first;
  final color = rarityConfig[a.rarity]?.color ?? kGold;
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF2A1458), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: color),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🏆 ACHIEVEMENT UNLOCKED',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Container(
              width: 84,
              height: 84,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color.withValues(alpha: 0.4),
                      color.withValues(alpha: 0.12)
                    ]),
                border: Border.all(color: color.withValues(alpha: 0.6)),
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 24)
                ],
              ),
              child: Icon(a.icon, color: color, size: 42),
            ),
            const SizedBox(height: 16),
            Text(a.title,
                textAlign: TextAlign.center,
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(a.description,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kTextSecondary, fontSize: 12)),
            if (items.length > 1) ...[
              const SizedBox(height: 8),
              Text('+${items.length - 1} more unlocked',
                  style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPlasma),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Nice!'),
            ),
          ],
        ),
      ),
    ),
  );
}

String _fmtReminder(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  final period = h < 12 ? 'AM' : 'PM';
  var hh = h % 12;
  if (hh == 0) hh = 12;
  return '$hh:${m.toString().padLeft(2, '0')} $period';
}

Future<void> showHabitEditor(BuildContext context, [Habit? existing]) async {
  final controller = TextEditingController(text: existing?.name ?? '');
  // The current difficulty decision — the AI (or heuristic) owns this; the user
  // no longer picks it. It's frozen onto the habit when they tap Add/Save.
  DifficultyVerdict verdict = existing != null
      ? DifficultyVerdict(existing.rarity, existing.difficultyReason,
          fromAi: existing.aiRated)
      : heuristicVerdict(controller.text);
  bool analyzing = false;
  Timer? debounce;
  int reqSeq = 0; // drops stale async results from earlier keystrokes
  String icon = existing?.icon ?? '';
  int? reminderMinutes = existing?.reminderMinutes; // daily reminder time
  const emojis = [
    '💧', '📖', '🏋️', '😴', '🧘', '🏃', '🥗', '💻',
    '🎯', '✍️', '🎸', '☀️', '🧠', '💰', '🌱', '🚭'
  ];
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Re-rate the habit: show the instant heuristic now, then let the local
        // Ollama model refine it shortly after the user stops typing.
        void analyze(String name) {
          debounce?.cancel();
          final instant = heuristicVerdict(name);
          if (name.trim().isEmpty || !appState.aiEnabled) {
            setLocal(() {
              verdict = instant;
              analyzing = false;
            });
            return;
          }
          final seq = ++reqSeq;
          setLocal(() {
            verdict = instant;
            analyzing = true;
          });
          debounce = Timer(const Duration(milliseconds: 650), () async {
            final v = await classifyDifficulty(name,
                enabled: appState.aiEnabled,
                baseUrl: appState.aiBaseUrl,
                model: appState.aiModel);
            if (!ctx.mounted || seq != reqSeq) return;
            setLocal(() {
              verdict = v;
              analyzing = false;
            });
          });
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? 'New habit' : 'Edit habit',
                  style: GoogleFonts.spaceGrotesk(
                      color: kTextPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: existing == null,
                style: const TextStyle(color: kTextPrimary),
                textCapitalization: TextCapitalization.sentences,
                decoration:
                    const InputDecoration(hintText: 'e.g. Meditate 10 min'),
                onChanged: analyze,
              ),
              const SizedBox(height: 14),
              const Text('Icon',
                  style: TextStyle(color: kTextTertiary, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: emojis.map((e) {
                  final sel = e == icon;
                  return GestureDetector(
                    onTap: () => setLocal(() => icon = sel ? '' : e),
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: sel ? kPlasma : kElevated,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: sel ? kPlasma : kBorder)),
                      child: Text(e, style: const TextStyle(fontSize: 20)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              _difficultyCard(verdict, analyzing),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
                decoration: BoxDecoration(
                    color: kElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder)),
                child: Row(children: [
                  Icon(Icons.notifications_active_rounded,
                      size: 18,
                      color: reminderMinutes != null
                          ? kPlasmaBright
                          : kTextTertiary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        reminderMinutes == null
                            ? 'No daily reminder'
                            : 'Remind me at ${_fmtReminder(reminderMinutes!)}',
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: () async {
                      final init = reminderMinutes != null
                          ? TimeOfDay(
                              hour: reminderMinutes! ~/ 60,
                              minute: reminderMinutes! % 60)
                          : const TimeOfDay(hour: 20, minute: 0);
                      final picked = await showTimePicker(
                          context: ctx, initialTime: init);
                      if (picked != null) {
                        setLocal(() => reminderMinutes =
                            picked.hour * 60 + picked.minute);
                      }
                    },
                    child: Text(reminderMinutes == null ? 'Set' : 'Change'),
                  ),
                  if (reminderMinutes != null)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setLocal(() => reminderMinutes = null),
                      icon: const Icon(Icons.close,
                          size: 18, color: kTextTertiary),
                    ),
                ]),
              ),
              const SizedBox(height: 18),
              Row(children: [
                if (existing != null)
                  TextButton.icon(
                      onPressed: () {
                        appState.deleteHabit(existing);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline, color: kRed),
                      label: const Text('Delete',
                          style: TextStyle(color: kRed))),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kPlasma),
                  onPressed: () {
                    final name = controller.text.trim();
                    if (name.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    debounce?.cancel();
                    final v = verdict;
                    if (existing == null) {
                      appState.addHabit(name, v.rarity,
                          icon: icon,
                          aiRated: v.fromAi,
                          reason: v.reason,
                          reminderMinutes: reminderMinutes);
                    } else {
                      appState.editHabit(existing,
                          name: name,
                          rarity: v.rarity,
                          icon: icon,
                          aiRated: v.fromAi,
                          reason: v.reason);
                      appState.setHabitReminder(existing, reminderMinutes);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(existing == null ? 'Add' : 'Save'),
                ),
              ]),
            ],
          ),
        );
      },
    ),
  );
  debounce?.cancel();
}

/// Shows the AI/heuristic difficulty verdict — the user can't change it.
Widget _difficultyCard(DifficultyVerdict v, bool analyzing) {
  final color = rarityConfig[v.rarity]?.color ?? kTextTertiary;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: kElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder)),
    child: Row(children: [
      Icon(Icons.auto_awesome_rounded, size: 18, color: color),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Flexible(
                child: Text('${v.label} · ×${v.multiplier} · ~${estimatedXp(v.rarity)} XP',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
              const SizedBox(width: 8),
              _ratingChip(v, analyzing),
            ]),
            const SizedBox(height: 3),
            Text(
                analyzing
                    ? 'Reading your habit…'
                    : (v.reason.isEmpty ? 'Difficulty set automatically' : v.reason),
                style: const TextStyle(color: kTextSecondary, fontSize: 11)),
          ],
        ),
      ),
    ]),
  );
}

Widget _ratingChip(DifficultyVerdict v, bool analyzing) {
  if (analyzing) {
    return SizedBox(
      width: 13,
      height: 13,
      child: CircularProgressIndicator(strokeWidth: 2, color: kPlasmaBright),
    );
  }
  final ai = v.fromAi;
  final label = ai ? '🤖 AI' : '✨ Auto';
  final c = ai ? kCyan : kTextTertiary;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.4))),
    child: Text(label,
        style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

Future<void> showAddReflection(BuildContext context) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Reflection', style: TextStyle(color: kTextPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        style: const TextStyle(color: kTextPrimary),
        textCapitalization: TextCapitalization.sentences,
        decoration:
            const InputDecoration(hintText: 'How did today go?'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (text != null && text.isNotEmpty) appState.addReflection(text);
}

// ── NUTRITION ────────────────────────────────────────────────────────────────
class _NutritionCard extends StatelessWidget {
  const _NutritionCard();
  @override
  Widget build(BuildContext context) {
    final n = appState.todayNutrition();
    final t = appState.targets();
    final score = appState.nutritionScore();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NutritionScreen())),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: _kGlassSheen,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kBorder),
            ),
            child: Row(children: [
              const Icon(Icons.restaurant_rounded, color: kGreen, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NUTRITION',
                        style: TextStyle(
                            color: kTextTertiary,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 3),
                    Text(
                        '${n.calories.round()} / ${t.calories.round()} kcal · ${n.protein.round()}g protein',
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Text('$score',
                  style: GoogleFonts.spaceGrotesk(
                      color: kGreen, fontSize: 20, fontWeight: FontWeight.w800)),
              const Icon(Icons.chevron_right, color: kTextTertiary),
            ]),
          ),
        ),
      ),
    );
  }
}

class NutritionScreen extends StatelessWidget {
  const NutritionScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final n = appState.todayNutrition();
        final today = dateKey(DateTime.now());
        final todays =
            appState.foodLog.where((e) => e.date == today).toList();
        final score = appState.nutritionScore();
        final t = appState.targets();
        final p = appState.bodyProfile;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Nutrition',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showAddFood(context),
            backgroundColor: kPlasma,
            icon: const Icon(Icons.add),
            label: const Text('Log food'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('NUTRITION SCORE',
                              style: TextStyle(
                                  color: kTextTertiary,
                                  fontSize: 11,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.bold)),
                          Text('$score / 100',
                              style: GoogleFonts.spaceGrotesk(
                                  color: kGreen,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    const Icon(Icons.restaurant_rounded,
                        color: kGreen, size: 32),
                  ]),
                  const SizedBox(height: 14),
                  _macroBar('Calories', n.calories, t.calories, 'kcal', kGold),
                  _macroBar('Protein', n.protein, t.protein, 'g', kRed),
                  _macroBar('Carbs', n.carbs, t.carbs, 'g', kCyan),
                  _macroBar('Fat', n.fat, t.fat, 'g', kPlasmaBright),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: Text(
                          p == null
                              ? 'Targets: defaults'
                              : 'TDEE ${computeTDEE(p).round()} kcal · ${p.goal}',
                          style: const TextStyle(
                              color: kTextTertiary, fontSize: 11)),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const BodyProfileScreen())),
                      icon: Icon(Icons.person_rounded,
                          size: 16, color: kPlasmaBright),
                      label: Text(
                          p == null ? 'Set body profile' : 'Edit profile',
                          style: TextStyle(color: kPlasmaBright)),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              if (todays.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyState(
                      emoji: '🍎',
                      title: 'No food logged today',
                      subtitle: 'Tap “Log food” to add a meal.'),
                )
              else
                ...todays.map((e) => _FoodTile(e)),
            ],
          ),
        );
      },
    );
  }
}

Widget _macroBar(
    String label, double value, double target, String unit, Color color) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: kTextSecondary, fontSize: 12)),
            Text('${value.round()} / ${target.round()} $unit',
                style: const TextStyle(color: kTextTertiary, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        GlowBar(
            value:
                (target <= 0 ? 0.0 : value / target).clamp(0.0, 1.0).toDouble(),
            height: 7,
            colors: [color, color]),
      ],
    ),
  );
}

class _FoodTile extends StatelessWidget {
  const _FoodTile(this.e);
  final FoodEntry e;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.name,
                  style: const TextStyle(
                      color: kTextPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                  '${e.calories.round()} kcal · P${e.protein.round()} C${e.carbs.round()} F${e.fat.round()}',
                  style: const TextStyle(color: kTextTertiary, fontSize: 12)),
            ],
          ),
        ),
        IconButton(
            icon: const Icon(Icons.close, color: kTextTertiary, size: 18),
            onPressed: () => appState.deleteFood(e)),
      ]),
    );
  }
}

double _parseNum(String s) => double.tryParse(s.trim()) ?? 0;

Widget _numField(TextEditingController c, String label, TextInputType kb,
        {ValueChanged<String>? onChanged}) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        keyboardType: kb,
        style: const TextStyle(color: kTextPrimary),
        decoration: InputDecoration(labelText: label),
        onChanged: onChanged,
      ),
    );

Future<void> showAddFood(BuildContext context) async {
  final meal = TextEditingController(); // free-text description for the AI
  final name = TextEditingController();
  final cal = TextEditingController();
  final p = TextEditingController();
  final c = TextEditingController();
  final f = TextEditingController();
  bool busy = false;
  bool aiFilled = false;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Ask the local model for macros, then pre-fill the editable fields.
        Future<void> runAi() async {
          final desc = meal.text.trim();
          if (desc.isEmpty) return;
          setLocal(() => busy = true);
          final est = await estimateNutrition(desc,
              enabled: appState.aiEnabled,
              baseUrl: appState.aiBaseUrl,
              model: appState.aiModel);
          if (!ctx.mounted) return;
          setLocal(() => busy = false);
          if (est == null) {
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text(appState.aiEnabled
                  ? "Couldn't reach the AI — is Ollama running? You can enter the macros manually."
                  : 'Turn on AI in Settings → AI difficulty, or enter the macros manually.'),
            ));
            return;
          }
          if (name.text.trim().isEmpty) name.text = est.name;
          cal.text = est.calories.round().toString();
          p.text = est.protein.round().toString();
          c.text = est.carbs.round().toString();
          f.text = est.fat.round().toString();
          setLocal(() => aiFilled = true);
        }

        return AlertDialog(
          backgroundColor: kCard,
          title:
              const Text('Log food', style: TextStyle(color: kTextPrimary)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: kElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: kBorder)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.auto_awesome_rounded,
                            size: 15, color: kCyan),
                        const SizedBox(width: 6),
                        const Text('Describe your meal',
                            style: TextStyle(
                                color: kTextSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ]),
                      const SizedBox(height: 6),
                      TextField(
                        controller: meal,
                        style: const TextStyle(color: kTextPrimary),
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            hintText:
                                'e.g. 2 eggs, toast with butter, black coffee'),
                        onSubmitted: (_) => runAi(),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: kPlasma,
                              minimumSize: const Size.fromHeight(40)),
                          onPressed: busy ? null : runAi,
                          icon: busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.auto_awesome_rounded,
                                  size: 16),
                          label: Text(
                              busy ? 'Calculating…' : 'Calculate macros with AI'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                if (aiFilled)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: Text('🤖 AI estimate — adjust anything below',
                        style: TextStyle(color: kCyan, fontSize: 11)),
                  ),
                _numField(name, 'Food name', TextInputType.text),
                _numField(cal, 'Calories (kcal)', TextInputType.number),
                _numField(p, 'Protein (g)', TextInputType.number),
                _numField(c, 'Carbs (g)', TextInputType.number),
                _numField(f, 'Fat (g)', TextInputType.number),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPlasma),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true) {
    final nm = name.text.trim().isEmpty ? 'Food' : name.text.trim();
    appState.addFood(nm, _parseNum(cal.text), _parseNum(p.text),
        _parseNum(c.text), _parseNum(f.text));
  }
}

// ── COMPANIONS ───────────────────────────────────────────────────────────────
class _CompanionOrb extends StatelessWidget {
  const _CompanionOrb(
      {required this.color, required this.icon, required this.size});
  final Color color;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.25)]),
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 16,
              spreadRadius: 1),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
  }
}

class _CompanionCard extends StatelessWidget {
  const _CompanionCard();
  @override
  Widget build(BuildContext context) {
    final c = companionByType(appState.activeCompanion);
    final stage = companionStage(appState.level);
    final line = appState.lastCompanionLine.isEmpty
        ? c.tagline
        : appState.lastCompanionLine;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CompanionsScreen())),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                gradient: _kGlassSheen,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder)),
            child: Row(children: [
              _CompanionOrb(color: c.color, icon: c.icon, size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(c.name,
                          style: const TextStyle(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0x268B5CF6),
                            borderRadius: BorderRadius.circular(10)),
                        child: Text('Stage $stage',
                            style: TextStyle(
                                color: kPlasmaGlow,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 3),
                    Text('"$line"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 12,
                            fontStyle: FontStyle.italic)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: kTextTertiary),
            ]),
          ),
        ),
      ),
    );
  }
}

class CompanionsScreen extends StatelessWidget {
  const CompanionsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Companions',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.92,
            children: kCompanions.map((c) {
              final unlocked = appState.companionUnlocked(c.type);
              final active = appState.activeCompanion == c.type;
              return GestureDetector(
                onTap: unlocked ? () => appState.setCompanion(c.type) : null,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: active ? c.color : kBorder,
                        width: active ? 2 : 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Opacity(
                        opacity: unlocked ? 1 : 0.35,
                        child: _CompanionOrb(
                            color: c.color,
                            icon: unlocked
                                ? c.icon
                                : Icons.lock_outline_rounded,
                            size: 54),
                      ),
                      const SizedBox(height: 10),
                      Text(c.name,
                          style: TextStyle(
                              color:
                                  unlocked ? kTextPrimary : kTextTertiary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(unlocked ? c.tagline : 'Unlock at Lv ${c.unlockLevel}',
                          textAlign: TextAlign.center,
                          style:
                              const TextStyle(color: kTextTertiary, fontSize: 11)),
                      if (active) ...[
                        const SizedBox(height: 6),
                        const Text('ACTIVE',
                            style: TextStyle(
                                color: kCyan,
                                fontSize: 10,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.bold)),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ── PRESTIGE & SEASONS ───────────────────────────────────────────────────────
class _PrestigeCard extends StatelessWidget {
  const _PrestigeCard();
  @override
  Widget build(BuildContext context) {
    final can = appState.canPrestige;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: glassDecoration(
          radius: 16, border: appState.prestige > 0 ? kGold : kBorder),
      child: Row(children: [
        const Icon(Icons.auto_awesome_rounded, color: kGold, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('PRESTIGE',
                    style: TextStyle(
                        color: kTextTertiary,
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold)),
                if (appState.prestige > 0) ...[
                  const SizedBox(width: 8),
                  Text('★' * appState.prestige,
                      style: const TextStyle(color: kGold, fontSize: 13)),
                ],
              ]),
              const SizedBox(height: 3),
              Text(
                  can
                      ? 'Rebirth to Lv 1 for a permanent ★ (+5% XP each)'
                      : 'Unlocks at Level $kPrestigeMinLevel',
                  style: const TextStyle(color: kTextSecondary, fontSize: 12)),
            ],
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: can ? kGold : kElevated,
              foregroundColor: can ? Colors.black : kTextTertiary),
          onPressed: can ? () => _confirmPrestige(context) : null,
          child: const Text('Prestige'),
        ),
      ]),
    );
  }
}

Future<void> _confirmPrestige(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Prestige?', style: TextStyle(color: kTextPrimary)),
      content: const Text(
          'This rebirths you to Level 1 and resets your XP, but grants a permanent ★ and +5% XP per star. Your habits, streaks, and coins are kept.',
          style: TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kGold, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Prestige'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState
        .setCompanionLine(companionLine(appState.activeCompanion, 'prestige'));
    appState.doPrestige();
    if (context.mounted) _showPrestige(context, appState.prestige);
  }
}

void _showPrestige(BuildContext context, int prestige) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF3A2A08), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kGold),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_rounded, color: kGold, size: 46),
            const SizedBox(height: 10),
            const Text('PRESTIGE',
                style: TextStyle(
                    color: kGold,
                    fontSize: 18,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('★' * prestige,
                style: const TextStyle(color: kGold, fontSize: 26)),
            const SizedBox(height: 8),
            const Text('Reborn as Initiate — stronger than before.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 10),
            Text(companionLine(appState.activeCompanion, 'prestige'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Rise'),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showSeasonIntro(BuildContext context) {
  final s = appState.currentSeason + 1;
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF0B2A4A), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kCyan),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public_rounded, color: kCyan, size: 44),
            const SizedBox(height: 10),
            const Text('NEW SEASON',
                style: TextStyle(
                    color: kCyan,
                    fontSize: 14,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Season $s',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Four bosses fell. A new season begins.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kCyan, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Begin'),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── BODY PROFILE ─────────────────────────────────────────────────────────────
Widget _dropdown(String label, String value, Map<String, String> opts,
        ValueChanged<String> onChanged) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        dropdownColor: kElevated,
        decoration: InputDecoration(labelText: label),
        items: opts.entries
            .map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value,
                    style: const TextStyle(color: kTextPrimary))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );

class BodyProfileScreen extends StatefulWidget {
  const BodyProfileScreen({super.key});
  @override
  State<BodyProfileScreen> createState() => _BodyProfileScreenState();
}

class _BodyProfileScreenState extends State<BodyProfileScreen> {
  late final TextEditingController _weight;
  late final TextEditingController _height;
  late final TextEditingController _age;
  String _gender = 'male';
  String _activity = 'moderate';
  String _goal = 'maintain';

  @override
  void initState() {
    super.initState();
    final p = appState.bodyProfile;
    _weight = TextEditingController(
        text: p != null ? p.weight.toStringAsFixed(0) : '');
    _height = TextEditingController(
        text: p != null ? p.height.toStringAsFixed(0) : '');
    _age = TextEditingController(text: p != null ? p.age.toString() : '');
    if (p != null) {
      _gender = p.gender;
      _activity = p.activity;
      _goal = p.goal;
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    _height.dispose();
    _age.dispose();
    super.dispose();
  }

  void _save() {
    final w = double.tryParse(_weight.text.trim()) ?? 0;
    final h = double.tryParse(_height.text.trim()) ?? 0;
    final a = int.tryParse(_age.text.trim()) ?? 0;
    if (w <= 0 || h <= 0 || a <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid weight, height, and age')));
      return;
    }
    appState.setBodyProfile(BodyProfile(
        weight: w,
        height: h,
        age: a,
        gender: _gender,
        activity: _activity,
        goal: _goal));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final w = double.tryParse(_weight.text) ?? 0;
    final h = double.tryParse(_height.text) ?? 0;
    final a = int.tryParse(_age.text) ?? 0;
    final preview = (w > 0 && h > 0 && a > 0)
        ? computeMacroTargets(BodyProfile(
            weight: w,
            height: h,
            age: a,
            gender: _gender,
            activity: _activity,
            goal: _goal))
        : null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Body Profile',
            style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.bold, color: kTextPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _numField(_weight, 'Weight (kg)', TextInputType.number,
              onChanged: (_) => setState(() {})),
          _numField(_height, 'Height (cm)', TextInputType.number,
              onChanged: (_) => setState(() {})),
          _numField(_age, 'Age', TextInputType.number,
              onChanged: (_) => setState(() {})),
          _dropdown(
              'Gender',
              _gender,
              const {'male': 'Male', 'female': 'Female', 'other': 'Other'},
              (v) => setState(() => _gender = v)),
          _dropdown(
              'Activity',
              _activity,
              const {
                'sedentary': 'Sedentary',
                'light': 'Light',
                'moderate': 'Moderate',
                'active': 'Active',
                'very_active': 'Very active'
              },
              (v) => setState(() => _activity = v)),
          _dropdown(
              'Goal',
              _goal,
              const {
                'cut': 'Cut (lose fat)',
                'maintain': 'Maintain',
                'bulk': 'Bulk (gain)'
              },
              (v) => setState(() => _goal = v)),
          const SizedBox(height: 16),
          if (preview != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  gradient: _kGlassSheen,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('COMPUTED TARGETS',
                      style: TextStyle(
                          color: kTextTertiary,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                      '${preview.calories.round()} kcal · P${preview.protein.round()} C${preview.carbs.round()} F${preview.fat.round()}',
                      style: const TextStyle(
                          color: kTextPrimary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kPlasma,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _save,
            child: const Text('Save profile'),
          ),
        ],
      ),
    );
  }
}

// ── LEGACY TIMELINE ──────────────────────────────────────────────────────────
IconData _milestoneIcon(String type) {
  switch (type) {
    case 'boss_defeat':
      return Icons.shield_rounded;
    case 'prestige':
      return Icons.auto_awesome_rounded;
    case 'season':
      return Icons.public_rounded;
    case 'streak':
      return Icons.local_fire_department_rounded;
    default:
      return Icons.trending_up_rounded; // level_up
  }
}

Color _milestoneColor(String type) {
  switch (type) {
    case 'boss_defeat':
    case 'prestige':
      return kGold;
    case 'season':
      return kCyan;
    case 'streak':
      return kRed;
    default:
      return kPlasmaBright;
  }
}

String _fmtDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${months[d.month - 1]} ${d.day} · $hh:$mm';
}

Widget _bestChip(String label, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: kElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: kTextTertiary, fontSize: 11)),
        ],
      ),
    );

class LegacyScreen extends StatelessWidget {
  const LegacyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final log = appState.milestoneLog;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Legacy',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('CAREER BESTS',
                        style: TextStyle(
                            color: kTextTertiary,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _bestChip('Peak level', '${appState.highestLevel}'),
                      _bestChip('Prestige', '★${appState.prestige}'),
                      _bestChip('Bosses', '${appState.totalBossDefeats}'),
                      _bestChip('Season', '${appState.currentSeason + 1}'),
                      _bestChip('Best streak', '${appState.bestStreak}'),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (log.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyState(
                      emoji: '📜',
                      title: 'No milestones yet',
                      subtitle: 'Level up, defeat the boss, or hit a streak.'),
                )
              else
                ...log.map((m) => _MilestoneTile(m)),
            ],
          ),
        );
      },
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile(this.m);
  final MilestoneEvent m;
  @override
  Widget build(BuildContext context) {
    final color = _milestoneColor(m.type);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
          child: Icon(_milestoneIcon(m.type), color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.description,
                  style: const TextStyle(
                      color: kTextPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_fmtDate(m.date),
                  style: const TextStyle(color: kTextTertiary, fontSize: 11)),
            ],
          ),
        ),
        if (m.xp > 0)
          Text('+${m.xp}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      ]),
    );
  }
}

// ── SETTINGS & ACCOUNT ───────────────────────────────────────────────────────
Widget _settingsTile(IconData icon, String title, String subtitle,
    VoidCallback? onTap,
    {bool danger = false}) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              gradient: _kGlassSheen,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Row(children: [
            Icon(icon, color: danger ? kRed : kPlasmaBright, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: danger ? kRed : kTextPrimary,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style:
                          const TextStyle(color: kTextTertiary, fontSize: 11)),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: kTextTertiary),
          ]),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(s,
          style: const TextStyle(
              color: kTextTertiary,
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold)),
    );

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ld = levelFromXp(appState.totalXp);
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Settings',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Account header
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Row(children: [
                  GestureDetector(
                    onTap: () => _pickProfilePhoto(context),
                    child: Stack(children: [
                      _Avatar(size: 58),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: kPlasma,
                              border: Border.all(color: kCard, width: 2)),
                          child: const Icon(Icons.camera_alt_rounded,
                              size: 10, color: Colors.white),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(appState.displayName,
                            style: const TextStyle(
                                color: kTextPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                        Text('Level ${ld.level} · ${levelTitle(ld.level)}',
                            style: const TextStyle(
                                color: kTextTertiary, fontSize: 12)),
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: () => _pickProfilePhoto(context),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.camera_alt_rounded,
                                size: 13, color: kPlasmaBright),
                            const SizedBox(width: 4),
                            Text('Change photo',
                                style: TextStyle(
                                    color: kPlasmaBright,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                      icon: Icon(Icons.edit,
                          color: kPlasmaBright, size: 18),
                      onPressed: () => _editName(context)),
                ]),
              ),
              _sectionLabel('ACCOUNT'),
              ListenableBuilder(
                listenable: auth,
                builder: (context, _) {
                  final authed = auth.isAuthed;
                  final u = auth.user;
                  return _settingsTile(
                    authed ? Icons.person_rounded : Icons.login_rounded,
                    authed ? 'Account' : 'Sign in or create account',
                    authed
                        ? (auth.isRemote
                            ? 'Signed in · ${u?.email ?? ''}'
                            : '${u?.email ?? ''} · on this device')
                        : 'Back up your progress & sync devices',
                    () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            authed ? const AccountScreen() : const LoginScreen())),
                  );
                },
              ),
              _sectionLabel('PREFERENCES'),
              _settingsTile(
                  Icons.palette_rounded,
                  'Appearance',
                  'Pick an accent theme',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AppearanceScreen()))),
              _settingsTile(
                  Icons.person_rounded,
                  'Body profile',
                  'Weight, height, goal → nutrition targets',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const BodyProfileScreen()))),
              _settingsTile(
                  Icons.pets_rounded,
                  'Companion',
                  'Choose your active companion',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const CompanionsScreen()))),
              _settingsTile(
                  Icons.auto_awesome_rounded,
                  'AI difficulty',
                  appState.aiEnabled
                      ? 'Ollama rates new habits · ${appState.aiModel}'
                      : 'Off — using the built-in estimate',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AiSettingsScreen()))),
              _sectionLabel('DATA'),
              _settingsTile(Icons.refresh_rounded, 'Reset all progress',
                  'Wipe habits, XP, and history',
                  () => _confirmReset(context),
                  danger: true),
              ListenableBuilder(
                listenable: auth,
                builder: (context, _) {
                  if (!auth.isAuthed) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: kElevated,
                          foregroundColor: kRed,
                          minimumSize: const Size.fromHeight(50)),
                      onPressed: () async {
                        await auth.signOut();
                        if (context.mounted) {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        }
                      },
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('Log out'),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              const Center(
                child: Text('Habitrail · v1.0.0\nRebuilt from the Habitrail web app',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextTertiary, fontSize: 11)),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _editName(BuildContext context) async {
  final c = TextEditingController(text: appState.displayName);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Your name', style: TextStyle(color: kTextPrimary)),
      content: TextField(
        controller: c,
        autofocus: true,
        style: const TextStyle(color: kTextPrimary),
        decoration: const InputDecoration(hintText: 'Display name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name != null && name.isNotEmpty) appState.setDisplayName(name);
}

Future<void> _confirmReset(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Reset all progress?',
          style: TextStyle(color: kTextPrimary)),
      content: const Text(
          'This permanently clears your habits, XP, coins, streaks, nutrition, companions, prestige, and history. It cannot be undone.',
          style: TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kRed, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState.resetAll();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Progress reset')));
  }
}

// ── AI DIFFICULTY (local Ollama) ─────────────────────────────────────────────
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: appState.aiBaseUrl);
  late final TextEditingController _model =
      TextEditingController(text: appState.aiModel);
  bool _testing = false;
  bool _testOk = false;
  String? _testResult;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    // Save what's on screen, then test exactly that.
    appState.setAiConfig(baseUrl: _url.text, model: _model.text);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await testOllama(_url.text, _model.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = r.ok;
      _testResult = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final on = appState.aiEnabled;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('AI difficulty',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.auto_awesome_rounded, color: kCyan, size: 20),
                      const SizedBox(width: 8),
                      Text('How it works',
                          style: GoogleFonts.spaceGrotesk(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                      'When you add a habit, a local AI model reads it and picks a '
                      'difficulty — harder habits earn a bigger XP multiplier. The '
                      'rating is locked in when the habit is created, so XP stays '
                      'fair and the app still works offline (it falls back to a '
                      'built-in estimate whenever the model isn\'t running).',
                      style: TextStyle(
                          color: kTextSecondary, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder)),
                child: SwitchListTile(
                  value: on,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  title: const Text('Use Ollama',
                      style: TextStyle(
                          color: kTextPrimary, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Rate new habits with a local model',
                      style: TextStyle(color: kTextTertiary, fontSize: 12)),
                  onChanged: (v) => appState.setAiConfig(enabled: v),
                ),
              ),
              const SizedBox(height: 16),
              _aiField('Server URL', _url, 'http://localhost:11434',
                  enabled: on,
                  onChanged: (v) => appState.setAiConfig(baseUrl: v)),
              const SizedBox(height: 12),
              _aiField('Model', _model, kDefaultAiModel,
                  enabled: on, onChanged: (v) => appState.setAiConfig(model: v)),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: on ? kPlasma : kElevated,
                    minimumSize: const Size.fromHeight(46)),
                onPressed: on && !_testing ? _test : null,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: Text(_testing ? 'Testing…' : 'Test connection'),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: (_testOk ? kGreen : kRed).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: (_testOk ? kGreen : kRed)
                              .withValues(alpha: 0.4))),
                  child: Row(children: [
                    Icon(_testOk ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: _testOk ? kGreen : kRed, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_testResult!,
                          style: TextStyle(
                              color: _testOk ? kGreen : kRed, fontSize: 12)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              _sectionLabel('SETUP'),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 2, 4, 0),
                child: Text(
                  '1. Install Ollama from ollama.com\n'
                  '2. Run:  ollama pull llama3.2\n'
                  '3. Keep Ollama running while you add habits.\n\n'
                  'On a real iPhone later, Ollama runs on your computer, not the '
                  'phone — set the Server URL to your computer\'s address, e.g. '
                  'http://192.168.1.20:11434, or leave AI off to use the built-in '
                  'estimate.',
                  style: TextStyle(
                      color: kTextTertiary, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _aiField(String label, TextEditingController c, String hint,
    {required bool enabled, required ValueChanged<String> onChanged}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(label,
            style: const TextStyle(color: kTextTertiary, fontSize: 12)),
      ),
      TextField(
        controller: c,
        enabled: enabled,
        style: const TextStyle(color: kTextPrimary),
        decoration: InputDecoration(hintText: hint),
        onChanged: onChanged,
      ),
    ],
  );
}

// ── APPEARANCE (themes) ──────────────────────────────────────────────────────
Widget _swatch(Color c) => Container(
      width: 22,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: kElevated));

// Gold affordability-aware buy pill. Affordable → glowing gold; otherwise a
// muted pill that still taps through to show the "not enough coins" toast.
Widget _buyPill({required int cost, required VoidCallback onTap}) {
  final canAfford = appState.coins >= cost;
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: canAfford
              ? const LinearGradient(
                  colors: [Color(0xFFFFD873), Color(0xFFF5A623)])
              : null,
          color: canAfford ? null : kElevated,
          border: canAfford ? null : Border.all(color: kBorder),
          boxShadow: canAfford
              ? [
                  BoxShadow(
                      color: const Color(0xFFF5A623).withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 3))
                ]
              : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bolt,
              size: 15, color: canAfford ? const Color(0xFF3A2A05) : kGold),
          const SizedBox(width: 3),
          Text('$cost',
              style: TextStyle(
                  color: canAfford ? const Color(0xFF3A2A05) : kTextSecondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13)),
        ]),
      ),
    ),
  );
}

// Small status chip for an owned/active cosmetic (check + label).
Widget _stateChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_rounded, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: color,
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8)),
      ]),
    );

// Outline pill for a secondary action (Select / Apply an owned cosmetic).
Widget _secondaryPill(String label, VoidCallback onTap) => Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kPlasma.withValues(alpha: 0.6)),
          ),
          child: Text(label,
              style: TextStyle(
                  color: kPlasmaGlow,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ),
      ),
    );

// Section header with an optional right-aligned owned-count ("3 / 7").
Widget _shopSectionHeader(String title, String trailing) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(children: [
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    color: kTextTertiary,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold))),
        if (trailing.isNotEmpty)
          Text(trailing,
              style: const TextStyle(
                  color: kTextTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
      ]),
    );

// Coins balance hero at the top of the shop.
Widget _balanceHero() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2E1A5C), Color(0xFF1A0F38)]),
        border: Border.all(color: kGold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
              color: kGold.withValues(alpha: 0.12),
              blurRadius: 28,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 58,
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [Color(0xFFFFD873), Color(0xFFF5A623)]),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFFF5A623).withValues(alpha: 0.5),
                  blurRadius: 18),
            ],
          ),
          child: const Icon(Icons.bolt, color: Color(0xFF3A2A05), size: 32),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('YOUR BALANCE',
                  style: TextStyle(
                      color: kTextTertiary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('${appState.coins}',
                      style: GoogleFonts.spaceGrotesk(
                          color: kGold,
                          fontSize: 34,
                          height: 1,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(width: 6),
                  const Text('coins',
                      style: TextStyle(color: kTextSecondary, fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
        if (appState.xpBoostActive)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: kPlasma.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kPlasma.withValues(alpha: 0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('2×',
                  style: TextStyle(
                      color: kPlasmaGlow,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
              const SizedBox(width: 4),
              Text('XP',
                  style: TextStyle(
                      color: kPlasmaGlow,
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
            ]),
          ),
      ]),
    );

Widget _shopItem({
  required IconData icon,
  required Color color,
  required String title,
  required String desc,
  required int cost,
  required VoidCallback? onBuy,
  String? activeLabel,
}) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder)),
    child: Row(children: [
      Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withValues(alpha: 0.28),
                color.withValues(alpha: 0.10)
              ]),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: kTextPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
            const SizedBox(height: 3),
            Text(desc,
                style: const TextStyle(
                    color: kTextTertiary, fontSize: 11.5, height: 1.3)),
          ],
        ),
      ),
      const SizedBox(width: 10),
      if (activeLabel != null)
        _stateChip(activeLabel, kGreen)
      else if (onBuy != null)
        _buyPill(cost: cost, onTap: onBuy)
      else
        _stateChip('OWNED', kGreen),
    ]),
  );
}

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ownedBorders =
            kBorders.where((b) => appState.ownsBorder(b.id)).length;
        final ownedThemes =
            kThemes.where((t) => appState.ownsTheme(t.id)).length;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Shop',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              _balanceHero(),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text(
                    'Spend coins on power-ups and cosmetics to personalize your journey.',
                    style: TextStyle(
                        color: kTextTertiary, fontSize: 12.5, height: 1.4)),
              ),
              _shopSectionHeader('POWER-UPS', ''),
              _shopItem(
                icon: Icons.bolt_rounded,
                color: kGold,
                title: '2× XP Booster',
                desc: appState.xpBoostActive
                    ? 'Active for the rest of today'
                    : 'Double all XP you earn today',
                cost: 150,
                onBuy: appState.xpBoostActive
                    ? null
                    : () => _toast(
                        context,
                        appState.buyXpBoost()
                            ? '2× XP active for today!'
                            : 'Not enough coins'),
                activeLabel: appState.xpBoostActive ? 'ACTIVE' : null,
              ),
              _shopItem(
                icon: Icons.shield_rounded,
                color: kCyan,
                title: 'Streak Shield',
                desc:
                    'Saves a streak from one missed day · owned: ${appState.streakShields}',
                cost: 100,
                onBuy: () => _toast(
                    context,
                    appState.buyStreakShield()
                        ? 'Streak Shield added!'
                        : 'Not enough coins'),
              ),
              _shopSectionHeader(
                  'PROFILE BORDERS', '$ownedBorders / ${kBorders.length}'),
              ...kBorders.map((b) => _borderShopTile(context, b)),
              _shopSectionHeader('THEMES', '$ownedThemes / ${kThemes.length}'),
              ...kThemes.map((t) => _themeShopTile(context, t)),
            ],
          ),
        );
      },
    );
  }
}

Widget _borderShopTile(BuildContext context, BorderDef b) {
  final owned = appState.ownsBorder(b.id);
  final selected = appState.selectedBorder == b.id;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 5),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: selected ? kPlasma : kBorder, width: selected ? 1.5 : 1)),
    child: Row(children: [
      _borderPreview(b, size: 42),
      const SizedBox(width: 14),
      Expanded(
          child: Text(b.name,
              style: const TextStyle(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14.5))),
      if (owned)
        selected
            ? _stateChip('SELECTED', kCyan)
            : _secondaryPill('Select', () => appState.setBorder(b.id))
      else
        _buyPill(
          cost: b.cost,
          onTap: () {
            if (appState.buyBorder(b.id)) {
              appState.setBorder(b.id);
              celebrate(context);
              _toast(context, '${b.name} unlocked & applied!');
            } else {
              _toast(context, 'Not enough coins');
            }
          },
        ),
    ]),
  );
}

Widget _themeShopTile(BuildContext context, AppThemeDef t) {
  final owned = appState.ownsTheme(t.id);
  final active = appState.themeId == t.id;
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 5),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        gradient: _kGlassSheen,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: active ? t.accent : kBorder, width: active ? 1.5 : 1)),
    child: Row(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        _swatch(t.accent),
        _swatch(t.bright),
        _swatch(t.glow),
      ]),
      const SizedBox(width: 10),
      Expanded(
          child: Text(t.name,
              style: const TextStyle(
                  color: kTextPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14.5))),
      if (owned)
        active
            ? _stateChip('ACTIVE', kCyan)
            : _secondaryPill('Apply', () => appState.setTheme(t.id))
      else
        _buyPill(
          cost: themeCost(t.id),
          onTap: () {
            if (appState.buyTheme(t.id)) {
              appState.setTheme(t.id);
              celebrate(context);
              _toast(context, '${t.name} unlocked & applied!');
            } else {
              _toast(context, 'Not enough coins');
            }
          },
        ),
    ]),
  );
}

// ── CONFETTI ─────────────────────────────────────────────────────────────────
void celebrate(BuildContext context) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: _Confetti(onDone: () => entry.remove()),
    ),
  );
  overlay.insert(entry);
}

class _Confo {
  _Confo(this.x, this.vx, this.delay, this.rot, this.vr, this.color, this.size);
  final double x, vx, delay, rot, vr, size;
  final Color color;
}

class _Confetti extends StatefulWidget {
  const _Confetti({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final List<_Confo> _p = [];

  @override
  void initState() {
    super.initState();
    final r = Random();
    final colors = [
      kPlasma, kCyan, kGold, const Color(0xFFF472B6), kGreen, kBlue
    ];
    for (int i = 0; i < 80; i++) {
      _p.add(_Confo(
        r.nextDouble(),
        (r.nextDouble() - 0.5) * 0.4,
        r.nextDouble() * 0.25,
        r.nextDouble() * 6.28,
        (r.nextDouble() - 0.5) * 10,
        colors[r.nextInt(colors.length)],
        6 + r.nextDouble() * 7,
      ));
    }
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1900))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
            size: Size.infinite, painter: _ConfettiPainter(_p, _c.value)),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.ps, this.t);
  final List<_Confo> ps;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final c in ps) {
      final denom = 1 - c.delay;
      final p = denom <= 0 ? t : (t - c.delay) / denom;
      if (p <= 0) continue;
      final pc = p.clamp(0.0, 1.0);
      final y = (pc * pc * 0.5 + pc * 0.6) * size.height * 1.1;
      final x = (c.x + c.vx * pc) * size.width;
      paint.color = c.color.withValues(alpha: (1 - pc).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(c.rot + c.vr * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset.zero, width: c.size, height: c.size * 0.6),
            const Radius.circular(1.5)),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard();
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayK = dateKey(now);
    const n = 35; // 5 weeks
    final cells = <({int score, bool today})>[];
    for (int i = n - 1; i >= 0; i--) {
      final k = dateKey(now.subtract(Duration(days: i)));
      cells.add((score: appState.dailyScore[k] ?? 0, today: k == todayK));
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ACTIVITY · LAST 5 WEEKS',
              style: TextStyle(
                  color: kTextTertiary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: cells.map((c) {
              final on = c.score > 0;
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: on
                      ? victoryColor(c.score)
                          .withValues(alpha: 0.25 + c.score / 100 * 0.75)
                      : const Color(0x14FFFFFF),
                  border: c.today
                      ? Border.all(color: Colors.white, width: 1)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _WeekTrendCard extends StatelessWidget {
  const _WeekTrendCard();
  @override
  Widget build(BuildContext context) {
    final days = appState.weekTrend();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          gradient: _kGlassSheen,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('THIS WEEK · VICTORY SCORE',
              style: TextStyle(
                  color: kTextTertiary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: days.map((d) {
                final h = 6.0 + (d.score / 100) * 60;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('${d.score}',
                        style: const TextStyle(
                            color: kTextTertiary, fontSize: 9)),
                    const SizedBox(height: 3),
                    Container(
                      width: 22,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: victoryColor(d.score)
                            .withValues(alpha: d.today ? 1 : 0.55),
                        border: d.today
                            ? Border.all(color: Colors.white, width: 1)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(d.label,
                        style: TextStyle(
                            color: d.today ? kTextPrimary : kTextTertiary,
                            fontSize: 10,
                            fontWeight:
                                d.today ? FontWeight.bold : FontWeight.normal)),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Appearance',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: kThemes.map((t) {
              final active = appState.themeId == t.id;
              final owned = appState.ownsTheme(t.id);
              return GestureDetector(
                onTap: owned ? () => appState.setTheme(t.id) : null,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: _kGlassSheen,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: active ? t.accent : kBorder,
                        width: active ? 2 : 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Opacity(
                        opacity: owned ? 1 : 0.5,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _swatch(t.accent),
                            _swatch(t.bright),
                            _swatch(t.glow),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(t.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 14.5)),
                      const SizedBox(height: 10),
                      if (active)
                        _stateChip('ACTIVE', kCyan)
                      else if (owned)
                        _secondaryPill('Apply', () => appState.setTheme(t.id))
                      else
                        _buyPill(
                          cost: themeCost(t.id),
                          onTap: () {
                            if (appState.buyTheme(t.id)) {
                              appState.setTheme(t.id);
                              celebrate(context);
                              _toast(
                                  context, '${t.name} unlocked & applied!');
                            } else {
                              _toast(context, 'Not enough coins');
                            }
                          },
                        ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ── DAILY BRIEFING ───────────────────────────────────────────────────────────
Widget _briefPanel(String tag, String title, Widget body) => Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(tag,
              style: const TextStyle(
                  color: kCyan,
                  letterSpacing: 3,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 28),
          body,
        ],
      ),
    );

class _DailyBriefing extends StatefulWidget {
  const _DailyBriefing();
  @override
  State<_DailyBriefing> createState() => _DailyBriefingState();
}

class _DailyBriefingState extends State<_DailyBriefing> {
  final _pc = PageController();
  int _page = 0;
  String? _coach;
  bool _coachLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCoach();
  }

  Future<void> _loadCoach() async {
    final ld = levelFromXp(appState.totalXp);
    final v = appState.victory();
    final summary =
        'Name: ${appState.displayName}. Level ${ld.level} (${levelTitle(ld.level)}). '
        'Victory score today: ${v.score}/100 (${victoryLabel(v.score)}). '
        'Habits done today: ${appState.doneTodayCount}/${appState.habits.length}. '
        'Best streak: ${appState.bestStreak} days. Coins: ${appState.coins}.';
    final msg = await aiCoachMessage(summary,
        enabled: appState.aiEnabled,
        baseUrl: appState.aiBaseUrl,
        model: appState.aiModel);
    if (!mounted) return;
    setState(() {
      _coach = msg;
      _coachLoading = false;
    });
  }

  String _coachFallback() {
    final done = appState.doneTodayCount;
    final total = appState.habits.length;
    if (total == 0) return 'Add your first habit and start a streak today.';
    final remaining = total - done;
    if (remaining <= 0) {
      return 'Perfect day — every habit done. Come back tomorrow to protect your streak!';
    }
    return "You've done $done of $total today. Knock out $remaining more for a perfect day.";
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _next(int last) {
    if (_page >= last) {
      appState.markBriefingSeen();
      Navigator.of(context).pop();
    } else {
      _pc.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final v = appState.victory();
    final who = companionByType(appState.activeCompanion);
    final panels = <Widget>[
      _briefPanel(
        'COACH',
        'Your coach',
        Column(children: [
          _CompanionOrb(color: who.color, icon: who.icon, size: 56),
          const SizedBox(height: 18),
          if (_coachLoading)
            Column(children: [
              SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kPlasmaBright)),
              const SizedBox(height: 10),
              const Text('Reading your day…',
                  style: TextStyle(color: kTextTertiary, fontSize: 13)),
            ])
          else
            Text('"${_coach ?? _coachFallback()}"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontSize: 15,
                    fontStyle: FontStyle.italic,
                    height: 1.5)),
        ]),
      ),
      _briefPanel(
        'BRIEFING',
        'Welcome back, ${appState.displayName}',
        Column(children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [kPlasma, kBlue])),
            child: Text('${ld.level}',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 12),
          Text(levelTitle(ld.level).toUpperCase(),
              style: const TextStyle(
                  color: kCyan, letterSpacing: 2, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Best streak: ${appState.bestStreak} days',
              style: const TextStyle(color: kTextSecondary)),
        ]),
      ),
      _briefPanel(
        'STATUS',
        'Today',
        Column(children: [
          SizedBox(
            width: 96,
            height: 96,
            child: Stack(alignment: Alignment.center, children: [
              GlowRing(
                value: v.score / 100,
                size: 96,
                stroke: 8,
                colors: [
                  victoryColor(v.score),
                  Color.lerp(victoryColor(v.score), Colors.white, 0.35)!,
                ],
              ),
              Text('${v.score}',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          Text(victoryLabel(v.score),
              style: TextStyle(
                  color: victoryColor(v.score),
                  fontWeight: FontWeight.bold,
                  fontSize: 18)),
          const SizedBox(height: 6),
          Text(
              '${appState.doneTodayCount}/${appState.habits.length} habits · ${appState.coins} coins',
              style: const TextStyle(color: kTextSecondary)),
        ]),
      ),
      _briefPanel(
        'ORDERS',
        "Today's quests",
        Column(
          children: kQuests.map((q) {
            final on = appState.questClaimedIds.contains(q.id);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 16, color: on ? kGreen : kTextTertiary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(q.title,
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 13))),
                Text('+${q.xp}',
                    style: TextStyle(
                        color: kPlasmaGlow,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ]),
            );
          }).toList(),
        ),
      ),
      _briefPanel(
        'DEPLOY',
        who.name,
        Column(children: [
          _CompanionOrb(color: who.color, icon: who.icon, size: 60),
          const SizedBox(height: 14),
          Text(
              '"${companionLine(appState.activeCompanion, v.score >= 90 ? 'elite_day' : 'level_up')}"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: kTextSecondary, fontStyle: FontStyle.italic)),
        ]),
      ),
    ];
    final last = panels.length - 1;
    return Dialog.fullscreen(
      backgroundColor: kBase,
      child: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              children: panels,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              panels.length,
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                width: i == _page ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i == _page ? kPlasma : const Color(0x33FFFFFF)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: SizedBox(
              width: double.infinity,
              child: GradientButton(
                label: _page >= last ? 'Start the day' : 'Next',
                onPressed: () => _next(last),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
