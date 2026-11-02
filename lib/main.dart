import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show MaskFilter, BlurStyle, ImageByteFormat;

import 'package:flutter/foundation.dart'
    show kIsWeb, kDebugMode, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'core.dart';
import 'ai.dart';
import 'auth.dart';
import 'backend.dart';
import 'friends.dart';
import 'purchases.dart';
import 'ui/hr_tokens.dart';
import 'ui/hr_theme.dart';
import 'ui/hr_widgets.dart';

/// Single shared state object for the whole app (loads immediately).
// Loaded eagerly in main() before the app renders — see main(). (Must NOT
// auto-load here: appState is a lazily-initialized top-level, so a new user's
// first access during sign-up would start load() AFTER the fresh-start reset
// and clobber it with the old saved state.)
// appState is defined in core.dart (shared with purchases.dart).

// The app uses a static night-sky backdrop behind every transparent page.

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
  Timer? backupDebounce;
  appState.addListener(() {
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 2), push);
    // Auto-back-up the full save once activity settles (signed-in only; no-op
    // otherwise). markBackedUp doesn't notify, so this can't loop.
    backupDebounce?.cancel();
    backupDebounce = Timer(const Duration(seconds: 30), () => backupNow());
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
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _FadeSlidePageTransitionsBuilder(),
            TargetPlatform.iOS: _FadeSlidePageTransitionsBuilder(),
            TargetPlatform.macOS: _FadeSlidePageTransitionsBuilder(),
            TargetPlatform.windows: _FadeSlidePageTransitionsBuilder(),
            TargetPlatform.linux: _FadeSlidePageTransitionsBuilder(),
          },
        ),
      ),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          const HrAmbientBackdrop(),
          ?child,
        ],
      ),
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
        position: Tween<Offset>(
          begin: const Offset(0.035, 0),
          end: Offset.zero,
        ).animate(eased),
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
              child: CircularProgressIndicator(color: kPlasmaBright),
            ),
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
    final comp = companionByType(appState.activeCompanion);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HrSpace.gutter,
            12,
            HrSpace.gutter,
            24,
          ),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 36),
                      Center(
                        child: CompanionSticker(
                          icon: comp.icon,
                          color: comp.color,
                          size: 104,
                          semanticLabel: comp.name,
                          imageAsset: comp.imageAsset,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Center(
                        child: SpeechBubble(
                          "Five habits. Every day. I'm watching.",
                          maxWidth: 260,
                        ),
                      ),
                      const SizedBox(height: 36),
                      Text(
                        'Build habits.\nEarn XP.\nLevel up your life.',
                        style: HrText.displayXl,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Check off up to five habits a day, keep the streak alive, and let your companion keep you honest.',
                        style: HrText.bodyS,
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              ),
              HrButton(
                label: 'Create account',
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SignUpScreen())),
              ),
              const SizedBox(height: 10),
              HrButton(
                label: 'Log in',
                kind: HrButtonKind.secondary,
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => auth.continueAsGuest(),
                child: Text(
                  'Continue without an account',
                  style: HrText.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
      return _unameStatusLine(
        HrColors.text3,
        Icons.info_outline_rounded,
        '3–20 letters, numbers, or underscores',
      );
    }
    if (_unameChecking) {
      return Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('Checking…', style: HrText.caption),
          ],
        ),
      );
    }
    if (_unameAvailable == true) {
      return _unameStatusLine(
        HrColors.accent,
        Icons.check_circle_rounded,
        'Available',
      );
    }
    if (_unameAvailable == false) {
      return _unameStatusLine(
        HrColors.dangerText,
        Icons.cancel_rounded,
        'Unavailable',
      );
    }
    return const SizedBox.shrink();
  }

  Widget _unameStatusLine(Color c, IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 6),
        Text(text, style: HrText.caption.copyWith(color: c)),
      ],
    ),
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
        MaterialPageRoute(builder: (_) => const OnboardingQuizScreen()),
      );
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
        _authField(
          _username,
          'Username',
          hint: 'e.g. sam_92',
          onChanged: _onUsernameChanged,
        ),
        _usernameStatus(),
        _authField(
          _email,
          'Email',
          keyboard: TextInputType.emailAddress,
          hint: 'you@example.com',
        ),
        _authField(
          _pw,
          'Password',
          obscure: true,
          hint: 'At least 6 characters',
        ),
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
            onPressed: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            ),
            child: Text(
              'Already have an account? Log in',
              style: HrText.bodyS.copyWith(
                color: HrColors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
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
    if (err == null) {
      await syncAfterSignIn(); // restore a cloud backup onto a fresh device
      if (!mounted) return;
      final u = auth.user;
      if (u != null) appState.setDisplayName(u.name);
      setState(() => _busy = false);
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      setState(() => _busy = false);
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
        _authField(
          _email,
          'Email',
          keyboard: TextInputType.emailAddress,
          hint: 'you@example.com',
        ),
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
            onPressed: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const SignUpScreen()),
            ),
            child: Text(
              'New here? Create an account',
              style: HrText.bodyS.copyWith(
                color: HrColors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        _authNote(),
      ],
    );
  }
}

// Cloud backup actions + helpers used by the Account screen.
Future<void> _backupNow(BuildContext context) async {
  await backupNow();
  if (context.mounted) {
    hrToast(context, 'Backed up to your account',
        icon: Icons.cloud_done_rounded);
  }
}

Future<void> _confirmRestore(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: HrColors.surface,
      title: Text('Restore from cloud?', style: HrText.title2),
      content: Text(
          'This replaces everything on this device with your cloud backup.',
          style: HrText.bodyS),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: HrText.caption)),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Restore',
                style: HrText.body.copyWith(color: HrColors.accent))),
      ],
    ),
  );
  if (ok != true) return;
  final done = await restoreFromCloud();
  if (context.mounted) {
    hrToast(context, done ? 'Progress restored' : 'No backup found yet',
        icon: done ? Icons.cloud_done_rounded : Icons.info_outline_rounded);
  }
}

String _fmtBackup(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return 'recently';
  final l = d.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${_kMonths[l.month - 1]} ${l.day}, $hh:$mm';
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
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Account'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              24,
            ),
            children: [
              HrCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () => _pickProfilePhoto(context),
                      child: Stack(
                        children: [
                          _Avatar(size: 76),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: HrColors.accent,
                                border: Border.all(
                                  color: HrColors.surface,
                                  width: 2,
                              ),
                              ),
                              child: const Icon(
                                Icons.camera_alt_rounded,
                                size: 12,
                                color: HrColors.bg,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _photoActions(context),
                    const SizedBox(height: 12),
                    Text(u.name, style: HrText.title1),
                    const SizedBox(height: 2),
                    Text(u.email, style: HrText.caption),
                    if (u.username.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '@${u.username}',
                        style: HrText.caption.copyWith(
                          color: HrColors.text2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (_memberSince(u.createdAt).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(_memberSince(u.createdAt), style: HrText.micro),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 4),
              _sectionLabel('LIFETIME'),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _statChip('Level', '${ld.level}'),
                  _statChip('Total XP', '${appState.totalXp}'),
                  _statChip('Best streak', '${appState.bestStreak}'),
                  _statChip('Habits', '${appState.habits.length}'),
                  _statChip('Prestige', '${appState.prestige}'),
                ],
              ),
              const SizedBox(height: 16),
              HrButton(
                label: 'Share my progress',
                icon: Icons.ios_share_rounded,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ShareCardScreen()),
                ),
              ),
              const SizedBox(height: 4),
              _sectionLabel('ACCOUNT'),
              _settingsTile(
                Icons.edit_rounded,
                'Edit name',
                u.name,
                () => _editAccountName(context),
              ),
              if (!auth.isRemote)
                _settingsTile(
                  Icons.cloud_off_rounded,
                  'Cloud sync',
                  'On this device for now — Supabase wires in later',
                  null,
                ),
              if (auth.isRemote) ...[
                const SizedBox(height: 4),
                _sectionLabel('BACKUP'),
                _settingsTile(
                  Icons.cloud_upload_rounded,
                  'Back up now',
                  appState.lastBackupAt.isEmpty
                      ? 'Save your progress to your account'
                      : 'Last backed up ${_fmtBackup(appState.lastBackupAt)}',
                  () => _backupNow(context),
                ),
                _settingsTile(
                  Icons.cloud_download_rounded,
                  'Restore from cloud',
                  'Replace this device with your backup',
                  () => _confirmRestore(context),
                ),
              ],
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => _confirmDeleteAccount(context),
                icon: const Icon(
                  Icons.delete_forever_rounded,
                  size: 18,
                  color: HrColors.dangerText,
                ),
                label: Text(
                  'Delete account',
                  style: HrText.body.copyWith(color: HrColors.dangerText),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Onboarding (first run, right after creating an account) ─────────────────
class _OnbSlide {
  const _OnbSlide(this.imageAsset, this.title, this.body, this.accent);
  final String imageAsset;
  final String title;
  final String body;
  final Color accent;
}

const _onbSlides = [
  _OnbSlide(
    'assets/onboarding/welcome.png',
    'Welcome to Habitrail',
    'Turn your daily habits into a game you actually want to play.',
    Color(0xFFFF8A4C),
  ),
  _OnbSlide(
    'assets/onboarding/xp.png',
    'Earn XP, level up',
    'Every habit you check off earns XP. Build streaks and combos for big multipliers, and climb from Level 1 to God-Tier.',
    Color(0xFF3DE7FF),
  ),
  _OnbSlide(
    'assets/onboarding/quests.png',
    'Quests, bosses & Victory Score',
    'Take on daily quests, defeat the weekly boss, and track each day with a 4-pillar Victory Score.',
    Color(0xFFFFD23F),
  ),
  _OnbSlide(
    'assets/onboarding/companions.png',
    'Companions & more',
    'Adopt a companion, log nutrition, prestige, and make every single day count.',
    Color(0xFF4ADE80),
  ),
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
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _onbSlides.length - 1;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: Text('Skip', style: HrText.caption),
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
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: HrColors.surface,
                            border: Border.all(
                              color: HrColors.accent,
                              width: 2,
                          ),
                          ),
                          child: Image.asset(
                            s.imageAsset,
                            fit: BoxFit.cover,
                            semanticLabel: s.title,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          s.title,
                          textAlign: TextAlign.center,
                          style: HrText.display,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          s.body,
                          textAlign: TextAlign.center,
                          style: HrText.bodyS.copyWith(height: 1.5),
                        ),
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
                    color: on ? HrColors.accent : HrColors.surface3,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.all(28),
              child: HrButton(
                label: last ? 'Get started' : 'Next',
                onPressed: _next,
              ),
            ),
          ],
        ),
      ),
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
      appState.setBodyProfile(
        BodyProfile(
          weight: w,
          height: h,
          age: a,
          gender: _gender,
          activity: _activity,
          goal: _goal,
        ),
      );
    }
    appState.seedHabitsForAreas(_areas);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _next() {
    if (_page >= _last) {
      _finish();
    } else {
      _pc.nextPage(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _last;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: _page > 0
                        ? IconButton(
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: HrColors.text2,
                            ),
                            onPressed: () => _pc.previousPage(
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOut,
                            ),
                          )
                        : null,
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(HrRadius.full),
                      child: LinearProgressIndicator(
                        value: (_page + 1) / (_last + 1),
                        minHeight: 6,
                        backgroundColor: HrColors.surface3,
                        valueColor: const AlwaysStoppedAnimation(HrColors.text),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 54,
                    child: last
                        ? null
                        : TextButton(
                            onPressed: _skip,
                            child: Text('Skip', style: HrText.caption),
                          ),
                  ),
                ],
              ),
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
              child: HrButton(
                label: last ? "Let's go" : 'Continue',
                onPressed: _canAdvance ? _next : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quizPage(String title, String? subtitle, Widget content) => ListView(
    padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 12, HrSpace.gutter, 16),
    children: [
      Text(title, style: HrText.display.copyWith(height: 1.1)),
      if (subtitle != null) ...[
        const SizedBox(height: 8),
        Text(subtitle, style: HrText.bodyS),
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
          borderRadius: BorderRadius.circular(HrRadius.full),
          color: on ? HrColors.text : HrColors.surface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Text(
              label,
              style: HrText.body.copyWith(
                color: on ? HrColors.bg : HrColors.text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _genderPage() => _quizPage(
    'How do you identify?',
    'Used only to personalize your nutrition targets.',
    Column(
      children: [
        _choiceRow(
          'male',
          'Male',
          '♂️',
          _gender,
          (v) => setState(() => _gender = v),
        ),
        _choiceRow(
          'female',
          'Female',
          '♀️',
          _gender,
          (v) => setState(() => _gender = v),
        ),
        _choiceRow(
          'other',
          'Other / prefer not to say',
          '⚧️',
          _gender,
          (v) => setState(() => _gender = v),
        ),
      ],
    ),
  );

  Widget _agePage() =>
      _quizPage('How old are you?', null, _numberField(_age, 'Age', 'years'));

  Widget _bodyPage() => _quizPage(
    'Your height & weight',
    'We use these for your calorie & macro targets.',
    Column(
      children: [
        _numberField(_height, 'Height', 'cm'),
        const SizedBox(height: 14),
        _numberField(_weight, 'Weight', 'kg'),
      ],
    ),
  );

  Widget _activityPage() => _quizPage(
    'How active are you?',
    null,
    Column(
      children: [
        _choiceRow(
          'sedentary',
          'Sedentary — little exercise',
          '🪑',
          _activity,
          (v) => setState(() => _activity = v),
        ),
        _choiceRow(
          'light',
          'Lightly active — 1–3 days/wk',
          '🚶',
          _activity,
          (v) => setState(() => _activity = v),
        ),
        _choiceRow(
          'moderate',
          'Moderately active — 3–5 days/wk',
          '🏃',
          _activity,
          (v) => setState(() => _activity = v),
        ),
        _choiceRow(
          'active',
          'Very active — 6–7 days/wk',
          '🏋️',
          _activity,
          (v) => setState(() => _activity = v),
        ),
        _choiceRow(
          'very_active',
          'Athlete — intense daily',
          '🔥',
          _activity,
          (v) => setState(() => _activity = v),
        ),
      ],
    ),
  );

  Widget _goalPage() => _quizPage(
    "What's your goal?",
    'This sets your daily calorie target.',
    Column(
      children: [
        _choiceRow(
          'cut',
          'Lose weight',
          '📉',
          _goal,
          (v) => setState(() => _goal = v),
        ),
        _choiceRow(
          'maintain',
          'Maintain',
          '⚖️',
          _goal,
          (v) => setState(() => _goal = v),
        ),
        _choiceRow(
          'bulk',
          'Build muscle',
          '📈',
          _goal,
          (v) => setState(() => _goal = v),
        ),
      ],
    ),
  );

  Widget _summaryPage() {
    final a = int.tryParse(_age.text.trim()) ?? 0;
    final h = double.tryParse(_height.text.trim()) ?? 0;
    final w = double.tryParse(_weight.text.trim()) ?? 0;
    final hasBody = a > 0 && h > 0 && w > 0;
    final cals = hasBody
        ? computeMacroTargets(
            BodyProfile(
              weight: w,
              height: h,
              age: a,
              gender: _gender,
              activity: _activity,
              goal: _goal,
            ),
          ).calories.round()
        : null;
    final comp = companionByType(appState.activeCompanion);
    return _quizPage(
      "You're all set.",
      'Your plan is personalized.',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summaryTile(
            Icons.local_fire_department_rounded,
            'Daily calorie target',
            hasBody ? '$cals kcal' : 'Add body stats later',
          ),
          const SizedBox(height: 12),
          _summaryTile(
            Icons.checklist_rounded,
            'Starter habits',
            _areas.isEmpty
                ? 'Default starter habits'
                : _areas.map(_areaLabel).join(' · '),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              CompanionSticker(
                icon: comp.icon,
                color: comp.color,
                size: 64,
                semanticLabel: comp.name,
                imageAsset: comp.imageAsset,
              ),
              const SizedBox(width: 10),
              const Flexible(
                child: SpeechBubble(
                  "Let's see if you last a week.",
                  maxWidth: 200,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(IconData icon, String title, String value) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: HrColors.surface,
      borderRadius: BorderRadius.circular(HrRadius.md),
      border: const Border(top: BorderSide(color: HrColors.hairline)),
    ),
    child: Row(
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: HrColors.accent,
          ),
          child: Icon(icon, color: HrColors.bg, size: 18),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: HrText.caption),
              const SizedBox(height: 2),
              Text(
                value,
                style: HrText.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _numberField(TextEditingController c, String hint, String suffix) =>
      TextField(
    controller: c,
    keyboardType: TextInputType.number,
    onChanged: (_) => setState(() {}),
    style: HrText.title2,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: HrText.title2.copyWith(color: HrColors.text3),
      suffixText: suffix,
      suffixStyle: HrText.caption,
      filled: true,
      fillColor: HrColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HrRadius.md),
            borderSide: BorderSide.none,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HrRadius.md),
            borderSide: BorderSide.none,
          ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: const BorderSide(color: HrColors.text, width: 1.5),
      ),
    ),
  );

  Widget _choiceRow(
    String id,
    String label,
    String emoji,
    String group,
    ValueChanged<String> onTap,
  ) {
    final on = group == id;
    return GestureDetector(
      onTap: () => onTap(id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HrRadius.md),
          color: HrColors.surface,
          border: Border(
            top: BorderSide(
              color: on ? HrColors.accent : HrColors.hairline,
              width: on ? 2 : 1,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: HrText.body.copyWith(fontWeight: FontWeight.w600),
            ),
            ),
            if (on)
              Icon(
                Icons.check_circle_rounded,
                color: HrColors.accent,
                size: 22,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Auth UI helpers ──────────────────────────────────────────────────────────
Widget _authScaffold(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<Widget> children,
}) {
  return Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: HrColors.text,
      elevation: 0,
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          HrSpace.gutter,
          8,
          HrSpace.gutter,
          24,
        ),
        children: [
          Text(title, style: HrText.display),
          const SizedBox(height: 6),
          Text(subtitle, style: HrText.bodyS),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    ),
  );
}

Widget _authField(
  TextEditingController c,
  String label, {
  bool obscure = false,
  TextInputType? keyboard,
  String? hint,
  ValueChanged<String>? onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label, style: HrText.caption),
        ),
        TextField(
          controller: c,
          obscureText: obscure,
          keyboardType: keyboard,
          onChanged: onChanged,
          style: HrText.body,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: HrText.body.copyWith(color: HrColors.text3),
            filled: true,
            fillColor: HrColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 16,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.md),
              borderSide: BorderSide.none,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.md),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.md),
              borderSide: const BorderSide(color: HrColors.text, width: 1.5),
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _authSubmit(String label, bool busy, VoidCallback onTap) =>
    HrButton(label: label, loading: busy, onPressed: busy ? null : onTap);

Widget _authError(String msg) => Container(
  margin: const EdgeInsets.only(bottom: 12),
  padding: const EdgeInsets.all(11),
  decoration: BoxDecoration(
    color: HrColors.dangerSurface,
    borderRadius: BorderRadius.circular(HrRadius.sm),
  ),
  child: Row(
    children: [
      const Icon(
        Icons.error_outline_rounded,
        color: HrColors.dangerText,
        size: 17,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          msg,
          style: HrText.caption.copyWith(color: HrColors.dangerText),
        ),
      ),
    ],
  ),
);

Widget _authDivider() => Row(
  children: [
    const Expanded(child: Divider(color: HrColors.hairline, thickness: 1)),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text('or', style: HrText.caption),
    ),
    const Expanded(child: Divider(color: HrColors.hairline, thickness: 1)),
  ],
);

Widget _appleButton() => Column(
  children: [
    const HrButton(
      label: 'Continue with Apple',
      icon: Icons.apple,
      kind: HrButtonKind.secondary,
      onPressed: null,
    ),
    const SizedBox(height: 6),
    Text('Available on iOS', style: HrText.micro),
  ],
);

Widget _authNote() {
  if (auth.isRemote) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Text(
      'Accounts are stored on this device for now — cloud sync turns on when Supabase is connected.',
      textAlign: TextAlign.center,
      style: HrText.micro.copyWith(height: 1.4),
    ),
  );
}

Widget _statChip(String label, String value) => Container(
  width: 104,
  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
  decoration: BoxDecoration(
    color: HrColors.surface,
    borderRadius: BorderRadius.circular(HrRadius.md),
    border: const Border(top: BorderSide(color: HrColors.hairline)),
  ),
  child: Column(
    children: [
      Text(value, style: HrText.stat),
      const SizedBox(height: 2),
      Text(label, textAlign: TextAlign.center, style: HrText.caption),
    ],
  ),
);

String _memberSince(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
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
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
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
      title: const Text(
        'Delete account?',
        style: TextStyle(color: kTextPrimary),
      ),
      content: const Text(
        'This removes your account and signs you out. Your habits and progress stay on this device — use "Reset all progress" to clear those. This cannot be undone.',
        style: TextStyle(color: kTextSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: kRed,
            foregroundColor: Colors.white,
          ),
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
// Lets any screen jump the bottom-nav to a tab (e.g. Focus → "Back to Today").
final ValueNotifier<int> shellTab = ValueNotifier<int>(0);

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
    shellTab.addListener(_onShellTab);
    _reminderTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkReminders(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkReminders());
  }

  void _onShellTab() {
    if (mounted && shellTab.value != _index) {
      setState(() => _index = shellTab.value);
    }
  }

  @override
  void dispose() {
    shellTab.removeListener(_onShellTab);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏰ Time for: ${h.name}'),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Done',
            onPressed: () {
              if (!appState.doneToday(h)) appState.toggle(h);
            },
          ),
        ),
      );
    }
  }

  // Today has its own '+' in the header now, so no global FAB.
  Widget? _fab() => null;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (appState.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
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
        final screens = <Widget>[
          HomeScreen(),
          FocusScreen(),
          ProgressScreen(),
          FriendsScreen(),
          SettingsScreen(),
        ];
        return Scaffold(
          body: IndexedStack(index: _index, children: screens),
          floatingActionButton: _fab(),
          bottomNavigationBar: HrTabBar(
            index: _index,
            onTap: (i) => shellTab.value = i,
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
  const _Avatar({this.size = 40, this.showBorder = true});
  final double size;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final b = borderById(appState.selectedBorder);
    final hasBorder = showBorder && b.id != 'none';
    // Thicker, glowing ring with a thin dark gap so the colour reads as a
    // distinct border against both the avatar and the cosmic background.
    final ringW = hasBorder
        ? (size * 0.11).clamp(3.0, 7.0)
        : (size * 0.06).clamp(2.0, 4.0);
    final gapW = hasBorder && b.frameAsset == null
        ? (size * 0.03).clamp(1.5, 3.0)
        : 0.0;
    final frameAsset = showBorder ? b.frameAsset : null;
    final inner = frameAsset != null
        ? size * 0.72
        : (showBorder ? size - (ringW + gapW) * 2 : size);
    final name = appState.displayName;
    final Widget pic = appState.pfpBytes != null
        ? Image.memory(
            appState.pfpBytes!,
            width: inner,
            height: inner,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : Container(
            width: inner,
            height: inner,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [kPlasma, kBlue]),
            ),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(fontFamily: kHrFont,
                color: Colors.white,
                fontSize: inner * 0.42,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
    Widget avatar = ClipOval(child: pic);
    // Dark separator ring between the colour and the avatar.
    if (gapW > 0) {
      avatar = Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF140B2B),
        ),
        padding: EdgeInsets.all(gapW),
        child: avatar,
      );
    }
    if (!showBorder) {
      return SizedBox(width: size, height: size, child: avatar);
    }
    if (frameAsset != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(width: inner, height: inner, child: avatar),
            Image.asset(
              frameAsset,
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ],
        ),
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
                  spreadRadius: 1.0,
                ),
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
  if (b.frameAsset != null) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size * 0.56,
            height: size * 0.56,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: kElevated,
            ),
          ),
          Image.asset(
            b.frameAsset!,
            width: size,
            height: size,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ],
      ),
    );
  }
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
          ? [
              BoxShadow(
                color: b.colors.first.withValues(alpha: 0.5),
                blurRadius: 8,
              ),
            ]
          : null,
    ),
    child: const DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: kElevated),
    ),
  );
}

// Pick a photo, center-crop + downscale to a tiny JPEG, and store it.
Future<void> _pickProfilePhoto(BuildContext context) async {
  try {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 85,
    );
    if (x == null) return;
    final bytes = await x.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      if (context.mounted) _toast(context, "Couldn't read that image.");
      return;
    }
    final side = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final cropped = img.copyCrop(
      decoded,
      x: (decoded.width - side) ~/ 2,
      y: (decoded.height - side) ~/ 2,
      width: side,
      height: side,
    );
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
        child: Text('Remove', style: HrText.caption),
      ),
    ],
  ],
);

// _coinsPill and _shopButton were replaced by _coinChip and per-screen headers.

// ── Glass phase-2 helpers ───────────────────────────────────────────────────

// Deep indigo glass surface with a violet edge and soft shadow.
const LinearGradient _kGlassSheen = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomCenter,
  colors: [Color(0xF01A1B2C), Color(0xF10D0E17)],
);

BoxDecoration glassDecoration({double radius = 18, Color? border}) =>
    BoxDecoration(
  borderRadius: BorderRadius.circular(radius),
  gradient: _kGlassSheen,
  border: Border.all(color: border ?? HrColors.cardEdge),
      boxShadow: const [
        BoxShadow(
          color: Color(0x40000000),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ],
);

const List<Color> _kAccentGradient = [Color(0xFF8E43F5), Color(0xFFB56BFF)];

// Violet glow primary button used by the older custom routes.
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
                  color: const Color(0xFF9B55FF).withValues(alpha: 0.34),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
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
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
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
    final c = colors ?? const [Color(0xFFFFC82F), Color(0xFFFFE277)];
    final v = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: v),
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0x22FFFFFF)),
              ),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: c),
                    boxShadow: [
                      BoxShadow(
                        color: c.last.withValues(alpha: 0.5),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Luminous gradient progress ring.
class GlowRing extends StatelessWidget {
  const GlowRing({
    required this.value,
    required this.size,
    this.stroke = 6,
    this.colors,
    super.key,
  });
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
          painter: _RingPainter(
            animatedValue,
            stroke,
            colors ?? _kAccentGradient,
          ),
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
        ..color = const Color(0x1FFFFFFF),
    );
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
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawArc(rect, -pi / 2, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.colors != colors || old.stroke != stroke;
}

// Dashboard app bar: profile picture + level on the LEFT, coins + shop RIGHT.
// _dashboardBar was replaced by the Today header (see _todayHeader).

// Standard app bar for the other tabs: title left; coins + shop + avatar right.
// _titleBar was replaced by flat per-screen headers in the redesign.

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
          ..showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 1100),
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt_rounded, color: kGold, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Habit complete  ·  +$reward XP',
                    style: const TextStyle(
                      color: kTextPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
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
        if (total > 0 &&
            doneBefore < total &&
            appState.doneTodayCount == total) {
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
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
          children: [
            _todayHeader(context),
            const SizedBox(height: 22),
            if (appState.habits.isEmpty)
              _todayEmpty(context)
            else
              _FiveCard(onToggle: onToggle),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
              child: HrCard(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const DashboardScreen())),
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                child: Row(children: [
                  HrHeroArt(
                    width: 92,
                    height: 70,
                    child: Image.asset('assets/achievements/first.png',
                        width: 60, height: 60),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Dashboard', style: HrText.headline),
                          const SizedBox(height: 2),
                          Text('Small steps drive big progress.',
                              style: HrText.bodyS),
                        ]),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: HrColors.text2, size: 28),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── DASHBOARD: everything that used to stack under Today's habits ────────────
// Keeps Today clean (just habits); the companion, coach, tasks, quests, boss,
// nutrition, victory and prestige cards live here behind a button.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: const HrAppBarTitle('Dashboard'),
      ),
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final hasTasks =
              appState.dailiesToday.isNotEmpty || appState.openTodos.isNotEmpty;
          final hasChallenge = appState.activeChallenge != null;

          return ListView(
            padding: const EdgeInsets.fromLTRB(0, 6, 0, 100),
            children: [
              const SizedBox(height: 4),
              if (hasTasks || hasChallenge) ...[
                const HrLabel('Today'),
                if (hasTasks) const _TasksCard(),
                if (hasChallenge) const _ChallengeTodayCard(),
                const SizedBox(height: 12),
              ],
              const HrLabel('Your progress'),
              const _VictoryCard(),
              const _NutritionCard(),
              const SizedBox(height: 12),
              const HrLabel('Adventure'),
              const _BossCard(),
              const _QuestsPanel(),
              const SizedBox(height: 12),
              const HrLabel('Coach'),
              const _CoachCard(),
            ],
          );
        },
      ),
    );
  }
}

// ── TODAY primitives (redesign) ──────────────────────────────────────────────
const _kWeekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _kMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
String _prettyToday() {
  final d = DateTime.now();
  return '${_kWeekdays[d.weekday - 1]}, ${_kMonths[d.month - 1]} ${d.day}';
}

// Small tappable coins chip (opens the Shop) — replaces the old violet pill.
Widget _coinChip(BuildContext context) => GestureDetector(
  onTap: () =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ShopScreen())),
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: HrColors.surface2,
      borderRadius: BorderRadius.circular(HrRadius.full),
      border: Border.all(color: HrColors.gold.withValues(alpha: 0.3)),
      boxShadow: [
        BoxShadow(
          color: HrColors.gold.withValues(alpha: 0.08),
          blurRadius: 12,
        ),
      ],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (appState.xpBoostActive) ...[
          Text(
            '2×',
            style: HrText.caption.copyWith(
              color: HrColors.gold,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
        ],
        Image.asset(
          'assets/shop/coin_stack.png',
          width: 19,
          height: 19,
          fit: BoxFit.contain,
          semanticLabel: 'Coins',
        ),
        const SizedBox(width: 5),
        Text(
          '${appState.coins}',
          style: HrText.caption.copyWith(
            color: HrColors.text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  ),
);

/// "Level 9 · XP to next level 420 / 1,000" with the gold bar — shared by
/// Today and Profile so both read the same.
class _LevelPanel extends StatelessWidget {
  const _LevelPanel({this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    return HrCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      radius: HrRadius.md + 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text.rich(TextSpan(children: [
                TextSpan(
                  text: 'Level ',
                  style: HrText.title2.copyWith(color: HrColors.lavender),
                ),
                TextSpan(
                  text: '${ld.level}',
                  style: HrText.title1.copyWith(
                    fontSize: compact ? 26 : 28,
                    color: HrColors.accentBright,
                    shadows: [
                      Shadow(
                        color: HrColors.accent.withValues(alpha: 0.7),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                ),
              ])),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('XP to next level',
                          style: HrText.micro.copyWith(color: HrColors.text2)),
                      Text.rich(TextSpan(children: [
                        TextSpan(
                          text: hrNum(ld.currentXp),
                          style: HrText.bodyS.copyWith(
                              color: HrColors.gold, fontWeight: FontWeight.w900),
                        ),
                        TextSpan(
                          text: ' / ${hrNum(ld.requiredXp)}',
                          style: HrText.bodyS.copyWith(
                              color: HrColors.text, fontWeight: FontWeight.w800),
                        ),
                      ])),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          HrXpBar(value: ld.progress, height: 11),
        ],
      ),
    );
  }
}

// Today header: big title with the mascot, the level panel and streak meter.
Widget _todayHeader(BuildContext context) {
  final streak = appState.bestStreak;
  final streakMarks = streak == 0 ? 0 : (streak % 7 == 0 ? 6 : streak % 7);
  return Padding(
    padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 168,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Positioned(
                right: -14,
                top: -4,
                child: HrHeroArt(width: 168, height: 178),
              ),
              Positioned(
                left: 0,
                top: 16,
                child: Semantics(
                  header: true,
                  label: 'Today, ${_prettyToday()}',
                  child: Text('Today',
                      style: HrText.display.copyWith(fontSize: 40)),
                ),
              ),
              const Positioned(
                left: 0,
                right: 128,
                bottom: 0,
                child: _LevelPanel(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        HrCard(
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RecoveryScreen())),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          radius: HrRadius.md + 2,
          child: Row(
            children: [
              Image.asset(
                'assets/streaks/enamel_flame.png',
                width: 36,
                height: 36,
              ),
              const SizedBox(width: 10),
              Text(
                '$streak',
                style: HrText.display.copyWith(
                    fontSize: 32, height: 1, color: HrColors.gold),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'day streak',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              HrStreakSquares(total: 6, filled: streakMarks, size: 14),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded,
                  color: HrColors.text2, size: 28),
            ],
          ),
        ),
      ],
    ),
  );
}

// Colourful glow behind each quest's 3D icon, stable per habit.
const _kQuestTints = [
  Color(0xFF4FA3FF),
  Color(0xFFA06BFF),
  Color(0xFFFF6EB4),
  Color(0xFF34D399),
  Color(0xFFFF9F43),
  Color(0xFF62D5FF),
];
Color _questTint(Habit h) =>
    _kQuestTints[h.name.codeUnits.fold<int>(0, (a, c) => a + c) %
        _kQuestTints.length];

Widget _questIcon(Habit h, {double size = 56}) {
  final icon = h.icon.trim();
  return icon == '💰'
      ? HrIconTile(asset: 'assets/shop/coin_stack.png', size: size)
      : HrIconTile(emoji: icon, size: size, color: _questTint(h));
}


// "The five" — today's habits as HabitRows, with swipe-to-delete and a
// reorder mode. Replaces the old _HabitTile list + TODAY'S HABITS label.
class _FiveCard extends StatefulWidget {
  const _FiveCard({required this.onToggle});
  final void Function(Habit) onToggle;
  @override
  State<_FiveCard> createState() => _FiveCardState();
}

class _FiveCardState extends State<_FiveCard> {
  bool _reorder = false;

  Widget _questTile(BuildContext context, Habit h) {
    final isDone = appState.doneToday(h);
    final meta = [
      if (h.streak > 0) '🔥 ${h.streak}',
      if (h.reminderMinutes != null) _fmtReminder(h.reminderMinutes!),
    ].join('  ·  ');
    return HrQuestRow(
      title: h.name,
      done: isDone,
      leading: _questIcon(h),
      subtitle: Row(
        children: [
          HrXpChip(appState.projectedXp(h)),
          if (meta.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HrText.micro.copyWith(color: HrColors.text2),
              ),
            ),
          ],
        ],
      ),
      onTap: () {
        if (!isDone) HapticFeedback.selectionClick();
        widget.onToggle(h);
      },
      onLongPress: () => _showHabitMenu(context, h),
    );
  }

  Widget _habitRow(BuildContext context, Habit h) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Dismissible(
      key: ValueKey('five-${h.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        appState.deleteHabit(h);
        hrToast(context, 'Habit removed', icon: Icons.delete_outline_rounded);
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          color: HrColors.dangerSurface,
          borderRadius: BorderRadius.circular(HrRadius.md + 2),
        ),
        child: const Icon(
          Icons.delete_outline_rounded,
          color: HrColors.dangerText,
        ),
      ),
      child: _questTile(context, h),
    ),
  );

  Widget _roundAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool filled = false,
  }) =>
      Tooltip(
        message: tooltip,
        child: HrPressable(
          onTap: onTap,
          scale: 0.9,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? HrColors.accent : HrColors.surface,
              border: Border.all(
                color: filled
                    ? HrColors.accentBright.withValues(alpha: 0.6)
                    : HrColors.cardEdge,
              ),
              boxShadow: filled
                  ? [
                      BoxShadow(
                        color: HrColors.accent.withValues(alpha: 0.5),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon,
                size: 20, color: filled ? HrColors.text : HrColors.text2),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final habits = appState.habits;
    final done = habits.where(appState.doneToday).length;
    final allDone = done == habits.length && habits.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 0, 12),
            child: Row(
              children: [
                const Text('⚔️', style: TextStyle(fontSize: 20, height: 1)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "Today's quests",
                    style: HrText.headline.copyWith(fontSize: 19),
                  ),
                ),
                const Icon(Icons.auto_awesome,
                    size: 14, color: HrColors.gold),
                const SizedBox(width: 5),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '$done',
                      style: HrText.headline.copyWith(
                          fontSize: 17, color: const Color(0xFF8FD3FF)),
                    ),
                    TextSpan(
                      text: ' / ${habits.length}',
                      style: HrText.headline.copyWith(
                          fontSize: 17, color: HrColors.text2),
                    ),
                  ]),
                  semanticsLabel: '$done of ${habits.length} quests done',
                ),
                const SizedBox(width: 12),
                _roundAction(
                  icon: _reorder
                      ? Icons.check_rounded
                      : Icons.swap_vert_rounded,
                  tooltip: _reorder ? 'Done reordering' : 'Reorder quests',
                  onTap: () => setState(() => _reorder = !_reorder),
                ),
                const SizedBox(width: 8),
                _roundAction(
                  icon: Icons.add_rounded,
                  tooltip: 'Add habit',
                  filled: true,
                  onTap: () => showHabitEditor(context),
                ),
              ],
            ),
          ),
          if (_reorder)
            HrCard(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: habits.length,
                onReorderItem: appState.reorderHabits,
                itemBuilder: (ctx, i) {
                  final h = habits[i];
                  return Padding(
                    key: ValueKey('reorder-${h.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        _questIcon(h, size: 40),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            h.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HrText.body
                                .copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: HrColors.text2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
          else ...[
            if (allDone)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: HrCard(
                  highlight: true,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const HrCheck(done: true, size: 40),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('All quests complete',
                                style: HrText.headline),
                            const SizedBox(height: 2),
                            Text(
                              '$done ${done == 1 ? 'habit' : 'habits'} checked off today',
                              style: HrText.bodyS,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (final h in habits) _habitRow(context, h),
          ],
        ],
      ),
    );
  }
}

// Zero-habits prompt shown in place of the quest list.
Widget _todayEmpty(BuildContext context) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
  child: HrCard(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
    child: Column(
      children: [
        const HrHeroArt(width: 130, height: 130),
        const SizedBox(height: 8),
        Text('No quests yet', style: HrText.title2),
        const SizedBox(height: 6),
        Text(
          'Add your first habit to start your trail.',
          textAlign: TextAlign.center,
          style: HrText.bodyS,
        ),
        const SizedBox(height: 18),
        HrButton(
          label: 'Add habit',
          icon: Icons.add_rounded,
          kind: HrButtonKind.accent,
          onPressed: () => showHabitEditor(context),
        ),
      ],
    ),
  ),
);

class _VictoryCard extends StatelessWidget {
  const _VictoryCard();
  @override
  Widget build(BuildContext context) {
    final v = appState.victory();
    final color = victoryColor(v.score);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Row(
          children: [
            SegmentedRing(
              size: 64,
              segments: 1,
              value: v.score / 100,
              stroke: 6,
              color: color,
              center: Text(
                '${v.score}',
                style: HrText.stat.copyWith(fontSize: 20),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('VICTORY SCORE', style: HrText.labelCaps),
                  const SizedBox(height: 3),
                  Text(
                    victoryLabel(v.score),
                    style: HrText.headline.copyWith(color: color),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Habits ${v.habits} · Nutr ${v.nutrition} · Focus ${v.focus} · Sleep ${v.sleep}',
                    style: HrText.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BossCard extends StatelessWidget {
  const _BossCard();
  @override
  Widget build(BuildContext context) {
    final count = appState.perfectDaysThisWeek().clamp(0, kBossGoal);
    final defeated = count >= kBossGoal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Image.asset(
                  kBossImageAsset,
                  width: 42,
                  height: 42,
                  fit: BoxFit.contain,
                  semanticLabel: 'Veil Regent weekly boss',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    kBossTitle,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  defeated ? 'DEFEATED' : '$count/$kBossGoal',
                  style: HrText.body.copyWith(
                    color: defeated ? HrColors.gold : HrColors.text2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(HrRadius.full),
              child: LinearProgressIndicator(
                value: (count / kBossGoal).clamp(0.0, 1.0).toDouble(),
                minHeight: 8,
                backgroundColor: HrColors.surface3,
                valueColor: const AlwaysStoppedAnimation(HrColors.gold),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              defeated
                  ? 'Reward claimed: +$kBossXp XP · +$kBossCoins coins'
                  : '$kBossDesc  (+$kBossXp XP, +$kBossCoins coins)',
              style: HrText.caption,
            ),
            const SizedBox(height: 6),
            Text(
              'Season ${appState.currentSeason + 1} · ${appState.seasonBossDefeats}/4 bosses',
              style: HrText.caption.copyWith(
                color: HrColors.info,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestsPanel extends StatelessWidget {
  const _QuestsPanel();
  @override
  Widget build(BuildContext context) {
    final claimed = appState.questClaimedIds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('DAILY QUESTS', style: HrText.labelCaps),
                Text(
                  '${claimed.length}/${kQuests.length}',
                  style: HrText.labelCaps.copyWith(color: HrColors.accent),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...kQuests.map((q) {
              final on = claimed.contains(q.id);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      on ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 18,
                      color: on ? HrColors.accent : HrColors.text3,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        q.title,
                        style: HrText.bodyS.copyWith(
                          color: on ? HrColors.text3 : HrColors.text,
                          decoration: on ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    Text(
                      '+${q.xp}',
                      style: HrText.caption.copyWith(
                        color: on ? HrColors.text3 : HrColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ── AI COACH (freemium) ─────────────────────────────────────────────────────
// On-demand coaching the user requests, metered against a weekly allowance
// (free vs Premium). A real AI reply spends one prompt; if AI is unavailable
// (off / unreachable) a templated nudge shows and nothing is spent.
class _CoachCard extends StatefulWidget {
  const _CoachCard();
  @override
  State<_CoachCard> createState() => _CoachCardState();
}

class _CoachCardState extends State<_CoachCard> {
  String? _message;
  bool _loading = false;

  String _resetLabel() {
    final d = appState.coachResetDate;
    return 'Resets ${_kWeekdays[d.weekday - 1].substring(0, 3)} ${_kMonths[d.month - 1]} ${d.day}';
  }

  String _fallback() {
    final done = appState.doneTodayCount;
    final total = appState.habits.length;
    if (total == 0) return 'Add your first habit and start a streak today.';
    final left = total - done;
    if (left <= 0) return 'Perfect day — every habit done. Protect your streak tomorrow!';
    return "You've done $done of $total today. $left more for a perfect day.";
  }

  Future<void> _coachMe() async {
    if (!appState.canUseCoach) {
      _showCoachPaywall(context);
      return;
    }
    setState(() => _loading = true);
    final ld = levelFromXp(appState.totalXp);
    final v = appState.victory();
    final summary =
        'Name: ${appState.displayName}. Level ${ld.level} (${levelTitle(ld.level)}). '
        'Victory score today: ${v.score}/100 (${victoryLabel(v.score)}). '
        'Habits done today: ${appState.doneTodayCount}/${appState.habits.length}. '
        'Best streak: ${appState.bestStreak} days. Coins: ${appState.coins}.';
    final msg = await aiCoachMessage(
      summary,
      enabled: appState.aiEnabled,
      baseUrl: appState.aiBaseUrl,
      model: appState.aiModel,
    );
    if (!mounted) return;
    if (msg != null) {
      appState.consumeCoachUse(); // only a real AI reply spends an allowance
      setState(() {
        _message = msg;
        _loading = false;
      });
    } else {
      setState(() {
        _message = _fallback();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = appState.coachUsesLeft;
    final atLimit = !appState.canUseCoach;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('YOUR COACH', style: HrText.labelCaps)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: atLimit ? HrColors.surface2 : HrColors.accentSurface,
                  borderRadius: BorderRadius.circular(HrRadius.xs)),
              child: Text(
                  appState.isPremium ? 'PREMIUM' : '$left of ${appState.coachLimit} left',
                  style: HrText.micro.copyWith(
                      color: atLimit ? HrColors.text3 : HrColors.accent,
                      fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 10),
          if (_loading)
            Row(children: [
              const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Reading your day…', style: HrText.bodyS),
            ])
          else
            Text(
              _message == null
                  ? (atLimit
                      ? "You've used your ${appState.coachLimit} free coaching prompts this week."
                      : 'Tap for a quick, personalized nudge for today.')
                  : '"$_message"',
              style: HrText.bodyS.copyWith(
                color: HrColors.text2,
                fontStyle: _message == null ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          if (!appState.isPremium) ...[
            const SizedBox(height: 4),
            Text(_resetLabel(), style: HrText.micro),
          ],
          const SizedBox(height: 12),
          if (atLimit && !appState.isPremium)
            HrButton(
              label: 'Unlock more with Premium',
              icon: Icons.workspace_premium_rounded,
              onPressed: () => _showCoachPaywall(context),
            )
          else
            HrButton(
              label: 'Coach me',
              icon: Icons.auto_awesome_rounded,
              kind: HrButtonKind.secondary,
              loading: _loading,
              onPressed: _loading ? null : _coachMe,
            ),
          // Debug-only: flip Premium to exercise the higher weekly limit.
          // kDebugMode is false in release builds, so this never ships.
          if (kDebugMode) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: HrColors.hairline),
            Row(children: [
              const Icon(Icons.bug_report_rounded, size: 14, color: HrColors.text3),
              const SizedBox(width: 6),
              Text('Premium (debug)', style: HrText.micro),
              const Spacer(),
              Switch(
                value: appState.isPremium,
                onChanged: (v) => setState(() => appState.setPremium(v)),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

// Friendly, non-blocking upgrade prompt shown when the free allowance is spent.
void _showCoachPaywall(BuildContext context) {
  final d = appState.coachResetDate;
  final resets = '${_kWeekdays[d.weekday - 1].substring(0, 3)} ${_kMonths[d.month - 1]} ${d.day}';
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl))),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                  color: HrColors.surface3, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Row(children: [
            const Icon(Icons.workspace_premium_rounded, color: HrColors.gold, size: 24),
            const SizedBox(width: 10),
            Text('Unlock more coaching', style: HrText.title2),
          ]),
          const SizedBox(height: 12),
          Text(
            'Free includes $kFreeCoachLimit AI coaching prompts a week. Premium gives '
            'you $kPremiumCoachLimit a week — personalized nudges whenever you want them.',
            style: HrText.bodyS,
          ),
          const SizedBox(height: 8),
          Text('Your free prompts reset $resets.', style: HrText.caption),
          const SizedBox(height: 20),
          HrButton(
            label: 'See Premium',
            icon: Icons.workspace_premium_rounded,
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PremiumScreen()),
              );
            },
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Maybe later', style: HrText.caption)),
          ),
        ],
      ),
    ),
  );
}

// ── Habitrail Premium — upgrade / manage ────────────────────────────────────
// A single value-prop row on the upgrade page and the "included" list.
class _PremiumProp extends StatelessWidget {
  const _PremiumProp(this.icon, this.title, this.sub);
  final IconData icon;
  final String title, sub;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: HrColors.accentSurface,
              borderRadius: BorderRadius.circular(HrRadius.sm)),
          child: Icon(icon, color: HrColors.accent, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: HrText.headline),
            const SizedBox(height: 2),
            Text(sub, style: HrText.caption),
          ]),
        ),
      ]),
    );
  }
}

// Entry card on the You screen: upsell when free, status when Premium.
class _PremiumYouCard extends StatelessWidget {
  const _PremiumYouCard();
  @override
  Widget build(BuildContext context) {
    final premium = appState.isPremium;
    return HrCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PremiumScreen()),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: HrColors.accentSurface,
              borderRadius: BorderRadius.circular(HrRadius.md)),
          child: const Icon(Icons.workspace_premium_rounded,
              color: HrColors.gold, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(premium ? 'Habitrail Premium' : 'Go Premium',
                style: HrText.headline),
            const SizedBox(height: 2),
            Text(premium ? 'Active — manage your plan' : 'Coach, insights & more',
                style: HrText.caption),
          ]),
        ),
        if (premium)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: HrColors.accentSurface,
                borderRadius: BorderRadius.circular(HrRadius.xs)),
            child: Text('PREMIUM',
                style: HrText.micro
                    .copyWith(color: HrColors.accent, fontWeight: FontWeight.w800)),
          )
        else
          const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
      ]),
    );
  }
}

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});
  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  String _plan = 'annual'; // default to the better-value plan

  @override
  void initState() {
    super.initState();
    purchases.init(); // no-op off iOS/Android; loads store products on device
  }

  String _fmtDate(String key) {
    final d = DateTime.tryParse(key);
    if (d == null) return '';
    return '${_kMonths[d.month - 1]} ${d.day}, ${d.year}';
  }

  List<Widget> _props() => [
        _PremiumProp(Icons.auto_awesome_rounded, 'AI coach & plans',
            '$kPremiumCoachLimit prompts a week, a Weekly Report and a Weekly Plan'),
        const _PremiumProp(Icons.insights_rounded, 'Deeper insights',
            'Consistency trends, best days, and cross-habit patterns'),
        const _PremiumProp(Icons.flag_rounded, 'Challenges & recovery',
            'Guided 7 & 30-day programs, streak-saves and rest days'),
        const _PremiumProp(Icons.palette_rounded, 'Make it yours',
            'Companion skins, the Nebula theme and a PREMIUM badge'),
      ];

  void _start() {
    if (purchases.available) {
      purchases.buy(_plan); // real store flow; success arrives via the stream
    } else {
      // No store on this platform (e.g. the Windows dev build) — activate the
      // in-app scaffold so Premium stays testable.
      appState.activatePremium(_plan);
      hrToast(context, "You're Premium — enjoy! ✨",
          icon: Icons.workspace_premium_rounded);
    }
  }

  void _manage() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: HrColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Manage Premium', style: HrText.title2),
              const SizedBox(height: 10),
              Text(
                  'To stop auto-renewal, cancel in your App Store or Google Play '
                  'account. This clears Premium on this device now; your habits, '
                  'history and coins stay.',
                  style: HrText.bodyS),
              const SizedBox(height: 20),
              HrButton(
                label: 'Cancel Premium',
                kind: HrButtonKind.danger,
                onPressed: () {
                  appState.cancelPremium();
                  Navigator.pop(ctx);
                  hrToast(context, 'Premium cancelled.',
                      icon: Icons.info_outline_rounded);
                },
              ),
              const SizedBox(height: 8),
              Center(
                  child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Keep Premium', style: HrText.caption))),
            ]),
      ),
    );
  }

  Widget _planCard(String id, String title, String price, String sub,
      {bool popular = false}) {
    final selected = _plan == id;
    return GestureDetector(
      onTap: () => setState(() => _plan = id),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? HrColors.accentSurface : HrColors.surface,
          borderRadius: BorderRadius.circular(HrRadius.lg),
          border: Border.all(
              color: selected ? HrColors.accent : HrColors.hairline,
              width: selected ? 2 : 1),
        ),
        child: Row(children: [
          Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? HrColors.accent : HrColors.text3,
              size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: HrText.headline),
                if (popular) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: HrColors.accent,
                        borderRadius: BorderRadius.circular(HrRadius.xs)),
                    child: Text('MOST POPULAR',
                        style: HrText.micro.copyWith(
                            color: HrColors.onAccent,
                            fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(sub, style: HrText.caption),
            ]),
          ),
          Text(price, style: HrText.headline),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, purchases]),
      builder: (context, _) {
        final premium = appState.isPremium;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Habitrail Premium'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 4, HrSpace.gutter, 32),
            children: [
              Row(children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: HrColors.accentSurface,
                      borderRadius: BorderRadius.circular(HrRadius.md)),
                  child: const Icon(Icons.workspace_premium_rounded,
                      color: HrColors.gold, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(premium ? "You're Premium" : 'Go Premium',
                            style: HrText.title1),
                        const SizedBox(height: 2),
                        Text(
                            premium
                                ? 'Thanks for supporting Habitrail.'
                                : 'Your personal coach, unlocked.',
                            style: HrText.caption),
                      ]),
                ),
              ]),
              const SizedBox(height: 18),
              if (premium) ...[
                HrCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.verified_rounded,
                              color: HrColors.accent, size: 18),
                          const SizedBox(width: 8),
                          Text(
                              appState.premiumPlan == 'annual'
                                  ? 'Annual plan'
                                  : appState.premiumPlan == 'monthly'
                                      ? 'Monthly plan'
                                      : 'Premium',
                              style: HrText.headline),
                        ]),
                        if (appState.premiumSince.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('Premium since ${_fmtDate(appState.premiumSince)}',
                              style: HrText.caption),
                        ],
                      ]),
                ),
                const SizedBox(height: 16),
                const HrLabel("What's included"),
                const SizedBox(height: 10),
                ..._props(),
                const SizedBox(height: 18),
                HrButton(
                    label: 'Manage subscription',
                    kind: HrButtonKind.secondary,
                    onPressed: _manage),
              ] else ...[
                const HrLabel('What you get'),
                const SizedBox(height: 10),
                ..._props(),
                const SizedBox(height: 18),
                _planCard(
                    'annual',
                    'Annual',
                    '${purchases.priceFor('annual', kPremiumAnnualPrice)}/yr',
                    '≈ $kPremiumAnnualPerMonth/mo · Save $kPremiumAnnualSavingsPct%',
                    popular: true),
                const SizedBox(height: 10),
                _planCard(
                    'monthly',
                    'Monthly',
                    '${purchases.priceFor('monthly', kPremiumMonthlyPrice)}/mo',
                    'Billed monthly'),
                const SizedBox(height: 18),
                HrButton(
                  label: purchases.busy
                      ? 'Processing…'
                      : _plan == 'annual'
                          ? 'Start Premium — ${purchases.priceFor('annual', kPremiumAnnualPrice)}/yr'
                          : 'Start Premium — ${purchases.priceFor('monthly', kPremiumMonthlyPrice)}/mo',
                  icon: Icons.workspace_premium_rounded,
                  kind: HrButtonKind.accent,
                  loading: purchases.busy,
                  onPressed: purchases.busy ? null : _start,
                ),
                if (purchases.error != null) ...[
                  const SizedBox(height: 8),
                  Text(purchases.error!,
                      style:
                          HrText.caption.copyWith(color: HrColors.dangerText),
                      textAlign: TextAlign.center),
                ],
                if (purchases.available) ...[
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                        onPressed: purchases.restore,
                        child:
                            Text('Restore purchases', style: HrText.caption)),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  purchases.available
                      ? 'Subscriptions auto-renew until cancelled; manage them in '
                          'your App Store / Google Play account. Your habit '
                          'tracking and core features always stay free.'
                      : 'No store on this platform, so this build activates Premium '
                          'instantly for testing; iOS and Android use real billing. '
                          'Your habit tracking and core features always stay free.',
                  style: HrText.micro,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ── Premium: Guided challenges ──────────────────────────────────────────────
Widget _challengeDayTag(int days) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: HrColors.surface2, borderRadius: BorderRadius.circular(HrRadius.xs)),
      child: Text('$days-day',
          style: HrText.micro
              .copyWith(color: HrColors.text2, fontWeight: FontWeight.w700)),
    );

// Four milestone markers (quarter, half, three-quarter, finish), lit as the
// user's check-ins reach each day threshold.
Widget _challengeMilestones(int days, int done) {
  final marks = <int>[
    (days / 4).ceil(),
    (days / 2).ceil(),
    (days * 3 / 4).ceil(),
    days,
  ];
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: marks.map((m) {
      final reached = done >= m;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(reached ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 18, color: reached ? HrColors.accent : HrColors.surface3),
        const SizedBox(height: 3),
        Text('Day $m',
            style: HrText.micro
                .copyWith(color: reached ? HrColors.text2 : HrColors.text3)),
      ]);
    }).toList(),
  );
}

// Compact active-challenge card on Today: progress + the daily check-in.
class _ChallengeTodayCard extends StatelessWidget {
  const _ChallengeTodayCard();

  void _checkIn(BuildContext context, ChallengeDef c) {
    final completed = appState.checkInChallenge();
    if (completed) {
      celebrate(context);
      _showChallengeComplete(context, c);
    } else {
      hrToast(context, 'Checked in — ${appState.challengeCheckInCount}/${c.days}',
          icon: Icons.check_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final c = appState.activeChallenge;
        if (c == null) return const SizedBox.shrink();
        final done = appState.challengeCheckInCount;
        final checkedToday = appState.challengeCheckedInToday;
        return Padding(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
          child: HrCard(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const ChallengesScreen())),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(c.icon, color: HrColors.accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(c.title,
                        style: HrText.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                Text('$done/${c.days}', style: HrText.caption),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(HrRadius.full),
                child: LinearProgressIndicator(
                    value: appState.challengeProgress,
                    minHeight: 6,
                    backgroundColor: HrColors.surface3,
                    valueColor: AlwaysStoppedAnimation(HrColors.accent)),
              ),
              const SizedBox(height: 10),
              Text(c.focus, style: HrText.bodyS.copyWith(color: HrColors.text2)),
              const SizedBox(height: 12),
              if (checkedToday)
                Row(children: [
                  Icon(Icons.check_circle_rounded,
                      color: HrColors.accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Checked in today — see you tomorrow.',
                          style: HrText.bodyS.copyWith(color: HrColors.text2))),
                ])
              else
                HrButton(
                    label: 'Check in for today',
                    icon: Icons.check_rounded,
                    kind: HrButtonKind.accent,
                    onPressed: () => _checkIn(context, c)),
            ]),
          ),
        );
      },
    );
  }
}

class ChallengesScreen extends StatelessWidget {
  const ChallengesScreen({super.key});

  Future<void> _start(BuildContext context, ChallengeDef c) async {
    if (!appState.isPremium) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PremiumScreen()));
      return;
    }
    if (appState.activeChallenge != null && appState.activeChallengeId != c.id) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: HrColors.surface,
          title: Text('Switch challenge?', style: HrText.title2),
          content: Text(
              'Starting "${c.title}" ends your current challenge and its progress.',
              style: HrText.bodyS),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Keep current', style: HrText.caption)),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Switch',
                    style: HrText.body.copyWith(color: HrColors.accent))),
          ],
        ),
      );
      if (ok != true) return;
    }
    appState.startChallenge(c.id);
    if (context.mounted) {
      hrToast(context, 'Challenge started — check in each day!',
          icon: Icons.flag_rounded);
    }
  }

  Future<void> _abandon(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text('End challenge?', style: HrText.title2),
        content: Text('Your progress on this challenge will be cleared.',
            style: HrText.bodyS),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Keep going', style: HrText.caption)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('End',
                  style: HrText.body.copyWith(color: HrColors.dangerText))),
        ],
      ),
    );
    if (ok == true) {
      appState.abandonChallenge();
      if (context.mounted) hrToast(context, 'Challenge ended.');
    }
  }

  void _checkIn(BuildContext context) {
    final c = appState.activeChallenge;
    final completed = appState.checkInChallenge();
    if (completed) {
      celebrate(context);
      _showChallengeComplete(context, c);
    } else {
      hrToast(context,
          'Checked in — ${appState.challengeCheckInCount} day'
          '${appState.challengeCheckInCount == 1 ? '' : 's'} done',
          icon: Icons.check_rounded);
    }
  }

  Widget _premiumBanner(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: HrCard(
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PremiumScreen())),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: HrColors.accentSurface,
                  borderRadius: BorderRadius.circular(HrRadius.md)),
              child: const Icon(Icons.workspace_premium_rounded,
                  color: HrColors.gold, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Challenges are Premium', style: HrText.headline),
                  const SizedBox(height: 2),
                  Text('Unlock to start a guided program',
                      style: HrText.caption),
                ])),
            _lockPill(),
          ]),
        ),
      );

  Widget _activeCard(BuildContext context, ChallengeDef c) {
    final done = appState.challengeCheckInCount;
    final checkedToday = appState.challengeCheckedInToday;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(c.icon, color: HrColors.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
                child: Text(c.title,
                    style: HrText.title2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            _challengeDayTag(c.days),
          ]),
          const SizedBox(height: 4),
          Text(c.focus, style: HrText.bodyS.copyWith(color: HrColors.text2)),
          const SizedBox(height: 14),
          Row(children: [
            Text('$done of ${c.days} days', style: HrText.headline),
            const Spacer(),
            Text('${(appState.challengeProgress * 100).round()}%',
                style: HrText.caption),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(HrRadius.full),
            child: LinearProgressIndicator(
                value: appState.challengeProgress,
                minHeight: 8,
                backgroundColor: HrColors.surface3,
                valueColor: AlwaysStoppedAnimation(HrColors.accent)),
          ),
          const SizedBox(height: 16),
          _challengeMilestones(c.days, done),
          const SizedBox(height: 18),
          if (checkedToday)
            Row(children: [
              Icon(Icons.check_circle_rounded,
                  color: HrColors.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      'Checked in today. Come back tomorrow to keep it going.',
                      style: HrText.bodyS.copyWith(color: HrColors.text2))),
            ])
          else
            HrButton(
                label: 'Check in for today',
                icon: Icons.check_rounded,
                kind: HrButtonKind.accent,
                onPressed: () => _checkIn(context)),
          const SizedBox(height: 6),
          Center(
              child: TextButton(
                  onPressed: () => _abandon(context),
                  child: Text('End challenge', style: HrText.caption))),
        ]),
      ),
    );
  }

  Widget _catalogTile(BuildContext context, ChallengeDef c) {
    final isActive = appState.activeChallengeId == c.id;
    final done = appState.completedChallenges.contains(c.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HrCard(
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: HrColors.surface2,
                borderRadius: BorderRadius.circular(HrRadius.md)),
            child: Icon(c.icon, color: HrColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Flexible(
                      child: Text(c.title,
                          style: HrText.headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 6),
                  _challengeDayTag(c.days),
                ]),
                const SizedBox(height: 2),
                Text(c.blurb,
                    style: HrText.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ])),
          const SizedBox(width: 10),
          if (isActive)
            _stateChip('ACTIVE', HrColors.accent)
          else if (done)
            _stateChip('DONE', HrColors.gold)
          else
            _secondaryPill('Start', () => _start(context, c)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final active = appState.activeChallenge;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Guided challenges'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 8, HrSpace.gutter, 28),
            children: [
              if (!appState.isPremium) _premiumBanner(context),
              if (active != null) _activeCard(context, active),
              const HrLabel('Programs'),
              const SizedBox(height: 10),
              ...kChallenges.map((c) => _catalogTile(context, c)),
            ],
          ),
        );
      },
    );
  }
}

// ── Premium: Streak recovery ────────────────────────────────────────────────
class RecoveryScreen extends StatelessWidget {
  const RecoveryScreen({super.key});

  void _restDay(BuildContext context) {
    if (appState.restDayActiveToday) return;
    final ok = appState.takeRestDay();
    hrToast(
      context,
      ok
          ? 'Rest day set — your streaks are safe today.'
          : 'No streak saves left this month.',
      icon: ok ? Icons.self_improvement_rounded : Icons.info_outline_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final premium = appState.isPremium;
        final left = appState.premiumStreakSavesLeft;
        final resting = appState.restDayActiveToday;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Streak protection'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 8, HrSpace.gutter, 28),
            children: [
              if (!premium)
                HrCard(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PremiumScreen())),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: HrColors.accentSurface,
                          borderRadius: BorderRadius.circular(HrRadius.md)),
                      child: const Icon(Icons.workspace_premium_rounded,
                          color: HrColors.gold, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('Streak protection is Premium',
                              style: HrText.headline),
                          const SizedBox(height: 2),
                          Text('Streak-saves & rest days keep hard-won streaks safe',
                              style: HrText.caption),
                        ])),
                    _lockPill(),
                  ]),
                )
              else ...[
                HrCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.health_and_safety_rounded,
                              color: HrColors.accent, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                              child:
                                  Text('Streak saves', style: HrText.headline)),
                          Text('$left of $kPremiumStreakSavesPerMonth',
                              style: HrText.headline),
                        ]),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(HrRadius.full),
                          child: LinearProgressIndicator(
                              value: left / kPremiumStreakSavesPerMonth,
                              minHeight: 8,
                              backgroundColor: HrColors.surface3,
                              valueColor:
                                  AlwaysStoppedAnimation(HrColors.accent)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                            'A save is spent automatically when a missed day would '
                            'break a streak. Your allowance refreshes at the start '
                            'of each month.',
                            style: HrText.bodyS.copyWith(color: HrColors.text2)),
                      ]),
                ),
                const SizedBox(height: 12),
                HrCard(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.self_improvement_rounded,
                              color: HrColors.accent, size: 18),
                          const SizedBox(width: 8),
                          Text('Plan a rest day', style: HrText.headline),
                        ]),
                        const SizedBox(height: 8),
                        Text(
                            'Mark today as a rest day so a planned break keeps your '
                            'streaks intact. Uses one save.',
                            style: HrText.bodyS.copyWith(color: HrColors.text2)),
                        const SizedBox(height: 12),
                        if (resting)
                          Row(children: [
                            Icon(Icons.check_circle_rounded,
                                color: HrColors.accent, size: 18),
                            const SizedBox(width: 8),
                            Text('Resting today — streaks protected',
                                style: HrText.bodyS
                                    .copyWith(color: HrColors.text2)),
                          ])
                        else
                          HrButton(
                            label: 'Take a rest day today',
                            icon: Icons.self_improvement_rounded,
                            kind: HrButtonKind.secondary,
                            onPressed: left > 0 ? () => _restDay(context) : null,
                          ),
                        if (!resting && left <= 0) ...[
                          const SizedBox(height: 8),
                          Text('No saves left this month.',
                              style: HrText.caption),
                        ],
                      ]),
                ),
                if (appState.streakShields > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                      'You also have ${appState.streakShields} coin streak '
                      'shield${appState.streakShields == 1 ? '' : 's'}, used before '
                      'your monthly saves.',
                      style: HrText.caption),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

// ── Tasks: Dailies & To-Dos ─────────────────────────────────────────────────
String _taskMeta(TaskItem t) {
  if (t.kind == TaskKind.daily) {
    if (t.weekdays.isEmpty) return 'Every day';
    final ds = t.weekdays.toList()..sort();
    return ds.map((d) => _kWeekdays[d - 1].substring(0, 3)).join(', ');
  }
  if (t.dueDate == null) return '';
  final d = DateTime.tryParse(t.dueDate!);
  return d == null ? '' : 'Due ${_kMonths[d.month - 1]} ${d.day}';
}

// One check-off row, shared by the Today card and the management screen.
Widget _taskTile(BuildContext context, TaskItem t, {VoidCallback? onEdit}) {
  final done = appState.taskDoneToday(t);
  final meta = _taskMeta(t);
  return Row(children: [
    Expanded(
      child: InkWell(
        onTap: () => appState.toggleTask(t),
        borderRadius: BorderRadius.circular(HrRadius.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Icon(
                done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: done ? HrColors.accent : HrColors.text3,
                size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.icon.isEmpty ? t.title : '${t.icon}  ${t.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(
                          color: done ? HrColors.text3 : HrColors.text,
                          decoration:
                              done ? TextDecoration.lineThrough : null,
                        )),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(meta, style: HrText.micro),
                    ],
                  ]),
            ),
          ]),
        ),
      ),
    ),
    if (onEdit != null)
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.more_horiz_rounded,
            color: HrColors.text3, size: 20),
        onPressed: onEdit,
      ),
  ]);
}

// Today card: today's due dailies + the next open to-dos.
class _TasksCard extends StatelessWidget {
  const _TasksCard();
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final dailies = appState.dailiesToday;
        final todos = appState.openTodos;
        if (dailies.isEmpty && todos.isEmpty) return const SizedBox.shrink();
        final shownTodos = todos.take(3).toList();
        return Padding(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
          child: HrCard(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('TASKS', style: HrText.labelCaps),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const TasksScreen())),
                      child: Row(children: [
                        Text('${appState.openTasksToday} open',
                            style: HrText.micro),
                        const Icon(Icons.chevron_right_rounded,
                            color: HrColors.text3, size: 16),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  ...dailies.map((t) => _taskTile(context, t)),
                  ...shownTodos.map((t) => _taskTile(context, t)),
                  if (todos.length > shownTodos.length) ...[
                    const SizedBox(height: 4),
                    Text('+${todos.length - shownTodos.length} more to-dos',
                        style: HrText.micro),
                  ],
                ]),
          ),
        );
      },
    );
  }
}

class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  Widget _group(BuildContext context, List<TaskItem> items, String empty) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(empty, style: HrText.caption),
      );
    }
    return HrCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
          children: items
              .map((t) => _taskTile(context, t,
                  onEdit: () => _showTaskEditor(context, existing: t)))
              .toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Tasks'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: 'New task',
                onPressed: () => _showTaskEditor(context),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 8, HrSpace.gutter, 28),
            children: [
              const HrLabel('Dailies'),
              const SizedBox(height: 8),
              _group(context, appState.allDailies,
                  'No dailies yet — add a recurring task.'),
              const SizedBox(height: 18),
              const HrLabel('To-Dos'),
              const SizedBox(height: 8),
              _group(context, appState.allTodos,
                  'No to-dos yet — add a one-off task.'),
              const SizedBox(height: 20),
              HrButton(
                  label: 'Add a task',
                  icon: Icons.add_rounded,
                  kind: HrButtonKind.secondary,
                  onPressed: () => _showTaskEditor(context)),
            ],
          ),
        );
      },
    );
  }
}

InputDecoration _taskField(String label, String hint) => InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: HrText.caption,
      hintStyle: HrText.caption.copyWith(color: HrColors.text3),
      filled: true,
      fillColor: HrColors.surface2,
      counterText: '',
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HrRadius.sm),
          borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );

// Create / edit a task (bottom sheet). Kind is chosen on create, fixed on edit.
void _showTaskEditor(BuildContext context, {TaskItem? existing}) {
  final titleCtrl = TextEditingController(text: existing?.title ?? '');
  final iconCtrl = TextEditingController(text: existing?.icon ?? '');
  var kind = existing?.kind ?? TaskKind.todo;
  final weekdays = <int>{...?existing?.weekdays};
  String? dueDate = existing?.dueDate;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 18,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
      child: StatefulBuilder(builder: (ctx, setSheet) {
        return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? 'New task' : 'Edit task',
                  style: HrText.title2),
              const SizedBox(height: 16),
              if (existing == null) ...[
                HrSegmented(
                    items: const ['To-Do', 'Daily'],
                    index: kind == TaskKind.daily ? 1 : 0,
                    onChanged: (i) => setSheet(
                        () => kind = i == 1 ? TaskKind.daily : TaskKind.todo)),
                const SizedBox(height: 14),
              ],
              TextField(
                  controller: titleCtrl,
                  style: HrText.body,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: _taskField('Title', 'e.g. Take vitamins')),
              const SizedBox(height: 12),
              TextField(
                  controller: iconCtrl,
                  maxLength: 2,
                  style: HrText.body,
                  decoration: _taskField('Emoji (optional)', '💊')),
              const SizedBox(height: 4),
              if (kind == TaskKind.daily) ...[
                Text('Repeat on', style: HrText.caption),
                const SizedBox(height: 8),
                Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(7, (i) {
                      final d = i + 1;
                      final on = weekdays.contains(d);
                      return GestureDetector(
                        onTap: () => setSheet(() =>
                            on ? weekdays.remove(d) : weekdays.add(d)),
                        child: Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on
                                ? HrColors.accentSurface
                                : HrColors.surface2,
                            border: Border.all(
                                color: on
                                    ? HrColors.accent
                                    : HrColors.hairline,
                                width: on ? 2 : 1),
                          ),
                          child: Text(_kWeekdays[i].substring(0, 1),
                              style: HrText.bodyS.copyWith(
                                  color:
                                      on ? HrColors.accent : HrColors.text2,
                                  fontWeight: FontWeight.w700)),
                        ),
                      );
                    })),
                const SizedBox(height: 6),
                Text(weekdays.isEmpty ? 'Empty = every day' : '',
                    style: HrText.micro),
              ] else ...[
                Row(children: [
                  Text(
                      dueDate == null
                          ? 'No due date'
                          : 'Due ${_fmtDue(dueDate!)}',
                      style: HrText.bodyS.copyWith(color: HrColors.text2)),
                  const Spacer(),
                  TextButton(
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: dueDate != null
                              ? (DateTime.tryParse(dueDate!) ?? now)
                              : now,
                          firstDate:
                              now.subtract(const Duration(days: 1)),
                          lastDate: DateTime(now.year + 5),
                        );
                        if (picked != null) {
                          setSheet(() => dueDate = dateKey(picked));
                        }
                      },
                      child: Text(dueDate == null ? 'Set date' : 'Change',
                          style: HrText.caption)),
                  if (dueDate != null)
                    TextButton(
                        onPressed: () => setSheet(() => dueDate = null),
                        child: Text('Clear', style: HrText.caption)),
                ]),
              ],
              const SizedBox(height: 16),
              HrButton(
                label: existing == null ? 'Add task' : 'Save',
                icon: Icons.check_rounded,
                onPressed: () {
                  if (titleCtrl.text.trim().isEmpty) return;
                  if (existing == null) {
                    appState.addTask(titleCtrl.text, kind,
                        icon: iconCtrl.text,
                        weekdays: weekdays.toList(),
                        dueDate: kind == TaskKind.todo ? dueDate : null);
                  } else {
                    appState.updateTask(existing,
                        title: titleCtrl.text,
                        icon: iconCtrl.text,
                        weekdays: existing.kind == TaskKind.daily
                            ? weekdays.toList()
                            : null,
                        dueDate: existing.kind == TaskKind.todo
                            ? (dueDate ?? '')
                            : null);
                  }
                  Navigator.pop(ctx);
                },
              ),
              if (existing != null) ...[
                const SizedBox(height: 6),
                Center(
                  child: TextButton(
                    onPressed: () {
                      appState.deleteTask(existing);
                      Navigator.pop(ctx);
                    },
                    child: Text('Delete task',
                        style: HrText.caption
                            .copyWith(color: HrColors.dangerText)),
                  ),
                ),
              ],
            ]);
      }),
    ),
  ).whenComplete(() {
    titleCtrl.dispose();
    iconCtrl.dispose();
  });
}

String _fmtDue(String key) {
  final d = DateTime.tryParse(key);
  return d == null ? key : '${_kMonths[d.month - 1]} ${d.day}';
}

// ── Parties (co-op) ──────────────────────────────────────────────────────────
String _partyWeekKey() {
  final now = DateTime.now();
  final mon = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1));
  return dateKey(mon);
}

class PartyScreen extends StatefulWidget {
  const PartyScreen({super.key});
  @override
  State<PartyScreen> createState() => _PartyScreenState();
}

class _PartyScreenState extends State<PartyScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  Map<String, dynamic>? _party;
  List<Map<String, dynamic>> _members = const [];
  bool _loading = true;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    // Near-real-time member progress: quietly refresh the roster while open.
    _tick = Timer.periodic(
        const Duration(seconds: 12), (_) => _refreshMembers());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final p = await myParty();
    final m = p == null
        ? const <Map<String, dynamic>>[]
        : await partyMembers(p['id'].toString());
    if (!mounted) return;
    setState(() {
      _party = p;
      _members = m;
      _loading = false;
    });
  }

  // Quiet roster + stats refresh (no spinner), driven by the periodic tick.
  Future<void> _refreshMembers() async {
    final p = _party;
    if (p == null) return;
    final m = await partyMembers(p['id'].toString());
    if (!mounted) return;
    setState(() => _members = m);
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() => _busy = true);
    final p = await createParty(_nameCtrl.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (p == null) {
      hrToast(context, "Couldn't create the party — try again.",
          icon: Icons.error_outline_rounded);
    } else {
      _nameCtrl.clear();
      await _load();
    }
  }

  Future<void> _join() async {
    if (_busy) return;
    if (_codeCtrl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final p = await joinParty(_codeCtrl.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (p == null) {
      hrToast(context, 'No party found for that code.',
          icon: Icons.info_outline_rounded);
    } else {
      _codeCtrl.clear();
      await _load();
    }
  }

  Future<void> _leave() async {
    final p = _party;
    if (p == null) return;
    final owner = p['owner_id'] == currentUserId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text(owner ? 'Disband party?' : 'Leave party?',
            style: HrText.title2),
        content: Text(
            owner
                ? 'You own this party — leaving disbands it for everyone.'
                : 'You can rejoin later with the invite code.',
            style: HrText.bodyS),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: HrText.caption)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(owner ? 'Disband' : 'Leave',
                  style: HrText.body.copyWith(color: HrColors.dangerText))),
        ],
      ),
    );
    if (ok != true) return;
    await leaveParty(p['id'].toString());
    await _load();
  }

  Future<void> _pickQuest() async {
    final p = _party;
    if (p == null) return;
    final chosen = await showModalBottomSheet<CoopQuestDef>(
      context: context,
      backgroundColor: HrColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 14),
          Text('Choose a co-op quest', style: HrText.title2),
          const SizedBox(height: 4),
          Text('The party fights the boss together with combined XP.',
              style: HrText.caption, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          ...kCoopQuests.map((q) => ListTile(
                leading: Text(q.emoji, style: const TextStyle(fontSize: 26)),
                title: Text(q.name, style: HrText.body),
                subtitle: Text('${q.target} XP · +${q.reward} coins each',
                    style: HrText.caption),
                onTap: () => Navigator.pop(ctx, q),
              )),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (chosen == null) return;
    final updated = await setPartyQuest(
        p['id'].toString(), chosen.id, chosen.target, _partyWeekKey());
    if (updated != null) await _load();
  }

  Future<void> _claimQuest(String key, int reward) async {
    appState.claimCoopQuest(key, reward);
    if (mounted) {
      hrToast(context, 'Reward claimed · +$reward coins',
          icon: Icons.emoji_events_rounded);
    }
  }

  int _memberGain(Map<String, dynamic> m) {
    final cur = (m['total_xp'] as num?)?.toInt() ?? 0;
    final base = (m['xp_baseline'] as num?)?.toInt() ?? 0;
    return (cur - base).clamp(0, 1 << 30);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: const HrAppBarTitle('Party'),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (!backendEnabled || currentUserId == null) {
      return _centered(Icons.groups_rounded, 'Parties need an account',
          'Sign in or create an account (You → Account) to start a party and invite friends to a shared weekly goal.');
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_party == null) return _noParty(context);
    return _partyView(context);
  }

  Widget _centered(IconData icon, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: HrColors.text3),
            const SizedBox(height: 14),
            Text(title, style: HrText.title2, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body,
                style: HrText.bodyS.copyWith(color: HrColors.text2),
                textAlign: TextAlign.center),
          ]),
        ),
      );

  Widget _noParty(BuildContext context) => ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 8, HrSpace.gutter, 28),
        children: [
          HrCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const HrLabel('Start a party'),
                const SizedBox(height: 10),
                TextField(
                    controller: _nameCtrl,
                    style: HrText.body,
                    textCapitalization: TextCapitalization.words,
                    decoration: _taskField('Party name', 'e.g. Morning Crew')),
                const SizedBox(height: 12),
                HrButton(
                    label: 'Create party',
                    icon: Icons.add_rounded,
                    loading: _busy,
                    onPressed: _busy ? null : _create),
              ])),
          const SizedBox(height: 14),
          HrCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const HrLabel('Join with a code'),
                const SizedBox(height: 10),
                TextField(
                    controller: _codeCtrl,
                    style: HrText.body,
                    textCapitalization: TextCapitalization.characters,
                    decoration: _taskField('Invite code', 'e.g. 4F9A2C')),
                const SizedBox(height: 12),
                HrButton(
                    label: 'Join party',
                    icon: Icons.login_rounded,
                    kind: HrButtonKind.secondary,
                    loading: _busy,
                    onPressed: _busy ? null : _join),
              ])),
        ],
      );

  Widget _partyView(BuildContext context) {
    final p = _party!;
    final owner = p['owner_id'] == currentUserId;
    final code = (p['invite_code'] ?? '').toString();
    final gained = _members.fold<int>(0, (a, m) => a + _memberGain(m));
    final questId = (p['quest_id'] ?? '').toString();
    final quest = coopQuestById(questId);
    final week = (p['goal_week'] ?? '').toString();
    final claimKey = 'quest:${p['id']}:$week:$questId';
    final claimed = appState.claimedQuests.contains(claimKey);
    final defeated = quest != null && gained >= quest.target;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 8, HrSpace.gutter, 28),
        children: [
          HrCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Icon(Icons.groups_rounded, color: HrColors.accent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text((p['name'] ?? 'Party').toString(),
                          style: HrText.title2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  Text(
                      '${_members.length} member${_members.length == 1 ? '' : 's'}',
                      style: HrText.caption),
                ]),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    hrToast(context, 'Invite code copied',
                        icon: Icons.copy_rounded);
                  },
                  borderRadius: BorderRadius.circular(HrRadius.sm),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                        color: HrColors.surface2,
                        borderRadius: BorderRadius.circular(HrRadius.sm)),
                    child: Row(children: [
                      Text('Invite code', style: HrText.caption),
                      const Spacer(),
                      Text(code,
                          style: HrText.headline.copyWith(letterSpacing: 2)),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy_rounded,
                          size: 16, color: HrColors.text3),
                    ]),
                  ),
                ),
              ])),
          const SizedBox(height: 10),
          HrButton(
            label: 'Party chat',
            icon: Icons.chat_bubble_outline_rounded,
            kind: HrButtonKind.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PartyChatScreen(
                    partyId: p['id'].toString(),
                    title: (p['name'] ?? 'Party').toString()))),
          ),
          const SizedBox(height: 14),
          HrCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Text(quest?.emoji ?? '⚔️',
                      style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(quest?.name ?? 'Co-op quest',
                          style: HrText.headline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  if (owner)
                    _secondaryPill(
                        quest == null ? 'Start' : 'Change', _pickQuest),
                ]),
                const SizedBox(height: 10),
                if (quest != null) ...[
                  Row(children: [
                    Text('$gained / ${quest.target} XP dealt',
                        style: HrText.bodyS.copyWith(color: HrColors.text2)),
                    const Spacer(),
                    Text(
                        '${((gained / quest.target).clamp(0.0, 1.0) * 100).round()}%',
                        style: HrText.caption),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(HrRadius.full),
                    child: LinearProgressIndicator(
                        value: (gained / quest.target).clamp(0.0, 1.0),
                        minHeight: 8,
                        backgroundColor: HrColors.surface3,
                        valueColor: AlwaysStoppedAnimation(
                            defeated ? HrColors.gold : HrColors.accent)),
                  ),
                  const SizedBox(height: 10),
                  if (defeated)
                    claimed
                        ? Row(children: [
                            const Icon(Icons.verified_rounded,
                                color: HrColors.gold, size: 16),
                            const SizedBox(width: 6),
                            Text('Boss defeated — reward claimed',
                                style: HrText.caption
                                    .copyWith(color: HrColors.gold)),
                          ])
                        : HrButton(
                            label: 'Boss down! Claim +${quest.reward} coins',
                            icon: Icons.emoji_events_rounded,
                            kind: HrButtonKind.accent,
                            onPressed: () => _claimQuest(claimKey, quest.reward),
                          )
                  else
                    Text(
                        'Earn XP together to defeat it · +${quest.reward} coins each',
                        style: HrText.caption),
                ] else
                  Text(
                      owner
                          ? 'Start a co-op quest — the party fights a boss together.'
                          : "The owner hasn't started a quest yet.",
                      style: HrText.bodyS.copyWith(color: HrColors.text2)),
              ])),
          const SizedBox(height: 14),
          const HrLabel('Members'),
          const SizedBox(height: 8),
          HrCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(children: _members.map(_memberRow).toList())),
          const SizedBox(height: 18),
          Center(
              child: TextButton(
                  onPressed: _leave,
                  child: Text(owner ? 'Disband party' : 'Leave party',
                      style:
                          HrText.caption.copyWith(color: HrColors.dangerText)))),
        ],
      ),
    );
  }

  Widget _memberRow(Map<String, dynamic> m) {
    final name = (m['name'] ?? m['username'] ?? 'Player').toString();
    final xp = (m['total_xp'] as num?)?.toInt() ?? 0;
    final streak = (m['streak'] as num?)?.toInt() ?? 0;
    final ld = levelFromXp(xp);
    final gain = _memberGain(m);
    final isMe = m['id'] == currentUserId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(children: [
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(fontWeight: FontWeight.w700))),
                if (isMe) ...[
                  const SizedBox(width: 6),
                  Text('you',
                      style: HrText.micro.copyWith(color: HrColors.accent)),
                ],
              ]),
              const SizedBox(height: 2),
              Text('Lv ${ld.level} · +$gain XP this week',
                  style: HrText.caption),
            ])),
        if (streak > 0) StreakPill(count: streak, quiet: true),
      ]),
    );
  }
}

// Live party chat. History loads via RLS-protected select; new messages stream
// in over Supabase realtime. Degrades to an empty state when the backend/chat
// schema isn't there.
class PartyChatScreen extends StatefulWidget {
  const PartyChatScreen({required this.partyId, required this.title, super.key});
  final String partyId;
  final String title;
  @override
  State<PartyChatScreen> createState() => _PartyChatScreenState();
}

class _PartyChatScreenState extends State<PartyChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = const [];
  Future<void> Function()? _unsub;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final m = await partyMessages(widget.partyId);
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _loading = false;
    });
    _toBottom();
    _unsub = subscribePartyMessages(widget.partyId, (row) {
      if (!mounted) return;
      final id = row['id']?.toString();
      if (id != null && _msgs.any((x) => x['id']?.toString() == id)) return;
      setState(() => _msgs = [..._msgs, row]);
      _toBottom();
    });
  }

  @override
  void dispose() {
    _unsub?.call();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _ctrl.clear();
    await sendPartyMessage(widget.partyId, text);
    final m = await partyMessages(widget.partyId);
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _sending = false;
    });
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: HrAppBarTitle(widget.title),
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('No messages yet — say hi to your party.',
                            style: HrText.bodyS.copyWith(color: HrColors.text3),
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(
                          HrSpace.gutter, 12, HrSpace.gutter, 12),
                      itemCount: _msgs.length,
                      itemBuilder: (c, i) => _bubble(_msgs[i]),
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: HrText.body,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration:
                      _taskField('Message', 'Say something to your party'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sending ? null : _send,
                icon: Icon(Icons.send_rounded, color: HrColors.accent),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    if (appState.isBlocked(m['user_id']?.toString() ?? '')) {
      return const SizedBox.shrink();
    }
    final mine = m['user_id'] == currentUserId;
    final author = (m['author_name'] ?? 'Player').toString();
    final body = maskProfanity((m['body'] ?? '').toString());
    return GestureDetector(
      onLongPress: () => _moderateMessage(context, m, 'party', () {
        if (mounted) setState(() {});
      }),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
              bottom: 8, left: mine ? 48 : 0, right: mine ? 0 : 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: mine ? HrColors.accentSurface : HrColors.surface2,
              borderRadius: BorderRadius.circular(HrRadius.md)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!mine) ...[
              Text(author, style: HrText.micro.copyWith(color: HrColors.text3)),
              const SizedBox(height: 2),
            ],
            Text(body,
                style: HrText.bodyS
                    .copyWith(color: mine ? HrColors.text : HrColors.text2)),
          ]),
        ),
      ),
    );
  }
}

// ── Guilds (public groups) ───────────────────────────────────────────────────
class GuildsScreen extends StatefulWidget {
  const GuildsScreen({super.key});
  @override
  State<GuildsScreen> createState() => _GuildsScreenState();
}

class _GuildsScreenState extends State<GuildsScreen> {
  int _seg = 0;
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _discover = const [];
  List<Map<String, dynamic>> _mine = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final d = await discoverGuilds(_searchCtrl.text);
    final m = await myGuilds();
    if (!mounted) return;
    setState(() {
      _discover = d;
      _mine = m;
      _loading = false;
    });
  }

  Future<void> _join(Map<String, dynamic> g) async {
    await joinGuild(g['id'].toString());
    await _load();
  }

  void _create() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HrColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 18,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('New guild', style: HrText.title2),
              const SizedBox(height: 16),
              TextField(
                  controller: nameCtrl,
                  style: HrText.body,
                  textCapitalization: TextCapitalization.words,
                  decoration: _taskField('Guild name', 'e.g. Early Risers')),
              const SizedBox(height: 12),
              TextField(
                  controller: descCtrl,
                  style: HrText.body,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: _taskField(
                      'Description (optional)', "What's this guild about?")),
              const SizedBox(height: 16),
              HrButton(
                label: 'Create guild',
                icon: Icons.add_rounded,
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty) return;
                  final g = await createGuild(nameCtrl.text, descCtrl.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _load();
                  if (g != null && mounted) {
                    setState(() => _seg = 1); // jump to My guilds
                  }
                },
              ),
            ]),
      ),
    ).whenComplete(() {
      nameCtrl.dispose();
      descCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = backendEnabled && currentUserId != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: const HrAppBarTitle('Guilds'),
        actions: signedIn
            ? [
                IconButton(
                    icon: const Icon(Icons.add_rounded),
                    tooltip: 'New guild',
                    onPressed: _create),
              ]
            : null,
      ),
      body: !signedIn
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.shield_rounded,
                      size: 40, color: HrColors.text3),
                  const SizedBox(height: 14),
                  Text('Guilds need an account',
                      style: HrText.title2, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                      'Sign in (You → Account) to discover and join public guilds.',
                      style: HrText.bodyS.copyWith(color: HrColors.text2),
                      textAlign: TextAlign.center),
                ]),
              ),
            )
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    HrSpace.gutter, 8, HrSpace.gutter, 10),
                child: HrSegmented(
                    items: const ['Discover', 'My guilds'],
                    index: _seg,
                    onChanged: (i) => setState(() => _seg = i)),
              ),
              Expanded(
                  child: _loading
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : _seg == 0
                          ? _discoverTab()
                          : _mineTab()),
            ]),
    );
  }

  Widget _discoverTab() => ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 28),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                style: HrText.body,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _load(),
                decoration: _taskField('Search guilds', 'by name'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.search_rounded, color: HrColors.text)),
          ]),
          const SizedBox(height: 12),
          if (_discover.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Text('No guilds yet — create the first one.',
                  style: HrText.caption),
            )
          else
            ..._discover.map((g) => _guildCard(g, showJoin: true)),
        ],
      );

  Widget _mineTab() => _mine.isEmpty
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
                'You haven\'t joined any guilds yet.\nFind one in Discover.',
                style: HrText.bodyS.copyWith(color: HrColors.text3),
                textAlign: TextAlign.center),
          ),
        )
      : ListView(
          padding:
              const EdgeInsets.fromLTRB(HrSpace.gutter, 4, HrSpace.gutter, 28),
          children: _mine.map((g) => _guildCard(g, showJoin: false)).toList(),
        );

  Widget _guildCard(Map<String, dynamic> g, {required bool showJoin}) {
    final isMember = g['is_member'] == true;
    final count = (g['member_count'] as num?)?.toInt() ?? 0;
    final desc = (g['description'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HrCard(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => GuildDetailScreen(
                  guildId: g['id'].toString(),
                  name: (g['name'] ?? 'Guild').toString(),
                  description: desc,
                  ownerId: (g['owner_id'] ?? '').toString(),
                  goalTarget: (g['goal_target'] as num?)?.toInt() ?? 0,
                  goalWeek: (g['goal_week'] ?? '').toString())));
          await _load();
        },
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: HrColors.accentSurface,
                borderRadius: BorderRadius.circular(HrRadius.md)),
            child: Icon(Icons.shield_rounded, color: HrColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text((g['name'] ?? 'Guild').toString(),
                    style: HrText.headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(desc,
                      style: HrText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 2),
                Text('$count member${count == 1 ? '' : 's'}',
                    style: HrText.micro),
              ])),
          const SizedBox(width: 10),
          if (showJoin && !isMember)
            _secondaryPill('Join', () => _join(g))
          else if (isMember)
            _stateChip('JOINED', HrColors.accent)
          else
            const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
        ]),
      ),
    );
  }
}

class GuildDetailScreen extends StatefulWidget {
  const GuildDetailScreen(
      {required this.guildId,
      required this.name,
      required this.description,
      this.ownerId = '',
      this.goalTarget = 0,
      this.goalWeek = '',
      super.key});
  final String guildId;
  final String name;
  final String description;
  final String ownerId;
  final int goalTarget;
  final String goalWeek;
  @override
  State<GuildDetailScreen> createState() => _GuildDetailScreenState();
}

class _GuildDetailScreenState extends State<GuildDetailScreen> {
  List<Map<String, dynamic>> _members = const [];
  bool _loading = true;
  late int _goalTarget;

  bool get _isOwner =>
      widget.ownerId.isNotEmpty && widget.ownerId == currentUserId;

  @override
  void initState() {
    super.initState();
    _goalTarget = widget.goalTarget;
    _load();
  }

  Future<void> _load() async {
    final m = await guildMembers(widget.guildId);
    if (!mounted) return;
    setState(() {
      _members = m;
      _loading = false;
    });
  }

  int _memberGain(Map<String, dynamic> m) {
    final cur = (m['total_xp'] as num?)?.toInt() ?? 0;
    final base = (m['xp_baseline'] as num?)?.toInt() ?? 0;
    return (cur - base).clamp(0, 1 << 30);
  }

  Future<void> _setGoal() async {
    final ctrl = TextEditingController(text: _goalTarget.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text('Weekly guild goal', style: HrText.title2),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Combined XP the guild aims to earn this week.',
                  style: HrText.bodyS),
              const SizedBox(height: 12),
              TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  style: HrText.body,
                  decoration: _taskField('Target XP', 'e.g. 5000')),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: HrText.caption)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Save',
                  style: HrText.body.copyWith(color: HrColors.accent))),
        ],
      ),
    );
    final target = int.tryParse(ctrl.text.trim()) ?? 0;
    ctrl.dispose();
    if (ok != true) return;
    final updated = await setGuildGoal(widget.guildId, target, _partyWeekKey());
    if (updated != null && mounted) {
      setState(() =>
          _goalTarget = (updated['goal_target'] as num?)?.toInt() ?? target);
      await _load();
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text('Leave guild?', style: HrText.title2),
        content: Text('You can rejoin from Discover anytime.',
            style: HrText.bodyS),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: HrText.caption)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Leave',
                  style: HrText.body.copyWith(color: HrColors.dangerText))),
        ],
      ),
    );
    if (ok != true) return;
    await leaveGuild(widget.guildId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final gained = _members.fold<int>(0, (a, m) => a + _memberGain(m));
    final pct = _goalTarget > 0 ? (gained / _goalTarget).clamp(0.0, 1.0) : 0.0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: HrAppBarTitle(widget.name),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  HrSpace.gutter, 8, HrSpace.gutter, 28),
              children: [
                if (widget.description.isNotEmpty) ...[
                  HrCard(
                      child: Text(widget.description,
                          style: HrText.bodyS.copyWith(color: HrColors.text2))),
                  const SizedBox(height: 14),
                ],
                HrButton(
                  label: 'Guild chat',
                  icon: Icons.chat_bubble_outline_rounded,
                  kind: HrButtonKind.secondary,
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => GuildChatScreen(
                              guildId: widget.guildId, title: widget.name))),
                ),
                const SizedBox(height: 14),
                HrCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        Icon(Icons.flag_rounded,
                            color: HrColors.accent, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text('Weekly guild goal',
                                style: HrText.headline)),
                        if (_isOwner)
                          _secondaryPill(
                              _goalTarget > 0 ? 'Edit' : 'Set', _setGoal),
                      ]),
                      const SizedBox(height: 10),
                      if (_goalTarget > 0) ...[
                        Row(children: [
                          Text('$gained of $_goalTarget XP',
                              style: HrText.bodyS
                                  .copyWith(color: HrColors.text2)),
                          const Spacer(),
                          Text('${(pct * 100).round()}%',
                              style: HrText.caption),
                        ]),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(HrRadius.full),
                          child: LinearProgressIndicator(
                              value: pct,
                              minHeight: 8,
                              backgroundColor: HrColors.surface3,
                              valueColor:
                                  AlwaysStoppedAnimation(HrColors.accent)),
                        ),
                      ] else
                        Text(
                            _isOwner
                                ? 'Set a combined weekly XP target for the guild.'
                                : "The owner hasn't set a goal yet.",
                            style: HrText.bodyS
                                .copyWith(color: HrColors.text2)),
                    ])),
                const SizedBox(height: 14),
                HrLabel('Members (${_members.length})'),
                const SizedBox(height: 8),
                HrCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(children: _members.map(_row).toList()),
                ),
                const SizedBox(height: 18),
                Center(
                    child: TextButton(
                        onPressed: _leave,
                        child: Text('Leave guild',
                            style: HrText.caption
                                .copyWith(color: HrColors.dangerText)))),
              ],
            ),
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final name = (m['name'] ?? m['username'] ?? 'Player').toString();
    final xp = (m['total_xp'] as num?)?.toInt() ?? 0;
    final streak = (m['streak'] as num?)?.toInt() ?? 0;
    final ld = levelFromXp(xp);
    final isMe = m['id'] == currentUserId;
    final sub = _goalTarget > 0
        ? 'Lv ${ld.level} · +${_memberGain(m)} XP this week'
        : 'Lv ${ld.level} · ${levelTitle(ld.level)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(children: [
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            HrText.body.copyWith(fontWeight: FontWeight.w700))),
                if (isMe) ...[
                  const SizedBox(width: 6),
                  Text('you',
                      style: HrText.micro.copyWith(color: HrColors.accent)),
                ],
              ]),
              const SizedBox(height: 2),
              Text(sub, style: HrText.caption),
            ])),
        if (streak > 0) StreakPill(count: streak, quiet: true),
      ]),
    );
  }
}

// Live guild chat — mirrors party chat (RLS-protected history + realtime),
// degrading to an empty state when the backend/chat schema isn't deployed.
class GuildChatScreen extends StatefulWidget {
  const GuildChatScreen({required this.guildId, required this.title, super.key});
  final String guildId;
  final String title;
  @override
  State<GuildChatScreen> createState() => _GuildChatScreenState();
}

class _GuildChatScreenState extends State<GuildChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = const [];
  Future<void> Function()? _unsub;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final m = await guildMessages(widget.guildId);
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _loading = false;
    });
    _toBottom();
    _unsub = subscribeGuildMessages(widget.guildId, (row) {
      if (!mounted) return;
      final id = row['id']?.toString();
      if (id != null && _msgs.any((x) => x['id']?.toString() == id)) return;
      setState(() => _msgs = [..._msgs, row]);
      _toBottom();
    });
  }

  @override
  void dispose() {
    _unsub?.call();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _ctrl.clear();
    await sendGuildMessage(widget.guildId, text);
    final m = await guildMessages(widget.guildId);
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _sending = false;
    });
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: HrAppBarTitle(widget.title),
      ),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('No messages yet — say hi to your guild.',
                            style: HrText.bodyS.copyWith(color: HrColors.text3),
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(
                          HrSpace.gutter, 12, HrSpace.gutter, 12),
                      itemCount: _msgs.length,
                      itemBuilder: (c, i) => _bubble(_msgs[i]),
                    ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: HrText.body,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration:
                      _taskField('Message', 'Say something to your guild'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sending ? null : _send,
                icon: Icon(Icons.send_rounded, color: HrColors.accent),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    if (appState.isBlocked(m['user_id']?.toString() ?? '')) {
      return const SizedBox.shrink();
    }
    final mine = m['user_id'] == currentUserId;
    final author = (m['author_name'] ?? 'Player').toString();
    final body = maskProfanity((m['body'] ?? '').toString());
    return GestureDetector(
      onLongPress: () => _moderateMessage(context, m, 'guild', () {
        if (mounted) setState(() {});
      }),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
              bottom: 8, left: mine ? 48 : 0, right: mine ? 0 : 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: mine ? HrColors.accentSurface : HrColors.surface2,
              borderRadius: BorderRadius.circular(HrRadius.md)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!mine) ...[
              Text(author, style: HrText.micro.copyWith(color: HrColors.text3)),
              const SizedBox(height: 2),
            ],
            Text(body,
                style: HrText.bodyS
                    .copyWith(color: mine ? HrColors.text : HrColors.text2)),
          ]),
        ),
      ),
    );
  }
}

// ── Global chat (one shared room, no joining) ────────────────────────────────
class GlobalChatScreen extends StatefulWidget {
  const GlobalChatScreen({super.key});
  @override
  State<GlobalChatScreen> createState() => _GlobalChatScreenState();
}

class _GlobalChatScreenState extends State<GlobalChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = const [];
  Future<void> Function()? _unsub;
  bool _loading = true;
  bool _sending = false;

  bool get _signedIn => backendEnabled && currentUserId != null;

  @override
  void initState() {
    super.initState();
    if (_signedIn) {
      _init();
    } else {
      _loading = false;
    }
  }

  Future<void> _init() async {
    final m = await globalMessages();
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _loading = false;
    });
    _toBottom();
    _unsub = subscribeGlobalMessages((row) {
      if (!mounted) return;
      final id = row['id']?.toString();
      if (id != null && _msgs.any((x) => x['id']?.toString() == id)) return;
      setState(() => _msgs = [..._msgs, row]);
      _toBottom();
    });
  }

  @override
  void dispose() {
    _unsub?.call();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _ctrl.clear();
    await sendGlobalMessage(text);
    final m = await globalMessages();
    if (!mounted) return;
    setState(() {
      _msgs = m;
      _sending = false;
    });
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: const HrAppBarTitle('Global chat'),
      ),
      body: !_signedIn
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.forum_rounded,
                      size: 40, color: HrColors.text3),
                  const SizedBox(height: 14),
                  Text('Sign in to join the global chat',
                      style: HrText.title2, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text('Everyone with an account can talk here — no joining.',
                      style: HrText.bodyS.copyWith(color: HrColors.text2),
                      textAlign: TextAlign.center),
                ]),
              ),
            )
          : Column(children: [
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _msgs.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                  'No messages yet — say hi to everyone.',
                                  style: HrText.bodyS
                                      .copyWith(color: HrColors.text3),
                                  textAlign: TextAlign.center),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(
                                HrSpace.gutter, 12, HrSpace.gutter, 12),
                            itemCount: _msgs.length,
                            itemBuilder: (c, i) => _bubble(_msgs[i]),
                          ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        style: HrText.body,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration:
                            _taskField('Message', 'Say something to everyone'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _sending ? null : _send,
                      icon: Icon(Icons.send_rounded, color: HrColors.accent),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    if (appState.isBlocked(m['user_id']?.toString() ?? '')) {
      return const SizedBox.shrink();
    }
    final mine = m['user_id'] == currentUserId;
    final author = (m['author_name'] ?? 'Player').toString();
    final body = maskProfanity((m['body'] ?? '').toString());
    return GestureDetector(
      onLongPress: () => _moderateMessage(context, m, 'global', () {
        if (mounted) setState(() {});
      }),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(
              bottom: 8, left: mine ? 48 : 0, right: mine ? 0 : 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: mine ? HrColors.accentSurface : HrColors.surface2,
              borderRadius: BorderRadius.circular(HrRadius.md)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!mine) ...[
              Text(author, style: HrText.micro.copyWith(color: HrColors.text3)),
              const SizedBox(height: 2),
            ],
            Text(body,
                style: HrText.bodyS
                    .copyWith(color: mine ? HrColors.text : HrColors.text2)),
          ]),
        ),
      ),
    );
  }
}

// Report/block sheet for a chat message (App Store Guideline 1.2 — user-
// generated content needs a way to report content and block users).
// scope is 'party' | 'guild' | 'global'.
Future<void> _moderateMessage(BuildContext context, Map<String, dynamic> m,
    String scope, VoidCallback onBlocked) async {
  final authorId = m['user_id']?.toString() ?? '';
  if (authorId.isEmpty || authorId == currentUserId) return;
  final author = (m['author_name'] ?? 'this user').toString();
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 10),
        Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
              color: HrColors.surface3,
              borderRadius: BorderRadius.circular(2)),
        ),
        ListTile(
          leading: const Icon(Icons.flag_outlined, color: HrColors.dangerText),
          title: Text('Report message', style: HrText.body),
          subtitle: Text('Flag this message for review', style: HrText.caption),
          onTap: () => Navigator.pop(ctx, 'report'),
        ),
        ListTile(
          leading: const Icon(Icons.block_rounded, color: HrColors.dangerText),
          title: Text('Block $author', style: HrText.body),
          subtitle:
              Text('Hide all messages from this user', style: HrText.caption),
          onTap: () => Navigator.pop(ctx, 'block'),
        ),
        const SizedBox(height: 10),
      ]),
    ),
  );
  if (action == 'report') {
    await reportMessage(scope, m['id']?.toString() ?? '', authorId);
    if (context.mounted) {
      hrToast(context, 'Reported — thanks for flagging.',
          icon: Icons.flag_outlined);
    }
  } else if (action == 'block') {
    appState.blockUser(authorId);
    onBlocked();
    if (context.mounted) {
      hrToast(context, 'Blocked $author', icon: Icons.block_rounded);
    }
  }
}

// ── MOMENTS: shared celebration dialog ──────────────────────────────────────
void _showMoment(
  BuildContext context, {
  required String label,
  Color labelColor = HrColors.gold,
  required Widget emblem,
  required String title,
  String? subtitle,
  String? bubble,
  List<Widget> rewards = const [],
  String buttonLabel = 'Continue',
}) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          color: HrColors.surface,
          borderRadius: BorderRadius.circular(HrRadius.xl),
          border: const Border(top: BorderSide(color: HrColors.hairline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.toUpperCase(),
              style: HrText.labelCaps.copyWith(
                color: labelColor,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 16),
            emblem,
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: HrText.title1),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle, textAlign: TextAlign.center, style: HrText.bodyS),
            ],
            if (bubble != null) ...[
              const SizedBox(height: 14),
              SpeechBubble(bubble, maxWidth: 240),
            ],
            if (rewards.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: rewards,
              ),
            ],
            const SizedBox(height: 22),
            HrButton(label: buttonLabel, onPressed: () => Navigator.pop(ctx)),
          ],
        ),
      ),
    ),
  );
}

Widget _momentReward(String value, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  margin: const EdgeInsets.symmetric(horizontal: 5),
  decoration: BoxDecoration(
    color: HrColors.surface2,
    borderRadius: BorderRadius.circular(HrRadius.md),
  ),
  child: Column(
    children: [
      Text(value, style: HrText.title2.copyWith(color: color)),
      const SizedBox(height: 2),
      Text(label, style: HrText.micro),
    ],
  ),
);

void _showBossDefeat(BuildContext context) {
  _showMoment(
    context,
    label: 'Boss defeated',
    labelColor: HrColors.gold,
    emblem: SegmentedRing(
      size: 136,
      segments: 1,
      value: 1,
      stroke: 9,
      color: HrColors.gold,
      center: Image.asset(
        kBossImageAsset,
        width: 76,
        height: 76,
        fit: BoxFit.contain,
        semanticLabel: 'Weekly boss',
      ),
    ),
    title: 'Weekly Sovereignty\nChallenge',
    bubble: companionLine(appState.activeCompanion, 'boss_defeat'),
    rewards: [
      _momentReward('+$kBossXp', 'XP', HrColors.gold),
      _momentReward('+$kBossCoins', 'Coins', HrColors.text),
    ],
    buttonLabel: 'Claim',
  );
}

// _HabitTile was replaced by HabitRow (design-system kit) in the _FiveCard.

// ── FOCUS ───────────────────────────────────────────────────────────────────
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});
  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  // Preset session lengths (Custom picks anything else).
  static const _presets = <(String, String, IconData, int)>[
    ('Pomodoro', '25 min', Icons.timer_outlined, 25),
    ('Short', '5 min', Icons.eco_rounded, 5),
    ('Long', '50 min', Icons.hourglass_bottom_rounded, 50),
  ];
  static const _customChoices = [10, 15, 20, 30, 45, 60, 90, 120];
  static const _modes = <(String, String)>[
    ('Deep Work', '🌿'),
    ('Study', '📚'),
    ('Reading', '📖'),
    ('Creative', '🎨'),
    ('Workout', '💪'),
    ('Mindful', '🧘'),
  ];
  int _minutes = 25;
  bool _custom = false;
  int _mode = 0;
  int _remaining = 25 * 60;
  bool _running = false;
  bool _started = false;
  bool _complete = false;
  int _lastGain = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setMinutes(int m, {bool custom = false}) {
    if (_started) return;
    setState(() {
      _minutes = m;
      _custom = custom;
      _remaining = m * 60;
    });
  }

  void _start() {
    setState(() {
      _running = true;
      _started = true;
      _complete = false;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        final gain = appState.completeFocus(_minutes);
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        setState(() {
          _running = false;
          _started = false;
          _remaining = _minutes * 60;
          _complete = true;
          _lastGain = gain;
        });
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

  void _backToToday() {
    setState(() {
      _complete = false;
      _remaining = _minutes * 60;
    });
    shellTab.value = 0; // jump the bottom-nav back to Today
  }

  Future<void> _pickMode() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Focus mode', style: HrText.title2),
              const SizedBox(height: 4),
              Text('Name what this session is for.', style: HrText.bodyS),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < _modes.length; i++)
                    HrPressable(
                      onTap: () => Navigator.pop(ctx, i),
                      child: _modeChip(_modes[i], selected: i == _mode),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _mode = picked);
  }

  Future<void> _pickCustom() async {
    if (_started) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Custom length', style: HrText.title2),
              const SizedBox(height: 4),
              Text('Every minute of focus earns 2 XP.', style: HrText.bodyS),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final m in _customChoices)
                    HrPressable(
                      onTap: () => Navigator.pop(ctx, m),
                      child: Container(
                        width: 72,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: m == _minutes && _custom
                              ? HrColors.accent
                              : HrColors.surface2,
                          borderRadius: BorderRadius.circular(HrRadius.md),
                          border: Border.all(color: HrColors.cardEdge),
                        ),
                        child: Text('$m min',
                            style: HrText.body
                                .copyWith(fontWeight: FontWeight.w800)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _setMinutes(picked, custom: true);
  }

  Widget _modeChip((String, String) mode, {bool selected = false, bool arrow = false}) =>
      Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
        decoration: BoxDecoration(
          color: selected ? HrColors.accentSurface : const Color(0xCC0D1018),
          borderRadius: BorderRadius.circular(HrRadius.full),
          border: Border.all(
            color: selected ? HrColors.accent : HrColors.cardEdge,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(mode.$2, style: const TextStyle(fontSize: 15, height: 1)),
            const SizedBox(width: 7),
            Text(mode.$1,
                style: HrText.bodyS.copyWith(
                    color: HrColors.text, fontWeight: FontWeight.w700)),
            if (arrow) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: HrColors.text2),
            ],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: _complete ? _completeView(context) : _timerView(context),
      ),
    );
  }

  Widget _header() => HrPageHeader(
    title: 'Focus',
    subtitle: 'Turn focus into a stronger you.',
    trailing: HrHeaderButton(
      icon: Icons.settings_rounded,
      tooltip: 'Focus mode',
      onPressed: _pickMode,
    ),
  );

  Widget _timerView(BuildContext context) {
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    // The ring is full when a session is ready and drains as time passes.
    final frac = _remaining / (_minutes * 60);
    final label = !_started
        ? 'Focus time'
        : _running
        ? 'Stay with it'
        : 'Paused';
    return ListView(
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        _header(),
        SizedBox(
          height: 372,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 14,
                child: _FocusTimerDial(
                  size: 248,
                  value: frac,
                  color: HrColors.accent,
                  center: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: HrText.body.copyWith(color: HrColors.text2)),
                      const SizedBox(height: 2),
                      Text(
                        '$mm:$ss',
                        style: HrText.numeralXl.copyWith(fontSize: 58),
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        button: true,
                        label: 'Focus mode: ${_modes[_mode].$1}',
                        child: HrPressable(
                          onTap: _pickMode,
                          child: _modeChip(_modes[_mode], arrow: true),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(
                bottom: -6,
                child: HrHeroArt(width: 190, height: 168),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: Row(
            children: [
              for (final p in _presets) ...[
                Expanded(
                  child: _presetTile(
                    p.$1,
                    p.$2,
                    p.$3,
                    selected: !_custom && _minutes == p.$4,
                    onTap: () => _setMinutes(p.$4),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: _presetTile(
                  'Custom',
                  _custom ? '$_minutes min' : null,
                  Icons.tune_rounded,
                  selected: _custom,
                  onTap: _pickCustom,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: !_started
              ? _FocusStartButton(onPressed: _start, minutes: _minutes)
              : Row(
                  children: [
                    Expanded(
                      child: HrButton(
                        label: 'Reset',
                        icon: Icons.refresh_rounded,
                        kind: HrButtonKind.secondary,
                        onPressed: _reset,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _running
                          ? HrButton(
                              label: 'Pause',
                              icon: Icons.pause_rounded,
                              kind: HrButtonKind.accent,
                              onPressed: _pause,
                            )
                          : HrButton(
                              label: 'Resume',
                              icon: Icons.play_arrow_rounded,
                              kind: HrButtonKind.accent,
                              onPressed: _start,
                            ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 10),
        Text(
          !_started
              ? '+${_minutes * 2} XP when you finish · ${appState.focusMinutesToday} min today'
              : _running
              ? '${_modes[_mode].$1} · +${_minutes * 2} XP at the end'
              : 'Session paused',
          style: HrText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _presetTile(
    String title,
    String? sub,
    IconData icon, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final enabled = !_started;
    return Semantics(
      button: true,
      selected: selected,
      label: sub == null ? title : '$title, $sub',
      child: HrPressable(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: HrMotion.of(context, HrMotion.base),
          height: 86,
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.lerp(HrColors.accentSurface, HrColors.accent, 0.18)!,
                      HrColors.accentSurface,
                    ],
                  )
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [HrColors.cardTop, HrColors.cardBottom],
                  ),
            borderRadius: BorderRadius.circular(HrRadius.md),
            border: Border.all(
              color: selected ? HrColors.accentBright : HrColors.cardEdge,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: HrColors.accent.withValues(alpha: 0.45),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: Opacity(
            opacity: enabled || selected ? 1 : 0.5,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 28,
                  color: selected
                      ? HrColors.accentBright
                      : (title == 'Short'
                          ? HrColors.success
                          : const Color(0xFFC9C3F0)),
                ),
                const SizedBox(height: 6),
                Text(title,
                    style: HrText.bodyS.copyWith(
                        color: HrColors.text, fontWeight: FontWeight.w800)),
                if (sub != null)
                  Text(sub, style: HrText.micro.copyWith(color: HrColors.text2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _completeView(BuildContext context) {
    final questDone = kQuests.firstWhere((q) => q.id == 'q2').done(appState);
    final comp = companionByType(appState.activeCompanion);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _header(),
        const SizedBox(height: 12),
        Center(
          child: SegmentedRing(
            size: 250,
            segments: 1,
            value: 1,
            stroke: 10,
            color: HrColors.accent,
            center: const HrHeroArt(width: 170, height: 170),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('Session complete', style: HrText.title1),
        ),
        const SizedBox(height: 6),
        Center(
          child: SpeechBubble(
            'Session complete. Output logged.',
            speaker: comp.name,
            maxWidth: 280,
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: Row(
            children: [
              Expanded(
                child: HrStatTile(
                  value: '+$_lastGain',
                  label: 'XP earned',
                  icon: Icons.auto_awesome,
                  valueColor: HrColors.gold,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: HrStatTile(
                  value: '${appState.focusMinutesToday}',
                  label: 'Min today',
                  icon: Icons.timer_rounded,
                  leading: Icon(Icons.timer_rounded,
                      size: 28, color: HrColors.accentBright),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: HrStatTile(
                  value: questDone ? '1/1' : '0/1',
                  label: 'Quest',
                  leading: Icon(Icons.flag_rounded,
                      size: 28,
                      color: questDone ? HrColors.success : HrColors.text3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: HrButton(
            label: 'Back to Today',
            kind: HrButtonKind.accent,
            onPressed: _backToToday,
          ),
        ),
      ],
    );
  }
}

class _FocusStartButton extends StatelessWidget {
  const _FocusStartButton({required this.onPressed, required this.minutes});

  final VoidCallback onPressed;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Start focus, $minutes minutes',
      excludeSemantics: true,
      child: HrPressable(
        onTap: onPressed,
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color.lerp(HrColors.accent, Colors.white, 0.14)!,
                HrColors.accent,
                Color.lerp(HrColors.accent, Colors.white, 0.1)!,
              ],
            ),
            borderRadius: BorderRadius.circular(HrRadius.full),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: [
              BoxShadow(
                color: HrColors.accent.withValues(alpha: 0.5),
                blurRadius: 22,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.play_arrow_rounded, size: 32, color: HrColors.text),
              const SizedBox(width: 8),
              Text(
                'Start Focus',
                style: HrText.title2.copyWith(fontSize: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FocusTimerDial extends StatelessWidget {
  const _FocusTimerDial({
    required this.size,
    required this.value,
    required this.color,
    required this.center,
  });

  final double size, value;
  final Color color;
  final Widget center;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: value),
    duration: const Duration(milliseconds: 450),
    curve: Curves.easeOutCubic,
    builder: (context, progress, _) => SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _FocusDialPainter(progress, color),
        child: Center(child: center),
      ),
    ),
  );
}

// Glowing violet ring like the reference: a soft halo, a faint track and a
// bright arc (with a cyan tail) showing the time left in the session.
class _FocusDialPainter extends CustomPainter {
  const _FocusDialPainter(this.value, this.color);

  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 10;
    final ringRect = Rect.fromCircle(center: center, radius: radius);

    // Dark disc so the numerals sit on calm ground.
    canvas.drawCircle(
      center,
      radius - 8,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xE6141529), Color(0xCC0A0B14)],
        ).createShader(Rect.fromCircle(center: center, radius: radius - 8)),
    );
    // Outer halo.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 22
        ..color = color.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    // Track.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..color = color.withValues(alpha: 0.22),
    );

    final v = value.clamp(0.0, 1.0).toDouble();
    if (v <= 0) return;
    // A small gap at 12 o'clock, like the reference ring.
    const gap = 0.06;
    final start = -pi / 2 + gap;
    final sweep = (2 * pi - gap * 2) * v;
    // t = 0 at 12 o'clock (rotated), with a cyan glint on the upper right.
    final light = Color.lerp(color, Colors.white, 0.3)!;
    final shader = SweepGradient(
      transform: const GradientRotation(-pi / 2),
      colors: [light, const Color(0xFF5FD4FF), color, color, light],
      stops: const [0.02, 0.2, 0.36, 0.85, 1],
    ).createShader(ringRect);
    canvas.drawArc(
      ringRect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..shader = shader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawArc(
      ringRect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_FocusDialPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}

// ── PROGRESS (Stats · Awards · Journal) ─────────────────────────────────────
// Folds the old Stats, Awards and Journal tabs behind one segmented control.
class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});
  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int _period = 0; // 0 = Month, 1 = Year, 2 = All time

  static const _kDayInitials = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _kMonthInitials = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

  // The current period and the same stretch of the one before it.
  ({DateTime from, DateTime to, DateTime? prevFrom, DateTime? prevTo}) _range() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    switch (_period) {
      case 0:
        return (
          from: DateTime(now.year, now.month, 1),
          to: tomorrow,
          prevFrom: DateTime(now.year, now.month - 1, 1),
          prevTo: DateTime(now.year, now.month - 1, now.day + 1),
        );
      case 1:
        return (
          from: DateTime(now.year, 1, 1),
          to: tomorrow,
          prevFrom: DateTime(now.year - 1, 1, 1),
          prevTo: DateTime(now.year - 1, now.month, now.day + 1),
        );
      default:
        return (from: DateTime(2000), to: tomorrow, prevFrom: null, prevTo: null);
    }
  }

  static String _fmtMinutes(int m) {
    if (m < 60) return '${m}m';
    final h = m ~/ 60, r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  bool _activeOn(String k) =>
      (appState.dailyDone[k] ?? 0) > 0 ||
      (appState.dailyFocus[k] ?? 0) > 0 ||
      appState.perfectDays.contains(k) ||
      (appState.dailyScore[k] ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              HrPageHeader(
                title: 'Progress',
                trailing: HrHeaderButton(
                  icon: Icons.ios_share_rounded,
                  tooltip: 'Share progress',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShareCardScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _pad(HrSegmented(
                items: const ['Month', 'Year', 'All time'],
                index: _period,
                onChanged: (i) => setState(() => _period = i),
              )),
              const SizedBox(height: 14),
              _pad(_totalsCard()),
              const SizedBox(height: 12),
              _pad(_streakCard()),
              const SizedBox(height: 12),
              _pad(_xpChartCard()),
              const SizedBox(height: 22),
              _pad(HrLabel(
                'Recent achievements',
                trailing: HrLink('See all',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AwardsScreen()))),
              )),
              _pad(_recentAchievements()),
              const SizedBox(height: 22),
              _pad(const HrLabel('Your journey')),
              _pad(_journeyGrid()),
              const SizedBox(height: 14),
              const _CompanionCard(),
              const SizedBox(height: 4),
              _pad(HrMenuGroup(children: [
                HrMenuRow(
                  icon: Icons.auto_awesome_rounded,
                  iconColor: HrColors.gold,
                  label: 'Prestige',
                  subtitle: appState.canPrestige
                      ? 'Ready — rebirth with a new star'
                      : 'Unlocks at Level $kPrestigeMinLevel',
                  value: appState.prestige > 0
                      ? Text('★ ${appState.prestige}',
                          style: HrText.bodyS.copyWith(
                              color: HrColors.gold,
                              fontWeight: FontWeight.w900))
                      : null,
                  onTap: () {
                    // Ask to prestige right away if eligible; else explain why.
                    if (appState.canPrestige) {
                      _confirmPrestige(context);
                    } else {
                      hrToast(context,
                          'Prestige unlocks at Level $kPrestigeMinLevel',
                          icon: Icons.auto_awesome_rounded);
                    }
                  },
                ),
                HrMenuRow(
                  icon: Icons.leaderboard_rounded,
                  label: 'Leaderboard',
                  subtitle: 'See how your friends are doing',
                  onTap: () => shellTab.value = 3,
                ),
                HrMenuRow(
                  icon: Icons.workspace_premium_rounded,
                  label: 'Legacy',
                  subtitle: 'Career bests and milestones',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const LegacyScreen())),
                ),
              ])),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
    child: child,
  );

  Widget _totalsCard() {
    final r = _range();
    final focus = appState.sumDays(appState.dailyFocus, r.from, r.to);
    final done = appState.sumDays(appState.dailyDone, r.from, r.to);
    int? delta(Map<String, int> m, int cur) {
      if (r.prevFrom == null) return null;
      final prev = appState.sumDays(m, r.prevFrom!, r.prevTo!);
      if (prev == 0) return null;
      return ((cur - prev) / prev * 100).round();
    }

    return HrCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _totalStat(
                icon: Icons.schedule_rounded,
                colors: [HrColors.accentBright, HrColors.accent],
                label: 'Total focus time',
                value: _fmtMinutes(focus),
                change: delta(appState.dailyFocus, focus),
              ),
            ),
            const VerticalDivider(width: 20, color: HrColors.cardEdge),
            Expanded(
              child: _totalStat(
                icon: Icons.check_rounded,
                colors: const [Color(0xFF5BE3A6), Color(0xFF1FA971)],
                label: 'Quests completed',
                value: hrNum(done),
                change: delta(appState.dailyDone, done),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _totalStat({
    required IconData icon,
    required List<Color> colors,
    required String label,
    required String value,
    int? change,
  }) {
    final up = (change ?? 0) >= 0;
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            boxShadow: [
              BoxShadow(color: colors.last.withValues(alpha: 0.45), blurRadius: 12),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.micro.copyWith(color: HrColors.text2)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    style: HrText.title2.copyWith(fontWeight: FontWeight.w900)),
              ),
              if (change != null)
                Row(
                  children: [
                    Icon(
                      up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                      size: 13,
                      color: up ? HrColors.success : HrColors.dangerText,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${up ? '+' : ''}$change%',
                      style: HrText.micro.copyWith(
                        color: up ? HrColors.success : HrColors.dangerText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _streakCard() {
    final streak = appState.bestStreak;
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    return HrCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset('assets/streaks/enamel_flame.png', width: 40, height: 40),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Day streak',
                      style: HrText.caption.copyWith(color: HrColors.text2)),
                  Text.rich(TextSpan(children: [
                    TextSpan(
                      text: '$streak',
                      style: HrText.title1.copyWith(color: HrColors.gold),
                    ),
                    TextSpan(
                      text: streak == 1 ? ' day' : ' days',
                      style: HrText.title2,
                    ),
                  ])),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 7; i++)
                Builder(builder: (context) {
                  final d = monday.add(Duration(days: i));
                  final k = dateKey(d);
                  final on = _activeOn(k);
                  final isToday = dateKey(now) == k;
                  return Semantics(
                    label: '${_kDayInitials[i]}${on ? ', active' : ''}',
                    excludeSemantics: true,
                    child: Column(
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: on
                                ? const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [HrColors.goldBright, HrColors.goldDeep],
                                  )
                                : null,
                            border: on
                                ? null
                                : Border.all(color: HrColors.controlBorder, width: 1.5),
                            boxShadow: on
                                ? [
                                    BoxShadow(
                                      color: HrColors.gold.withValues(alpha: 0.5),
                                      blurRadius: 9,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _kDayInitials[i],
                          style: HrText.micro.copyWith(
                            color: isToday ? HrColors.text : HrColors.text2,
                            fontWeight: isToday ? FontWeight.w900 : FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ],
      ),
    );
  }

  // Bars for the chart: daily for Month, monthly for Year / All time.
  ({List<int> values, List<String> labels, String title}) _xpSeries() {
    final now = DateTime.now();
    final xp = appState.dailyXp;
    if (_period == 0) {
      final days = DateTime(now.year, now.month + 1, 0).day;
      final values = [
        for (var d = 1; d <= days; d++) xp[dateKey(DateTime(now.year, now.month, d))] ?? 0,
      ];
      final labels = [
        for (var d = 1; d <= days; d++)
          (d == 1 || d % 5 == 0) ? '$d' : '',
      ];
      return (values: values, labels: labels, title: 'XP this month');
    }
    // 12 monthly buckets: this year (Year) or the last 12 months (All time).
    final start = _period == 1
        ? DateTime(now.year, 1, 1)
        : DateTime(now.year, now.month - 11, 1);
    final values = <int>[];
    final labels = <String>[];
    for (var i = 0; i < 12; i++) {
      final a = DateTime(start.year, start.month + i, 1);
      final b = DateTime(start.year, start.month + i + 1, 1);
      values.add(appState.sumDays(xp, a, b));
      labels.add(_kMonthInitials[a.month - 1]);
    }
    return (
      values: values,
      labels: labels,
      title: _period == 1 ? 'XP this year' : 'XP all time',
    );
  }

  Widget _xpChartCard() {
    final s = _xpSeries();
    final total = _period == 2
        ? appState.dailyXp.values.fold<int>(0, (a, b) => a + b)
        : s.values.fold<int>(0, (a, b) => a + b);
    final maxV = s.values.fold<int>(0, max);
    final peak = maxV == 0 ? -1 : s.values.indexOf(maxV);
    return HrCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(s.title, style: HrText.headline)),
              Text('${hrNum(total)} XP',
                  style: HrText.headline.copyWith(
                      color: HrColors.gold, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 128,
            child: LayoutBuilder(builder: (context, c) {
              final n = s.values.length;
              final slot = c.maxWidth / n;
              final barW = max(3.0, min(slot * 0.62, 18.0));
              const chartTop = 26.0, chartH = 128.0 - chartTop;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Faint guide lines.
                  for (var g = 0; g < 3; g++)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: chartTop + chartH * g / 3,
                      child: Container(height: 1, color: const Color(0x14FFFFFF)),
                    ),
                  for (var i = 0; i < n; i++)
                    Positioned(
                      left: slot * i + (slot - barW) / 2,
                      bottom: 0,
                      width: barW,
                      height: maxV == 0
                          ? 5
                          : max(4.0, chartH * s.values[i] / maxV),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(barW / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: maxV > 0 && s.values[i] >= maxV * 0.7
                                ? [HrColors.goldBright, HrColors.gold, HrColors.accent]
                                : [HrColors.accentBright, HrColors.accent],
                            stops: maxV > 0 && s.values[i] >= maxV * 0.7
                                ? const [0, 0.35, 1]
                                : null,
                          ),
                          boxShadow: s.values[i] > 0
                              ? [
                                  BoxShadow(
                                    color: HrColors.accent.withValues(alpha: 0.35),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  if (peak >= 0)
                    Positioned(
                      left: (slot * peak + slot / 2 - 34).clamp(0.0, c.maxWidth - 68),
                      top: 0, // just above the tallest bar
                      width: 68,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: HrColors.surface2,
                            borderRadius: BorderRadius.circular(HrRadius.xs),
                            border: Border.all(color: HrColors.accentBright),
                          ),
                          child: Text('${hrNum(maxV)} XP',
                              style: HrText.micro.copyWith(color: HrColors.text)),
                        ),
                      ),
                    ),
                  if (maxV == 0)
                    Positioned.fill(
                      child: Center(
                        child: Text(
                          'Complete quests to fill this chart',
                          style: HrText.caption,
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final l in s.labels)
                Expanded(
                  child: Text(
                    l,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: HrText.micro.copyWith(color: HrColors.text2),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recentAchievements() {
    final earned = kAchievements.where(appState.isAchievementEarned).toList();
    final show = earned.isNotEmpty
        ? earned.reversed.take(3).toList()
        : kAchievements.take(3).toList();
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: i < show.length
                ? _achievementMini(show[i], appState.isAchievementEarned(show[i]))
                : const SizedBox(),
          ),
        ],
      ],
    );
  }

  Widget _achievementMini(Achievement a, bool earned) => HrCard(
    onTap: () => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AwardsScreen())),
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
    radius: HrRadius.md,
    child: Column(
      children: [
        Opacity(
          opacity: earned ? 1 : 0.4,
          child: Image.asset(a.imageAsset, width: 60, height: 60),
        ),
        const SizedBox(height: 8),
        Text(
          a.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: HrText.bodyS.copyWith(
              color: HrColors.text, fontWeight: FontWeight.w800, fontSize: 13),
        ),
        Text(
          earned ? a.description : 'Locked',
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: HrText.micro.copyWith(color: HrColors.text2),
        ),
      ],
    ),
  );

  Widget _journeyGrid() {
    final items = <(String, IconData, Color, Widget Function())>[
      ('Calendar', Icons.calendar_month_rounded, const Color(0xFF62D5FF), () => const CalendarScreen()),
      ('Stats', Icons.insights_rounded, HrColors.accentBright, () => const StatsScreen()),
      ('Awards', Icons.emoji_events_rounded, HrColors.gold, () => const AwardsScreen()),
      ('Journal', Icons.menu_book_rounded, const Color(0xFFFF6EB4), () => const JournalScreen()),
    ];
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: HrCard(
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => items[i].$4())),
              padding: const EdgeInsets.symmetric(vertical: 12),
              radius: HrRadius.md,
              child: Column(
                children: [
                  HrIconTile(icon: items[i].$2, color: items[i].$3, size: 44),
                  const SizedBox(height: 8),
                  Text(items[i].$1,
                      style: HrText.caption.copyWith(
                          color: HrColors.text, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

const _kMonthsFull = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _compactNum(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

// ── CALENDAR (Progress tab) ─────────────────────────────────────────────────
// A weekly streak ring + a month grid coloured by each day's victory score.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({this.embedded = false, super.key});
  final bool embedded;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
  }

  void _shift(int d) =>
      setState(() => _month = DateTime(_month.year, _month.month + d, 1));

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final week = appState.perfectDaysThisWeek();
    final comp = companionByType(appState.activeCompanion);
    final streak = appState.bestStreak;
    final line =
        '$week of 7 this week. ${week >= 6 ? 'Close.' : 'Keep going.'}';
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 100),
      children: [
        SizedBox(
          height: 150,
          child: Center(
            child: SizedBox(
              width: 150,
              height: 150,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  SegmentedRing(
                    size: 140,
                    segments: 7,
                    value: week.toDouble(),
                    stroke: 9,
                    color: HrColors.accent,
                    center: CompanionSticker(
                      icon: comp.icon,
                      color: comp.color,
                      size: 86,
                      semanticLabel: comp.name,
                      imageAsset: comp.imageAsset,
                    ),
                  ),
                  if (streak > 0)
                    Positioned(
                      bottom: -6,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: StreakPill(
                          count: streak,
                          big: true,
                          label: '$streak DAY STREAK',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: SpeechBubble(line, speaker: comp.name, maxWidth: 220)),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: _monthCard(context, now),
        ),
      ],
    );
  }

  Widget _monthCard(BuildContext context, DateTime now) {
    final first = _month;
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final leading = first.weekday - 1; // Monday = 0 leading cells
    final todayK = dateKey(now);
    final atCurrentMonth = first.year == now.year && first.month == now.month;
    return HrCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '${_kMonthsFull[first.month - 1]} ${first.year}',
                style: HrText.headline,
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _shift(-1),
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.chevron_left_rounded,
                  color: HrColors.text2,
                ),
              ),
              IconButton(
                onPressed: atCurrentMonth ? null : () => _shift(1),
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.chevron_right_rounded,
                  color: HrColors.text2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final d in const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'])
                Expanded(
                  child: Center(child: Text(d, style: HrText.micro)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (int i = 0; i < leading; i++) const SizedBox.shrink(),
              for (int day = 1; day <= daysInMonth; day++)
                _dayCell(
                  context,
                  DateTime(first.year, first.month, day),
                  todayK,
                  now,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(
    BuildContext context,
    DateTime date,
    String todayK,
    DateTime now,
  ) {
    final k = dateKey(date);
    final score = appState.dailyScore[k];
    final perfect = appState.perfectDays.contains(k);
    final isToday = k == todayK;
    final isFuture = date.isAfter(DateTime(now.year, now.month, now.day));
    final strong = perfect || (score != null && score >= 75);
    Color bg = HrColors.surface2;
    Widget? mark;
    if (strong) {
      bg = HrColors.accent;
      mark = Icon(Icons.check_rounded, size: 15, color: HrColors.onAccent);
    } else if (score != null && score > 0) {
      bg = HrColors.victory(score).withValues(alpha: 0.9);
    }
    return GestureDetector(
      onTap: isFuture ? null : () => _showDay(context, date, score, perfect),
      child: Opacity(
        opacity: isFuture ? 0.35 : 1,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(HrRadius.xs),
            border: isToday
                ? Border.all(color: HrColors.text, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child:
              mark ??
              Text(
                '${date.day}',
                style: HrText.caption.copyWith(
                  color: strong ? HrColors.onAccent : HrColors.text2,
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
        ),
      ),
    );
  }

  void _showDay(BuildContext context, DateTime date, int? score, bool perfect) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: HrColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: HrColors.surface3,
                  borderRadius: BorderRadius.circular(2),
              ),
            ),
            ),
            Text(
              '${_kWeekdays[date.weekday - 1]}, ${_kMonthsFull[date.month - 1]} ${date.day}',
              style: HrText.title2,
            ),
            const SizedBox(height: 14),
            if (score == null)
              Text('No activity recorded for this day.', style: HrText.bodyS)
            else
              Row(
                children: [
                  CountSticker(
                    '$score',
                    size: 30,
                    fill: HrColors.victory(score),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        victoryLabel(score),
                        style: HrText.headline.copyWith(
                          color: HrColors.victory(score),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Victory score${perfect ? ' · Perfect day' : ''}',
                        style: HrText.caption,
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.sub,
    required this.color,
  });
  final String label, value;
  final String? sub;
  final Color color;
  IconData get _icon => switch (label) {
    'Level' => Icons.workspace_premium_rounded,
    'Total XP' => Icons.auto_awesome_rounded,
    'Best streak' => Icons.local_fire_department_rounded,
    'Perfect days' => Icons.stars_rounded,
    'Avg score 7d' => Icons.insights_rounded,
    'Coins' => Icons.monetization_on_rounded,
    _ => Icons.circle_rounded,
  };

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1A1B2B), Color(0xFF10111B)],
      ),
      borderRadius: BorderRadius.circular(HrRadius.md),
      border: Border.all(color: color.withValues(alpha: 0.28), width: 0.9),
      boxShadow: [
        BoxShadow(
          color: color.withValues(alpha: 0.07),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Icon(
          _icon,
          size: 19,
          color: color,
          shadows: [Shadow(color: color.withValues(alpha: 0.36), blurRadius: 9)],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.stat.copyWith(fontSize: 23, color: color),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.caption.copyWith(fontSize: 11),
            ),
            if (sub != null)
              Text(
                sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HrText.micro.copyWith(color: HrColors.text3),
              ),
          ],
        ),
      ],
    ),
  );
}

Widget _legacyLink(BuildContext context) => HrCard(
  onTap: () =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LegacyScreen())),
  child: Row(
    children: [
      const Icon(Icons.history_rounded, color: HrColors.text2, size: 20),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          'Legacy timeline',
          style: HrText.body.copyWith(fontWeight: FontWeight.w600),
      ),
      ),
      Text(
        '${appState.milestoneLog.length}',
        style: HrText.body.copyWith(color: HrColors.text3),
      ),
      const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
    ],
  ),
);

class StatsScreen extends StatelessWidget {
  const StatsScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final tiles = <(String, String, String?, Color)>[
      ('Level', '${ld.level}', levelTitle(ld.level), HrColors.text),
      ('Total XP', _compactNum(appState.totalXp), null, HrColors.accent),
      ('Best streak', '${appState.bestStreak}', null, HrColors.streak),
      ('Perfect days', '${appState.totalPerfectDays}', null, HrColors.text),
      (
        'Avg score 7d',
        '${appState.avgScoreLastDays(7).round()}',
        null,
        HrColors.text,
      ),
      ('Coins', '${appState.coins}', null, HrColors.gold),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        4,
        HrSpace.gutter,
        100,
      ),
      children: [
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.9,
          children: tiles
              .map(
                (t) =>
                    _StatTile(label: t.$1, value: t.$2, sub: t.$3, color: t.$4),
              )
              .toList(),
        ),
        const SizedBox(height: 14),
        const _WeeklyReportCard(),
        const SizedBox(height: 14),
        const _WeeklyPlanCard(),
        const SizedBox(height: 14),
        const _InsightsCard(),
        const SizedBox(height: 14),
        const _WeekTrendCard(),
        const SizedBox(height: 14),
        const _HabitStreaksCard(),
        const SizedBox(height: 14),
        const _HeatmapCard(),
        const SizedBox(height: 14),
        _legacyLink(context),
      ],
    );
  }
}

// _StatCard was replaced by _StatTile (flat redesign).

// ── Premium: Weekly AI Coach Report ─────────────────────────────────────────
// A once-a-week AI recap of the week. Premium-only; cached so it generates at
// most once per week. Does not touch the daily coach allowance.
class _WeeklyReportCard extends StatefulWidget {
  const _WeeklyReportCard();
  @override
  State<_WeeklyReportCard> createState() => _WeeklyReportCardState();
}

class _WeeklyReportCardState extends State<_WeeklyReportCard> {
  bool _loading = false;

  int _perfectThisWeek() {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    var c = 0;
    for (final k in appState.perfectDays) {
      final d = DateTime.tryParse(k);
      if (d != null && !d.isBefore(monday)) c++;
    }
    return c;
  }

  Future<void> _generate() async {
    setState(() => _loading = true);
    final avg = appState.avgScoreLastDays(7).round();
    final perfect = _perfectThisWeek();
    final summary =
        'Weekly review. Perfect days this week: $perfect. Average victory score '
        '(last 7 days): $avg out of 100. Best streak: ${appState.bestStreak} days. '
        'Habits tracked: ${appState.habits.length}. Level '
        '${levelFromXp(appState.totalXp).level}. Write a short, encouraging weekly '
        'coaching recap (2-3 sentences) with one concrete focus for next week.';
    final msg = await aiCoachMessage(
      summary,
      enabled: appState.aiEnabled,
      baseUrl: appState.aiBaseUrl,
      model: appState.aiModel,
    );
    if (!mounted) return;
    final text = msg ??
        'Average score $avg with $perfect perfect day${perfect == 1 ? '' : 's'} '
            'this week. Pick one habit to protect every day next week.';
    appState.saveWeeklyReport(text);
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final premium = appState.isPremium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.summarize_rounded, color: HrColors.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Weekly Coach Report', style: HrText.headline)),
            if (!premium) _lockPill(),
          ]),
          const SizedBox(height: 10),
          if (!premium) ...[
            Text(
                'An AI recap of your week — what went well, your patterns, and one '
                'focus for next week.',
                style: HrText.bodyS.copyWith(color: HrColors.text2)),
            const SizedBox(height: 12),
            HrButton(
                label: 'Unlock with Premium',
                icon: Icons.workspace_premium_rounded,
                kind: HrButtonKind.secondary,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PremiumScreen()))),
          ] else if (_loading) ...[
            Row(children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Writing your weekly report…', style: HrText.bodyS),
            ]),
          ] else if (appState.weeklyReportIsCurrent) ...[
            Text('"${appState.weeklyReportText}"',
                style: HrText.bodyS.copyWith(
                    color: HrColors.text2, fontStyle: FontStyle.italic)),
            const SizedBox(height: 10),
            _secondaryPill('Regenerate', _generate),
          ] else ...[
            Text('Your week in review, summarized by your AI coach.',
                style: HrText.bodyS.copyWith(color: HrColors.text2)),
            const SizedBox(height: 12),
            HrButton(
                label: "Generate this week's report",
                icon: Icons.auto_awesome_rounded,
                kind: HrButtonKind.secondary,
                onPressed: _generate),
          ],
        ]),
      ),
    );
  }
}

// ── Premium: Weekly AI Plan ─────────────────────────────────────────────────
// Forward-looking companion to the Weekly Report: a short plan for the week
// ahead. Premium-only; cached per week.
class _WeeklyPlanCard extends StatefulWidget {
  const _WeeklyPlanCard();
  @override
  State<_WeeklyPlanCard> createState() => _WeeklyPlanCardState();
}

class _WeeklyPlanCardState extends State<_WeeklyPlanCard> {
  bool _loading = false;

  Future<void> _generate() async {
    setState(() => _loading = true);
    final ld = levelFromXp(appState.totalXp);
    final habitNames = appState.habits.map((h) => h.name).take(8).join(', ');
    final avg = appState.avgScoreLastDays(7).round();
    final summary = 'Plan the week ahead. Habits: $habitNames. '
        'Average victory score (last 7 days): $avg/100. '
        'Best streak: ${appState.bestStreak} days. '
        'Habits done today: ${appState.doneTodayCount}/${appState.habits.length}. '
        'Level ${ld.level}.';
    final msg = await aiWeeklyPlan(
      summary,
      enabled: appState.aiEnabled,
      baseUrl: appState.aiBaseUrl,
      model: appState.aiModel,
    );
    if (!mounted) return;
    final text = msg ??
        '- Protect your best streak every day\n'
            '- Pick one habit you keep missing and do it first\n'
            '- Aim for one perfect day this week';
    appState.saveWeeklyPlan(text);
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final premium = appState.isPremium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flag_circle_rounded, color: HrColors.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Your Weekly Plan', style: HrText.headline)),
            if (!premium) _lockPill(),
          ]),
          const SizedBox(height: 10),
          if (!premium) ...[
            Text(
                'A personalized, AI-made plan for the week ahead — a few concrete '
                'focus actions.',
                style: HrText.bodyS.copyWith(color: HrColors.text2)),
            const SizedBox(height: 12),
            HrButton(
                label: 'Unlock with Premium',
                icon: Icons.workspace_premium_rounded,
                kind: HrButtonKind.secondary,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PremiumScreen()))),
          ] else if (_loading) ...[
            Row(children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Building your plan…', style: HrText.bodyS),
            ]),
          ] else if (appState.weeklyPlanIsCurrent) ...[
            Text(appState.weeklyPlanText,
                style: HrText.bodyS
                    .copyWith(color: HrColors.text2, height: 1.5)),
            const SizedBox(height: 10),
            _secondaryPill('Regenerate', _generate),
          ] else ...[
            Text('A focused plan for the next 7 days, made by your AI coach.',
                style: HrText.bodyS.copyWith(color: HrColors.text2)),
            const SizedBox(height: 12),
            HrButton(
                label: "Generate this week's plan",
                icon: Icons.auto_awesome_rounded,
                kind: HrButtonKind.secondary,
                onPressed: _generate),
          ],
        ]),
      ),
    );
  }
}

// ── Premium: Deeper insights ────────────────────────────────────────────────
// Real patterns computed from the user's own history (trend, best day,
// consistency, strongest habit). Premium-only; free users see a teaser.
class _InsightsCard extends StatelessWidget {
  const _InsightsCard();

  List<(IconData, String, String)> _insights() {
    final rows = <(IconData, String, String)>[];
    final scores = appState.dailyScore;
    if (scores.isNotEmpty) {
      final avg7 = appState.avgScoreLastDays(7);
      final keys = scores.keys.toList()..sort();
      var prev7 = 0.0;
      if (keys.length > 7) {
        final start = (keys.length - 14).clamp(0, keys.length);
        final prevKeys = keys.sublist(start, keys.length - 7);
        if (prevKeys.isNotEmpty) {
          prev7 = prevKeys.fold<int>(0, (a, k) => a + (scores[k] ?? 0)) /
              prevKeys.length;
        }
      }
      final delta = (avg7 - prev7).round();
      final trend = prev7 == 0
          ? 'avg ${avg7.round()}'
          : 'avg ${avg7.round()} · ${delta >= 0 ? '+' : ''}$delta vs last week';
      rows.add((
        delta >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
        'Weekly trend',
        trend,
      ));

      final byDow = <int, List<int>>{};
      scores.forEach((k, v) {
        final d = DateTime.tryParse(k);
        if (d != null) (byDow[d.weekday] ??= []).add(v);
      });
      if (byDow.isNotEmpty) {
        var bestDow = byDow.keys.first;
        var bestAvg = -1.0;
        byDow.forEach((dow, vs) {
          final a = vs.fold<int>(0, (x, y) => x + y) / vs.length;
          if (a > bestAvg) {
            bestAvg = a;
            bestDow = dow;
          }
        });
        rows.add((
          Icons.event_available_rounded,
          'Best day',
          '${_kWeekdays[bestDow - 1]} · avg ${bestAvg.round()}',
        ));
      }

      final today = DateTime.now();
      var active = 0;
      for (var i = 0; i < 30; i++) {
        final k = dateKey(today.subtract(Duration(days: i)));
        if ((scores[k] ?? 0) > 0) active++;
      }
      rows.add((
        Icons.calendar_month_rounded,
        'Consistency',
        '${((active / 30) * 100).round()}% of last 30 days',
      ));
    }
    final habits = [...appState.habits]
      ..sort((a, b) => b.streak.compareTo(a.streak));
    if (habits.isNotEmpty && habits.first.streak > 0) {
      rows.add((
        Icons.local_fire_department_rounded,
        'Strongest habit',
        '${habits.first.name} · ${habits.first.streak}d',
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final premium = appState.isPremium;
    final rows = premium ? _insights() : const <(IconData, String, String)>[];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.insights_rounded, color: HrColors.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Deeper insights', style: HrText.headline)),
            if (!premium) _lockPill(),
          ]),
          const SizedBox(height: 10),
          if (!premium) ...[
            Text(
                'Consistency trends, your best days, and cross-habit patterns from '
                'your own history.',
                style: HrText.bodyS.copyWith(color: HrColors.text2)),
            const SizedBox(height: 12),
            HrButton(
                label: 'Unlock with Premium',
                icon: Icons.workspace_premium_rounded,
                kind: HrButtonKind.secondary,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PremiumScreen()))),
          ] else if (rows.isEmpty)
            Text('Keep logging habits and a few days of scores to reveal your '
                'patterns here.',
                style: HrText.bodyS.copyWith(color: HrColors.text2))
          else
            ...rows.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Icon(r.$1, size: 16, color: HrColors.text3),
                    const SizedBox(width: 10),
                    Text(r.$2,
                        style: HrText.bodyS.copyWith(color: HrColors.text2)),
                    const Spacer(),
                    Flexible(
                      child: Text(r.$3,
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              HrText.bodyS.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ]),
                )),
        ]),
      ),
    );
  }
}

// Small gold PREMIUM chip for locked cards.
Widget _lockPill() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: HrColors.accentSurface,
          borderRadius: BorderRadius.circular(HrRadius.xs)),
      child: Text('PREMIUM',
          style: HrText.micro
              .copyWith(color: HrColors.accent, fontWeight: FontWeight.w800)),
    );

class _HabitStreaksCard extends StatelessWidget {
  const _HabitStreaksCard();
  @override
  Widget build(BuildContext context) {
    final habits = [...appState.habits]
      ..sort((a, b) => b.streak.compareTo(a.streak));
    if (habits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HrLabel('Habit streaks'),
            ...habits
                .take(8)
                .map(
                  (h) => Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            h.icon.isEmpty ? h.name : '${h.icon}  ${h.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HrText.body.copyWith(color: HrColors.text2),
                          ),
                        ),
                        if (h.streak > 0)
                          StreakPill(count: h.streak, quiet: true)
                        else
                          Text(
                            '—',
                            style: HrText.body.copyWith(color: HrColors.text3),
                          ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
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
      final origin = box != null
          ? (box.localToGlobal(Offset.zero) & box.size)
          : null;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ImageByteFormat.png);
      if (data == null) throw 'encode failed';
      final file = File(
        '${Directory.systemTemp.path}/habitrail_progress_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text:
              "I'm Level ${appState.level} on Habitrail with a ${appState.bestStreak}-day streak! 🔥 Build habits, earn XP, level up.",
          sharePositionOrigin: origin,
        ),
      );
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
        final cardWidth = min(
          360.0,
          MediaQuery.sizeOf(context).width - HrSpace.gutter * 2,
        );
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Share progress'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              32,
            ),
            children: [
              Center(
                child: RepaintBoundary(
                  key: _cardKey,
                  child: SizedBox(
                    width: cardWidth,
                    height: cardWidth * 16 / 9,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 24,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF17151E), Color(0xFF0A0A0D)],
                        ),
                        borderRadius: BorderRadius.circular(HrRadius.xl),
                        border: Border.all(color: const Color(0xFF34313D)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x553E2B65),
                            blurRadius: 24,
                            spreadRadius: -10,
                          ),
                        ],
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            top: -70,
                            right: -80,
                            child: Container(
                              width: 180,
                              height: 180,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Color(0x182C87FF),
                                    blurRadius: 70,
                                    spreadRadius: 18,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.route_rounded,
                                    size: 17,
                                    color: Color(0xFF8B73FF),
                                  ),
                                  const SizedBox(width: 7),
                                  Text(
                                    'HABITRAIL',
                                    style: HrText.caption.copyWith(
                                      color: HrColors.text,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 2.2,
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                children: [
                                  Image.asset(
                                    'assets/streaks/enamel_flame.png',
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.contain,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${appState.bestStreak}',
                                    style: const TextStyle(
                                      color: Color(0xFFFFB547),
                                      fontSize: 48,
                                      height: 1,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -1.5,
                                    ),
                                  ),
                                  Text(
                                    appState.bestStreak == 1
                                        ? 'DAY IN A ROW'
                                        : 'DAYS IN A ROW',
                                    style: HrText.micro.copyWith(
                                      color: const Color(0xFFFFC979),
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _Avatar(size: 64),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          appState.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: HrText.title2,
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          'Level ${ld.level} · ${levelTitle(ld.level)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: HrText.caption,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                children: [
                                  Row(
                                    children: [
                                      _shareStat(
                                        Icons.emoji_events_rounded,
                                        HrColors.gold,
                                        'Daily Score',
                                        '${v.score}',
                                      ),
                                      const SizedBox(width: 8),
                                      _shareStat(
                                        Icons.bolt_rounded,
                                        const Color(0xFF79DCFF),
                                        'Total XP',
                                        '${appState.totalXp}',
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      _shareStat(
                                        Icons.check_circle_rounded,
                                        const Color(0xFF7FE2B0),
                                        'Habits',
                                        '${appState.habits.length}',
                                      ),
                                      const SizedBox(width: 8),
                                      _shareStat(
                                        Icons.workspace_premium_rounded,
                                        const Color(0xFFC49BFF),
                                        'Prestige',
                                        '${appState.prestige}',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Text(
                                'Build your own streak with Habitrail.',
                                textAlign: TextAlign.center,
                                style: HrText.bodyS.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: HrColors.text2,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              HrButton(
                label: _busy ? 'Preparing…' : 'Share',
                icon: Icons.ios_share_rounded,
                loading: _busy,
                onPressed: _busy ? null : _share,
              ),
              const SizedBox(height: 10),
              Text(
                'Share your card to show off your streak and level.',
                textAlign: TextAlign.center,
                style: HrText.caption,
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _shareStat(IconData icon, Color tint, String label, String value) =>
    Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1A20),
          borderRadius: BorderRadius.circular(HrRadius.md),
          border: Border.all(color: const Color(0xFF302E37)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 17, color: tint),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.headline.copyWith(color: HrColors.text),
            ),
            Text(label, style: HrText.micro),
          ],
        ),
      ),
    );

// ── FRIENDS & LEADERBOARD ────────────────────────────────────────────────────

// A ranked entry (you or a friend) for the leaderboard.
class _Ranked {
  _Ranked(
    this.name,
    this.totalXp,
    this.streak,
    this.borderId,
    this.isMe, {
    this.friendId,
  });
  final String name;
  final int totalXp;
  final int streak;
  final String borderId;
  final bool isMe;
  final String? friendId; // null for the current user
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  int _seg = 0;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, friends]),
      builder: (context, _) {
        // Leaderboard = you + your friends, ranked by total XP.
        final board = <_Ranked>[
          _Ranked(
            appState.displayName,
            appState.totalXp,
            appState.bestStreak,
            appState.selectedBorder,
            true,
          ),
          ...friends.friends.map(
            (f) => _Ranked(
              f.name,
              f.totalXp,
              f.streak,
              f.borderId,
              false,
              friendId: f.id,
            ),
          ),
        ]..sort((a, b) => b.totalXp.compareTo(a.totalXp));
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HrSpace.gutter,
                    4,
                    HrSpace.gutter,
                    0,
                  ),
                  child: Row(
                    children: [
                      Text('Friends', style: HrText.display),
                      const Spacer(),
                      Tooltip(
                        message: 'Global chat',
                        child: Material(
                          color: HrColors.surface2,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const GlobalChatScreen())),
                            child: const SizedBox(
                              width: 38,
                              height: 38,
                              child: Icon(Icons.forum_rounded,
                                  color: HrColors.text, size: 20),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Guilds',
                        child: Material(
                          color: HrColors.surface2,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const GuildsScreen())),
                            child: const SizedBox(
                              width: 38,
                              height: 38,
                              child: Icon(Icons.shield_rounded,
                                  color: HrColors.text, size: 20),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Party',
                        child: Material(
                          color: HrColors.surface2,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const PartyScreen())),
                            child: const SizedBox(
                              width: 38,
                              height: 38,
                              child: Icon(Icons.groups_rounded,
                                  color: HrColors.text, size: 20),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Add a friend',
                        child: Material(
                          color: HrColors.surface2,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() => _seg = 1),
                            child: const SizedBox(
                              width: 38,
                              height: 38,
                              child: Icon(
                                Icons.person_add_alt_1_rounded,
                                color: HrColors.text,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HrSpace.gutter,
                    10,
                    HrSpace.gutter,
                    10,
                  ),
                  child: HrSegmented(
                    items: const ['Leaderboard', 'Friends'],
                    index: _seg,
                    onChanged: (i) => setState(() => _seg = i),
                  ),
                ),
                Expanded(
                  child: _seg == 0
                      ? _leaderboardTab(context, board)
                      : _friendsTab(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _leaderboardTab(BuildContext context, List<_Ranked> board) {
    final myXp = appState.totalXp;
    final myIndex = board.indexWhere((entry) => entry.isMe);
    final rank = myIndex >= 0 ? myIndex + 1 : board.length + 1;
    final isLeading = rank == 1;
    final opponent = isLeading
        ? (board.length > 1 ? board[1] : null)
        : (board.isNotEmpty ? board.first : null);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        4,
        HrSpace.gutter,
        100,
      ),
      children: [
        _podium(context, board),
        const SizedBox(height: 16),
        _leaderboardStatusCard(
          rank: rank,
          myXp: myXp,
          opponent: opponent,
          isLeading: isLeading,
        ),
        const SizedBox(height: 22),
        for (int i = 0; i < board.length; i++)
          _leaderRow(context, i + 1, board[i]),
      ],
    );
  }

  Widget _leaderboardStatusCard({
    required int rank,
    required int myXp,
    required _Ranked? opponent,
    required bool isLeading,
  }) {
    final gap = opponent == null ? 0 : (opponent.totalXp - myXp).abs();
    final targetXp = opponent?.totalXp ?? myXp;
    final progress = isLeading || targetXp <= 0
        ? 1.0
        : (myXp / targetXp).clamp(0.0, 1.0).toDouble();
    final lead = opponent == null
        ? (isLeading ? "You're leading—" : 'Keep climbing—')
        : isLeading
        ? "You're ${_groupedNum(gap)} XP ahead of ${opponent.name}—"
        : '${opponent.name} is ${_groupedNum(gap)} XP ahead—';
    final nudge = isLeading ? 'keep it going!' : 'catch up!';
    final comparison = opponent == null
        ? 'You: ${_groupedNum(myXp)} XP'
        : isLeading
        ? 'You: ${_groupedNum(myXp)} XP · Next: ${opponent.name} ${_groupedNum(opponent.totalXp)} XP'
        : 'You: ${_groupedNum(myXp)} XP · ${opponent.name}: ${_groupedNum(opponent.totalXp)} XP';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B1A2B), Color(0xFF10111A)],
        ),
        borderRadius: BorderRadius.circular(HrRadius.lg),
        border: Border.all(color: HrColors.cardEdge, width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x44000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.star_rounded,
                  size: 38,
                  color: HrColors.gold,
                  shadows: [
                    Shadow(
                      color: HrColors.gold.withValues(alpha: 0.28),
                      blurRadius: 8,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '#$rank',
                    style: const TextStyle(
                      color: Color(0xFF302400),
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#$rank IN THE RACE',
                  style: HrText.micro.copyWith(
                    color: HrColors.gold.withValues(alpha: 0.88),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                  ),
                ),
                const SizedBox(height: 3),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: lead,
                        style: HrText.body.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: nudge,
                        style: HrText.body.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          fontStyle: FontStyle.italic,
                          color: const Color(0xFFC08BFF),
                        ),
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(HrRadius.full),
                  child: SizedBox(
                    height: 6,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: HrColors.surface3),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: constraints.maxWidth * progress,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFFA44DFF),
                                    Color(0xFF36C9F4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  comparison,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.micro.copyWith(color: HrColors.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _groupedNum(int value) => value.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );

  Widget _friendsTab(BuildContext context) {
    final list = friends.friends;
    final suggestions = friends.suggestions();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        4,
        HrSpace.gutter,
        100,
      ),
      children: [
        const _AddFriendField(),
        const SizedBox(height: 16),
        if (list.isEmpty)
          _friendsEmpty(context)
        else ...[
          HrLabel('Your friends · ${list.length}'),
          ...list.map((f) => _friendCard(context, f)),
        ],
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 10),
          const HrLabel('Suggested'),
          ...suggestions.map((f) => _suggestionCard(context, f)),
        ],
      ],
    );
  }

  Widget _friendsEmpty(BuildContext context) {
    final comp = companionByType(appState.activeCompanion);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        children: [
          CompanionSticker(
            icon: comp.icon,
            color: comp.color,
            size: 72,
            semanticLabel: comp.name,
            imageAsset: comp.imageAsset,
          ),
          const SizedBox(height: 14),
          const SpeechBubble(
            'Habits are easier with witnesses.',
            maxWidth: 240,
          ),
          const SizedBox(height: 20),
          Text('No friends yet', style: HrText.title2),
          const SizedBox(height: 6),
          Text(
            'Add a friend by username to compare XP and streaks.',
            textAlign: TextAlign.center,
            style: HrText.bodyS,
          ),
        ],
      ),
    );
  }
}

// Avatar for an arbitrary name + border (friends have no photo of their own).
class _FriendAvatar extends StatelessWidget {
  const _FriendAvatar({
    required this.name,
    required this.borderId,
    this.size = 44,
    this.showBorder = true,
  });
  final String name;
  final String borderId;
  final double size;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final b = borderById(borderId);
    final hasBorder = showBorder && b.id != 'none';
    final ringW = hasBorder
        ? (size * 0.1).clamp(3.0, 6.0)
        : (size * 0.06).clamp(2.0, 4.0);
    final frameAsset = showBorder ? b.frameAsset : null;
    final inner = frameAsset != null
        ? size * 0.72
        : (showBorder ? size - ringW * 2 : size);
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final avatar = ClipOval(
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [kPlasma, kBlue]),
        ),
        child: Text(
          letter,
          style: TextStyle(fontFamily: kHrFont,
            color: Colors.white,
            fontSize: inner * 0.42,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    if (!showBorder) {
      return SizedBox(width: size, height: size, child: avatar);
    }
    if (frameAsset != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(width: inner, height: inner, child: avatar),
            Image.asset(
              frameAsset,
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ],
        ),
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
                  color: b.colors.first.withValues(alpha: 0.6),
                  blurRadius: size * 0.22,
      ),
              ]
            : null,
          ),
      child: avatar,
    );
  }
}

Widget _youTag() => Container(
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(
    color: HrColors.accent.withValues(alpha: 0.22),
    borderRadius: BorderRadius.circular(HrRadius.xs),
  ),
  child: Text(
    'YOU',
    style: HrText.micro.copyWith(
      color: HrColors.accent,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
    ),
  ),
);

// Gold PREMIUM chip shown next to a Premium member on the leaderboard.
Widget _premiumTag() => Container(
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(
    color: HrColors.gold.withValues(alpha: 0.22),
    borderRadius: BorderRadius.circular(HrRadius.xs),
  ),
  child: Text(
    'PREMIUM',
    style: HrText.micro.copyWith(
      color: HrColors.gold,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
    ),
  ),
);

// Top-three leaderboard profiles, shown without a podium backdrop.
Widget _podium(BuildContext context, List<_Ranked> board) {
  final top = board.take(3).toList();
  _Ranked? at(int r) => top.length >= r ? top[r - 1] : null;
  const order = [2, 1, 3];
  void openProfile(_Ranked? entry) {
    if (entry?.friendId == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(friendId: entry!.friendId!),
      ),
    );
  }

  Widget avatarFor(int rank, double size) {
    final entry = at(rank);
    if (entry == null) return SizedBox(width: size, height: size);
    final avatar = entry.isMe
        ? _Avatar(size: size, showBorder: false)
        : _FriendAvatar(
            name: entry.name,
            borderId: entry.borderId,
            size: size,
            showBorder: false,
          );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openProfile(entry),
      child: avatar,
    );
  }

  Color rankColor(int rank) => switch (rank) {
    1 => HrColors.gold,
    2 => HrColors.text2,
    _ => const Color(0xFFD98A5A),
  };

  Widget rankSummary(int rank) {
    final entry = at(rank);
    if (entry == null) return const Expanded(child: SizedBox.shrink());
    final label = switch (rank) {
      1 => '1ST',
      2 => '2ND',
      _ => '3RD',
    };
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openProfile(entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: HrText.micro.copyWith(
                  fontSize: 12,
                  height: 16 / 12,
                  color: rankColor(rank),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                entry.isMe ? 'You' : entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: HrText.caption.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
              ),
              ),
              Text(
                '${entry.totalXp} XP',
                style: HrText.micro.copyWith(
                  fontSize: 12,
                  height: 16 / 12,
                  color: HrColors.text2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = width * 1024 / 1792;
          // The transparent 16:9 asset lets the black app background show
          // around the carved stands. Position avatar centers within each ring.
          final d1 = width * 0.158;
          final d2 = width * 0.148;
          final d3 = width * 0.136;
          return SizedBox(
            width: width,
            height: height,
            child: Stack(
              children: [
                Image.asset(
                  'assets/leaderboard/podium_stands_clean.png',
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                  semanticLabel: 'Three 3D leaderboard podium stands',
                ),
                Positioned(
                  left: width * 0.488 - d1 / 2,
                  top: height * 0.264 - d1 / 2,
                  child: avatarFor(1, d1),
                ),
                Positioned(
                  left: width * 0.180 - d2 / 2,
                  top: height * 0.317 - d2 / 2,
                  child: avatarFor(2, d2),
                ),
                Positioned(
                  left: width * 0.818 - d3 / 2,
                  top: height * 0.413 - d3 / 2,
                  child: avatarFor(3, d3),
                ),
              ],
            ),
          );
        },
      ),
      const SizedBox(height: 4),
      Row(children: [for (final rank in order) rankSummary(rank)]),
    ],
  );
}

Widget _leaderRow(BuildContext context, int rank, _Ranked e) {
  final ld = levelFromXp(e.totalXp);
  final rankColor = switch (rank) {
    1 => HrColors.gold,
    2 => HrColors.text2,
    3 => const Color(0xFFD98A5A),
    _ => HrColors.text3,
  };
  final topThree = rank <= 3;
  final row = Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: e.isMe
            ? [HrColors.accentSurface, HrColors.surface]
            : [HrColors.surface2, HrColors.surface],
      ),
      borderRadius: BorderRadius.circular(HrRadius.md),
      border: Border.all(
        color: e.isMe
            ? HrColors.accent.withValues(alpha: 0.72)
            : topThree
            ? rankColor.withValues(alpha: rank == 1 ? 0.42 : 0.26)
            : HrColors.cardEdge,
        width: e.isMe ? 1.4 : 0.8,
      ),
      boxShadow: !e.isMe && rank == 1
          ? [
              BoxShadow(
                color: rankColor.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ]
          : null,
    ),
    child: Row(
      children: [
        SizedBox(
          width: 28,
          height: 30,
          child: topThree
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      Icons.hexagon_rounded,
                      size: 27,
                      color: rankColor.withValues(alpha: 0.16),
                    ),
                    Icon(
                      Icons.hexagon_outlined,
                      size: 27,
                      color: rankColor.withValues(alpha: 0.55),
                    ),
                    Text(
                      '$rank',
                      style: HrText.caption.copyWith(
                        color: rankColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                )
              : Center(
          child: Text(
            '$rank',
            textAlign: TextAlign.center,
                    style: HrText.body.copyWith(
                      color: HrColors.text3,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
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
              Row(
                children: [
                  Flexible(
                    child: Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (e.isMe) ...[const SizedBox(width: 6), _youTag()],
                  if (e.isMe && appState.isPremium) ...[
                    const SizedBox(width: 6),
                    _premiumTag(),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Lv ${ld.level} · ${levelTitle(ld.level)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HrText.caption,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (e.streak > 0) ...[
          StreakPill(count: e.streak, quiet: true, leaderboard: true),
          const SizedBox(width: 10),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${e.totalXp}',
              style: HrText.body.copyWith(
                color: topThree ? rankColor : HrColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text('XP', style: HrText.micro),
          ],
        ),
      ],
    ),
  );
  return e.friendId == null
      ? row
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FriendProfileScreen(friendId: e.friendId!),
            ),
          ),
          child: row,
        );
}

Widget _friendCard(BuildContext context, Friend f) {
  final ld = levelFromXp(f.totalXp);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FriendProfileScreen(friendId: f.id)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        children: [
          _FriendAvatar(name: f.name, borderId: f.borderId, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (f.prestige > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '★${f.prestige}',
                        style: HrText.caption.copyWith(
                          color: HrColors.gold,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '@${f.username} · Lv ${ld.level}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (f.streak > 0) StreakPill(count: f.streak, quiet: true),
          IconButton(
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: HrColors.text3,
              size: 20,
            ),
            tooltip: 'Remove',
            onPressed: () => _confirmRemoveFriend(context, f),
          ),
        ],
      ),
    ),
  );
}

Widget _suggestionCard(BuildContext context, Friend f) {
  final ld = levelFromXp(f.totalXp);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          _FriendAvatar(name: f.name, borderId: f.borderId, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '@${f.username} · Lv ${ld.level}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          HrButton(
            label: 'Add',
            icon: Icons.add_rounded,
            kind: HrButtonKind.secondary,
            small: true,
            expand: false,
            onPressed: () async {
              final err = await friends.addByUsername(f.username);
              if (!context.mounted) return;
              _toast(context, err ?? 'Added @${f.username}');
            },
          ),
        ],
      ),
    ),
  );
}

void _confirmRemoveFriend(BuildContext context, Friend f) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kElevated,
      title: Text(
        'Remove ${f.name}?',
        style: const TextStyle(color: kTextPrimary),
      ),
      content: Text(
        'You can add @${f.username} again any time.',
        style: const TextStyle(color: kTextSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
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
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _c,
            onSubmitted: (_) => _add(),
            textInputAction: TextInputAction.done,
            style: HrText.body,
            decoration: InputDecoration(
              hintText: 'Add by username',
              hintStyle: HrText.body.copyWith(color: HrColors.text3),
              filled: true,
              fillColor: HrColors.surface,
              prefixIcon: const Icon(
                Icons.alternate_email_rounded,
                size: 18,
                color: HrColors.text3,
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 14,
                horizontal: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(HrRadius.md),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(HrRadius.md),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(HrRadius.md),
                borderSide: const BorderSide(color: HrColors.text, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 76,
          child: HrButton(label: 'Add', small: true, onPressed: _add),
        ),
      ],
    );
  }
}

Widget _profileStat(String value, String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
  decoration: BoxDecoration(
    color: HrColors.surface,
    borderRadius: BorderRadius.circular(HrRadius.md),
    border: const Border(top: BorderSide(color: HrColors.hairline)),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: HrText.stat.copyWith(color: color),
      ),
      const SizedBox(height: 2),
      Text(label, style: HrText.caption),
    ],
  ),
);

Widget _compareBar(double frac, Color color) => ClipRRect(
  borderRadius: BorderRadius.circular(HrRadius.full),
  child: LinearProgressIndicator(
    value: frac.clamp(0.0, 1.0),
    minHeight: 6,
    backgroundColor: HrColors.surface2,
    valueColor: AlwaysStoppedAnimation(color),
  ),
);

// Friend value (grey) over your value (accent), scaled to the larger of the two.
Widget _compareRow(String label, int friendVal, int myVal) {
  final peak = friendVal > myVal ? friendVal : myVal;
  final denom = peak <= 0 ? 1.0 : peak.toDouble();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(child: Text(label, style: HrText.caption)),
          Text(
            '$friendVal',
            style: HrText.caption.copyWith(
              color: HrColors.text2,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text('  vs  ', style: HrText.caption),
          Text(
            '$myVal',
            style: HrText.caption.copyWith(
              color: HrColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      _compareBar(friendVal / denom, HrColors.text3),
      const SizedBox(height: 5),
      _compareBar(myVal / denom, HrColors.accent),
    ],
  );
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
              foregroundColor: kTextPrimary,
            ),
            body: const Center(
              child: Text(
                'This friend was removed.',
                style: TextStyle(color: kTextTertiary),
              ),
            ),
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
            foregroundColor: HrColors.text,
            elevation: 0,
            title: HrAppBarTitle(f.name),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              32,
            ),
            children: [
              Column(
                children: [
                  _FriendAvatar(name: f.name, borderId: f.borderId, size: 96),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HrText.title1,
                        ),
                      ),
                      if (f.prestige > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '★${f.prestige}',
                          style: HrText.title2.copyWith(color: HrColors.gold),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@${f.username} · Lv ${ld.level} · ${levelTitle(ld.level)}',
                    style: HrText.caption,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _profileStat('${ld.level}', 'Level', HrColors.text),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _profileStat(
                      '${f.streak}',
                      'Streak',
                      HrColors.streak,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _profileStat('#$rank', 'Rank', HrColors.accent),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              HrCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HrLabel('Compared to you'),
                    _compareRow('Total XP', f.totalXp, myXp),
                    const SizedBox(height: 12),
                    _compareRow('Streak', f.streak, appState.bestStreak),
                    const SizedBox(height: 12),
                    _compareRow('Level', ld.level, levelFromXp(myXp).level),
                    const SizedBox(height: 14),
                    Text(cmp, style: HrText.bodyS),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              HrButton(
                label: 'Send a nudge',
                icon: Icons.bolt_rounded,
                onPressed: () => _toast(context, 'Nudged ${f.name}!'),
              ),
              const SizedBox(height: 10),
              HrButton(
                label: 'Remove friend',
                kind: HrButtonKind.danger,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: HrColors.surface,
                    title: Text('Remove ${f.name}?', style: HrText.title2),
                    content: Text(
                      'You can add @${f.username} again any time.',
                      style: HrText.bodyS,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: HrColors.danger,
                        ),
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
    final unlocked = kAchievements
        .where((a) => appState.isAchievementEarned(a))
        .length;
    final total = kAchievements.length;
    final allDone = unlocked >= total;
    final next = kAchievements.firstWhere(
      (a) => !appState.isAchievementEarned(a),
      orElse: () => kAchievements.last,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        4,
        HrSpace.gutter,
        100,
      ),
      children: [
        HrCard(
          child: Row(
            children: [
              SegmentedRing(
                size: 64,
                segments: 1,
                value: total == 0 ? 0 : unlocked / total,
                stroke: 7,
                color: HrColors.gold,
                center: Text('$unlocked', style: HrText.title2),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$unlocked of $total unlocked',
                      style: HrText.headline,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      allDone ? 'Every award earned.' : 'Next: ${next.title}',
                      style: HrText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.95,
          children: kAchievements.map((a) => _AchievementCard(a)).toList(),
        ),
      ],
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard(this.a);
  final Achievement a;

  @override
  Widget build(BuildContext context) {
    final on = appState.isAchievementEarned(a);
    final color = HrColors.rarity[a.rarity] ?? HrColors.text3;
    final rarity = '${a.rarity[0].toUpperCase()}${a.rarity.substring(1)}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            on ? color.withValues(alpha: 0.13) : HrColors.surface2,
            HrColors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(HrRadius.lg),
        border: Border.all(
          color: on ? color.withValues(alpha: 0.68) : HrColors.cardEdge,
          width: on ? 1.3 : 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: (on ? color : HrColors.accent).withValues(alpha: on ? 0.13 : 0.045),
            blurRadius: on ? 18 : 10,
            offset: const Offset(0, 6),
          ),
          const BoxShadow(
            color: Color(0x55000000),
            blurRadius: 8,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Opacity(
                    opacity: on ? 1 : 0.45,
                    child: Image.asset(a.imageAsset, fit: BoxFit.contain),
                  ),
                ),
                if (!on)
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: HrColors.surface2,
                        shape: BoxShape.circle,
                        border: Border.all(color: HrColors.hairline),
                      ),
                      child: const Icon(
                        Icons.lock_rounded,
                        size: 12,
                        color: HrColors.text2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            a.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HrText.bodyS.copyWith(
              color: on ? HrColors.text : HrColors.text2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          on
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(HrRadius.xs),
                  ),
                  child: Text(
                    rarity.toUpperCase(),
                    style: HrText.micro.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                )
              : Text(
                  a.description,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.micro,
                ),
        ],
      ),
    );
  }
}

// ── JOURNAL ─────────────────────────────────────────────────────────────────
String _journalDate(String key) {
  final d = DateTime.tryParse(key);
  if (d == null) return key;
  return '${_kWeekdays[d.weekday - 1].substring(0, 3)} · ${_kMonths[d.month - 1]} ${d.day}';
}

// Long-press a journal entry → Edit / Delete.
Future<void> _showJournalMenu(BuildContext context, Reflection r) async {
  HapticFeedback.selectionClick();
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: HrColors.surface3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Row(children: [
              Expanded(
                child: Text(_journalDate(r.date),
                    style: HrText.title2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          ListTile(
            leading: Icon(Icons.edit_rounded, color: HrColors.accent),
            title: Text('Edit reflection', style: HrText.body),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded,
                color: HrColors.dangerText),
            title: Text('Delete reflection',
                style: HrText.body.copyWith(color: HrColors.dangerText)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );
  if (action == 'edit') {
    if (context.mounted) await showAddReflection(context, existing: r);
  } else if (action == 'delete') {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text('Delete reflection?', style: HrText.title2),
        content: Text('This removes the entry for ${_journalDate(r.date)}.',
            style: HrText.bodyS),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: HrText.caption),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: HrText.body.copyWith(color: HrColors.dangerText)),
          ),
        ],
      ),
    );
    if (ok == true) {
      appState.deleteReflection(r);
      if (context.mounted) {
        hrToast(context, 'Reflection deleted',
            icon: Icons.delete_outline_rounded);
      }
    }
  }
}

class JournalScreen extends StatefulWidget {
  const JournalScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final items = appState.reflections;
    final today = dateKey(DateTime.now());
    final reflectedToday = items.any((r) => r.date == today);
    final visibleItems = _showAll ? items : items.take(2).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        8,
        HrSpace.gutter,
        100,
      ),
      children: [
        _TodayReflectionCard(
          reflectedToday: reflectedToday,
          onWrite: () => showAddReflection(context),
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Recent entries', style: HrText.title2),
            const Spacer(),
            if (items.length > 2)
              TextButton(
                onPressed: () => setState(() => _showAll = !_showAll),
                style: TextButton.styleFrom(
                  foregroundColor: HrColors.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(40, 36),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_showAll ? 'Show less' : 'View all',
                        style: HrText.caption.copyWith(
                          color: HrColors.accent,
                          fontWeight: FontWeight.w700,
                        )),
                    const SizedBox(width: 3),
                    Icon(
                      _showAll
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: HrColors.accent,
                    ),
                  ],
                ),
              )
            else
              Text(
                '${items.length} ${items.length == 1 ? 'entry' : 'entries'}',
                style: HrText.micro,
              ),
          ],
        ),
        const SizedBox(height: 11),
        if (items.isEmpty)
          HrCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 23),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: HrColors.accent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.auto_stories_rounded,
                      color: HrColors.accent, size: 21),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your story starts here', style: HrText.headline),
                      const SizedBox(height: 4),
                      Text(
                        'Your first reflection will appear here.',
                        style: HrText.caption,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          ...visibleItems.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 11),
              child: _JournalEntryCard(
                reflection: r,
                onMenu: () => _showJournalMenu(context, r),
              ),
            ),
          ),
      ],
    );
  }
}

class _TodayReflectionCard extends StatelessWidget {
  const _TodayReflectionCard({
    required this.reflectedToday,
    required this.onWrite,
  });

  final bool reflectedToday;
  final VoidCallback onWrite;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final weekday = _kWeekdays[now.weekday - 1].substring(0, 3).toUpperCase();
    final month = _kMonths[now.month - 1].toUpperCase();
    final buttonWidth = (MediaQuery.sizeOf(context).width - 96).clamp(218.0, 256.0);

    return Container(
      height: 230,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HrRadius.lg),
        border: Border.all(color: const Color(0xFF65518C).withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: HrColors.accent.withValues(alpha: 0.08),
            blurRadius: 24,
            spreadRadius: -9,
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _JournalLandscapePainter(HrColors.accent)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xF2181720),
                  Color(0xD4181720),
                  Color(0x50181720),
                ],
                stops: [0, 0.58, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$weekday · $month ${now.day}',
                      style: HrText.labelCaps.copyWith(
                        color: const Color(0xFFC3B9DE),
                        letterSpacing: 1.25,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xAA241F2E),
                        borderRadius: BorderRadius.circular(HrRadius.full),
                        border: Border.all(
                            color: HrColors.gold.withValues(alpha: 0.45)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star_rounded,
                              size: 15, color: HrColors.gold),
                          const SizedBox(width: 4),
                          Text(
                            '+20 XP',
                            style: HrText.micro.copyWith(
                              color: const Color(0xFFFFD779),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  "Today's reflection",
                  style: HrText.title1.copyWith(fontSize: 23),
                ),
                const SizedBox(height: 5),
                Text(
                  reflectedToday
                      ? 'Anything else you want to remember?'
                      : 'What felt like a win today?',
                  style: HrText.bodyS.copyWith(
                    color: const Color(0xFFCDC8DA),
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: buttonWidth,
                  child: HrButton(
                    label: reflectedToday ? 'Add reflection' : 'Write reflection',
                    icon: Icons.edit_rounded,
                    kind: HrButtonKind.accent,
                    onPressed: onWrite,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _JournalEntryCard extends StatelessWidget {
  const _JournalEntryCard({
    required this.reflection,
    required this.onMenu,
  });

  final Reflection reflection;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final moodColor = reflection.mood > 0
        ? HrColors.victory((reflection.mood * 10).clamp(0, 100))
        : HrColors.text3;
    final moodIcon = reflection.mood >= 8
        ? Icons.sentiment_very_satisfied_rounded
        : reflection.mood >= 5
            ? Icons.sentiment_satisfied_rounded
            : Icons.sentiment_neutral_rounded;
    final metrics = <({String label, int value, IconData icon, Color color})>[
      (label: 'Day', value: reflection.day, icon: Icons.calendar_today_rounded, color: HrColors.accent),
      (label: 'Energy', value: reflection.energy, icon: Icons.bolt_rounded, color: HrColors.gold),
      (label: 'Mood', value: reflection.mood, icon: moodIcon, color: moodColor),
      (label: 'Focus', value: reflection.focus, icon: Icons.center_focus_strong_rounded, color: const Color(0xFFAD91FF)),
    ].where((metric) => metric.value > 0).toList();
    // Journal score = the four self-ratings, each /10, summed out of 40.
    final ratingScore =
        reflection.day + reflection.energy + reflection.mood + reflection.focus;
    final rated = metrics.isNotEmpty;
    final scoreColor = HrColors.victory((ratingScore / 40 * 100).round());

    return HrCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _journalDate(reflection.date).toUpperCase(),
                style: HrText.labelCaps.copyWith(
                  color: const Color(0xFFAAA5B7),
                  letterSpacing: 1,
                ),
              ),
              if (reflection.mood > 0) ...[
                const SizedBox(width: 9),
                Icon(moodIcon, color: moodColor, size: 19),
              ],
              const Spacer(),
              if (rated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: scoreColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(HrRadius.full),
                    border:
                        Border.all(color: scoreColor.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, color: scoreColor, size: 14),
                      const SizedBox(width: 3),
                      Text(
                        'Score $ratingScore/40',
                        style: HrText.micro.copyWith(
                          color: scoreColor,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              IconButton(
                onPressed: onMenu,
                tooltip: 'Edit or delete entry',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_vert_rounded,
                    size: 19, color: HrColors.text3),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            reflection.text.isEmpty ? 'A day recorded in your journal.' : reflection.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HrText.body.copyWith(
              color: reflection.text.isEmpty ? HrColors.text3 : HrColors.text,
              height: 1.38,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (metrics.isNotEmpty) ...[
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 18) / 4;
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: metrics
                      .map((metric) => _journalMetricTile(
                            metric.label,
                            metric.value,
                            metric.icon,
                            metric.color,
                            width,
                          ))
                      .toList(),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

Widget _journalMetricTile(
  String label,
  int value,
  IconData icon,
  Color color,
  double width,
) =>
    Container(
      width: width,
      height: 60,
      padding: const EdgeInsets.fromLTRB(7, 6, 6, 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.micro.copyWith(fontSize: 9.5),
                ),
              ),
            ],
          ),
          Text(
            '$value',
            style: HrText.stat.copyWith(
              fontSize: 18,
              height: 1,
              color: color,
            ),
          ),
        ],
      ),
    );

class _JournalLandscapePainter extends CustomPainter {
  const _JournalLandscapePainter(this.accent);

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final moonCenter = Offset(w * 0.81, h * 0.46);
    canvas.drawCircle(
      moonCenter,
      12,
      Paint()
        ..color = const Color(0xFFFFD895).withValues(alpha: 0.88)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawCircle(
      moonCenter,
      8,
      Paint()..color = const Color(0xFFFFE5AF),
    );

    final stars = <Offset>[
      Offset(w * 0.68, h * 0.21),
      Offset(w * 0.87, h * 0.16),
      Offset(w * 0.94, h * 0.38),
      Offset(w * 0.61, h * 0.42),
      Offset(w * 0.75, h * 0.29),
    ];
    for (var i = 0; i < stars.length; i++) {
      canvas.drawCircle(
        stars[i],
        i == 1 ? 1.5 : 1,
        Paint()..color = Colors.white.withValues(alpha: i == 2 ? 0.76 : 0.5),
      );
    }

    final farMountain = Path()
      ..moveTo(w * 0.38, h)
      ..lineTo(w * 0.54, h * 0.63)
      ..lineTo(w * 0.64, h * 0.72)
      ..lineTo(w * 0.77, h * 0.48)
      ..lineTo(w * 0.87, h * 0.62)
      ..lineTo(w, h * 0.43)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(
      farMountain,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF39314F), Color(0xFF24202F)],
        ).createShader(Offset.zero & size),
    );

    final nearMountain = Path()
      ..moveTo(w * 0.34, h)
      ..lineTo(w * 0.57, h * 0.78)
      ..lineTo(w * 0.71, h * 0.88)
      ..lineTo(w * 0.85, h * 0.71)
      ..lineTo(w, h * 0.8)
      ..lineTo(w, h)
      ..close();
    canvas.drawPath(
      nearMountain,
      Paint()..color = const Color(0xFF17171F),
    );

    final river = Path()
      ..moveTo(w * 0.77, h * 0.74)
      ..cubicTo(w * 0.68, h * 0.8, w * 0.9, h * 0.83, w * 0.77, h * 0.9)
      ..cubicTo(w * 0.68, h * 0.95, w * 0.86, h * 0.96, w * 0.82, h);
    canvas.drawPath(
      river,
      Paint()
        ..color = const Color(0xFFFFC868).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );

    final accentGlow = Paint()
      ..shader = RadialGradient(
        colors: [accent.withValues(alpha: 0.13), Colors.transparent],
      ).createShader(Rect.fromCircle(
        center: Offset(w * 0.82, h * 0.86),
        radius: w * 0.35,
      ));
    canvas.drawCircle(Offset(w * 0.82, h * 0.86), w * 0.35, accentGlow);
  }

  @override
  bool shouldRepaint(covariant _JournalLandscapePainter oldDelegate) =>
      oldDelegate.accent != accent;
}

// ── Shared bits ─────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.emoji,
    required this.title,
    required this.subtitle,
  });
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
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 36)),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: kHrFont,
                color: kTextPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kTextTertiary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showLevelUp(BuildContext context, int level) {
  _showMoment(
    context,
    label: 'Level Up',
    labelColor: HrColors.gold,
    emblem: _LevelUpEmblem(level: level),
    title: levelTitle(level),
    subtitle: 'Level $level reached',
    bubble: companionLine(appState.activeCompanion, 'level_up'),
    buttonLabel: 'Continue',
  );
}

class _LevelUpEmblem extends StatelessWidget {
  const _LevelUpEmblem({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 164,
        height: 164,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 154,
              height: 154,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    HrColors.accent.withValues(alpha: 0.19),
                    HrColors.accent.withValues(alpha: 0.07),
                    Colors.transparent,
                  ],
                  stops: const [0.15, 0.58, 1],
                ),
              ),
            ),
            CustomPaint(
              size: const Size.square(150),
              painter: _LevelUpOrbitPainter(HrColors.accent),
            ),
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF414149), Color(0xFF202024), Color(0xFF151517)],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 18,
                    offset: const Offset(0, 9),
                  ),
                  BoxShadow(
                    color: HrColors.accent.withValues(alpha: 0.24),
                    blurRadius: 23,
                    spreadRadius: -4,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'LEVEL',
                    style: HrText.micro.copyWith(
                      color: HrColors.text2,
                      letterSpacing: 2.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, HrColors.accent],
                    ).createShader(bounds),
                    child: Text(
                      '$level',
                      style: HrText.numeralXl.copyWith(
                        fontSize: 57,
                        color: Colors.white,
                        shadows: const [
                          Shadow(color: Colors.black38, offset: Offset(0, 3), blurRadius: 5),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _LevelUpOrbitPainter extends CustomPainter {
  const _LevelUpOrbitPainter(this.accent);

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.16);
    canvas.drawCircle(center, 68, ring);

    for (var i = 0; i < 32; i++) {
      final angle = (i * 2 * pi / 32) - pi / 2;
      final major = i % 4 == 0;
      final inner = major ? 62.0 : 64.5;
      final outer = major ? 72.0 : 69.5;
      final start = Offset(
        center.dx + cos(angle) * inner,
        center.dy + sin(angle) * inner,
      );
      final end = Offset(
        center.dx + cos(angle) * outer,
        center.dy + sin(angle) * outer,
      );
      final tick = Paint()
        ..color = (major ? HrColors.gold : accent)
            .withValues(alpha: major ? 0.95 : 0.48)
        ..strokeWidth = major ? 2.4 : 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(start, end, tick);
    }

    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          accent.withValues(alpha: 0.05),
          accent.withValues(alpha: 0.9),
          HrColors.gold.withValues(alpha: 0.9),
          accent.withValues(alpha: 0.05),
        ],
        stops: const [0, 0.34, 0.7, 1],
      ).createShader(Rect.fromCircle(center: center, radius: 57));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 57),
      -pi * 0.88,
      pi * 1.64,
      false,
      highlight,
    );

    for (var i = 0; i < 4; i++) {
      final angle = (i * pi / 2) - pi / 4;
      final sparkle = Offset(
        center.dx + cos(angle) * 76,
        center.dy + sin(angle) * 76,
      );
      canvas.drawCircle(
        sparkle,
        i.isEven ? 2.4 : 1.6,
        Paint()..color = (i.isEven ? HrColors.gold : accent).withValues(alpha: 0.95),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LevelUpOrbitPainter oldDelegate) =>
      oldDelegate.accent != accent;
}

void _showAchievementUnlocked(BuildContext context, List<Achievement> items) {
  if (items.isEmpty) return;
  final a = items.first;
  final color = HrColors.rarity[a.rarity] ?? HrColors.gold;
  _showMoment(
    context,
    label: 'Achievement unlocked',
    labelColor: color,
    emblem: Container(
      width: 112,
      height: 112,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 3),
      ),
      child: Image.asset(a.imageAsset, fit: BoxFit.cover),
    ),
    title: a.title,
    subtitle: items.length > 1
        ? '${a.description}\n+${items.length - 1} more unlocked'
        : a.description,
    buttonLabel: 'Nice',
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

// Long-press on a habit → a compact "Edit / Delete" action sheet.
Future<void> _showHabitMenu(BuildContext context, Habit h) async {
  HapticFeedback.selectionClick();
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: HrColors.surface3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    h.icon.isEmpty ? h.name : '${h.icon}  ${h.name}',
                    style: HrText.title2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(Icons.edit_rounded, color: HrColors.accent),
            title: Text('Edit habit', style: HrText.body),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(
              Icons.delete_outline_rounded,
              color: HrColors.dangerText,
            ),
            title: Text(
              'Delete habit',
              style: HrText.body.copyWith(color: HrColors.dangerText),
            ),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );
  if (action == 'edit') {
    if (context.mounted) await showHabitEditor(context, h);
  } else if (action == 'delete') {
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HrColors.surface,
        title: Text('Delete habit?', style: HrText.title2),
        content: Text(
          '"${h.name}" and its streak will be removed.',
          style: HrText.bodyS,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: HrText.caption),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: HrText.body.copyWith(color: HrColors.dangerText),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      appState.deleteHabit(h);
      if (context.mounted) {
        hrToast(context, 'Habit removed', icon: Icons.delete_outline_rounded);
      }
    }
  }
}

Future<void> showHabitEditor(BuildContext context, [Habit? existing]) async {
  final controller = TextEditingController(text: existing?.name ?? '');
  // The current difficulty decision — the AI (or heuristic) owns this; the user
  // no longer picks it. It's frozen onto the habit when they tap Add/Save.
  DifficultyVerdict verdict = existing != null
      ? DifficultyVerdict(
          existing.rarity,
          existing.difficultyReason,
          fromAi: existing.aiRated,
        )
      : heuristicVerdict(controller.text);
  bool analyzing = false;
  Timer? debounce;
  int reqSeq = 0; // drops stale async results from earlier keystrokes
  String icon = existing?.icon ?? '';
  // The AI auto-picks an emoji from the name; a manual tap on the grid locks it.
  bool iconManual = existing != null && existing.icon.isNotEmpty;
  int? reminderMinutes = existing?.reminderMinutes; // daily reminder time
  const emojis = [
    '💧',
    '📖',
    '🏋️',
    '😴',
    '🧘',
    '🏃',
    '🥗',
    '💻',
    '🎯',
    '✍️',
    '🎸',
    '☀️',
    '🧠',
    '💰',
    '🌱',
    '🚭',
  ];
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: HrColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Re-rate the habit: show the instant heuristic now, then let the local
        // Ollama model refine it shortly after the user stops typing.
        void analyze(String name) {
          debounce?.cancel();
          final instant = heuristicVerdict(name);
          final trimmed = name.trim();
          if (trimmed.isEmpty) {
            setLocal(() {
              verdict = instant;
              analyzing = false;
            });
            return;
          }
          // AI off: still auto-assign a fitting emoji via the keyword heuristic.
          if (!appState.aiEnabled) {
            setLocal(() {
              verdict = instant;
              if (!iconManual) icon = heuristicEmoji(trimmed);
              analyzing = false;
            });
            return;
          }
          final seq = ++reqSeq;
          setLocal(() {
            verdict = instant;
            if (!iconManual && icon.isEmpty) icon = heuristicEmoji(trimmed);
            analyzing = true;
          });
          debounce = Timer(const Duration(milliseconds: 650), () async {
            // Classify difficulty and pick an emoji concurrently; the emoji
            // call is skipped once the user has locked one manually.
            final fv = classifyDifficulty(
              name,
              enabled: appState.aiEnabled,
              baseUrl: appState.aiBaseUrl,
              model: appState.aiModel,
            );
            final fe = iconManual
                ? Future<String>.value('')
                : aiHabitEmoji(
                    name,
                    enabled: appState.aiEnabled,
                    baseUrl: appState.aiBaseUrl,
                    model: appState.aiModel,
                  );
            final v = await fv;
            final e = await fe;
            if (!ctx.mounted || seq != reqSeq) return;
            setLocal(() {
              verdict = v;
              if (!iconManual && e.isNotEmpty) icon = e;
              analyzing = false;
            });
          });
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: HrColors.surface3,
                    borderRadius: BorderRadius.circular(2),
                ),
              ),
              ),
              Text(
                existing == null ? 'New habit' : 'Edit habit',
                style: HrText.title2,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: existing == null,
                style: HrText.body,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'e.g. Meditate 10 min',
                  hintStyle: HrText.body.copyWith(color: HrColors.text3),
                  filled: true,
                  fillColor: HrColors.surface2,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    borderSide: BorderSide.none,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    borderSide: const BorderSide(
                      color: HrColors.text,
                      width: 1.5,
                    ),
                  ),
                ),
                onChanged: analyze,
              ),
              const SizedBox(height: 16),
              const HrLabel('Icon'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: emojis.map((e) {
                  final sel = e == icon;
                  return GestureDetector(
                    onTap: () => setLocal(() {
                    icon = sel ? '' : e;
                    iconManual = true;
                  }),
                    child: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sel ? HrColors.accent : HrColors.surface2,
                        borderRadius: BorderRadius.circular(HrRadius.sm),
                      ),
                      child: e == '💰'
                          ? Image.asset(
                              'assets/shop/coin_stack.png',
                              width: 27,
                              height: 27,
                              fit: BoxFit.contain,
                              semanticLabel: 'Coins',
                            )
                          : Text(e, style: const TextStyle(fontSize: 20)),
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
                  color: HrColors.surface2,
                  borderRadius: BorderRadius.circular(HrRadius.md),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.notifications_active_rounded,
                      size: 18,
                      color: reminderMinutes != null
                          ? HrColors.accent
                          : HrColors.text3,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        reminderMinutes == null
                            ? 'No daily reminder'
                            : 'Remind me at ${_fmtReminder(reminderMinutes!)}',
                        style: HrText.bodyS.copyWith(color: HrColors.text),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final init = reminderMinutes != null
                            ? TimeOfDay(
                                hour: reminderMinutes! ~/ 60,
                                minute: reminderMinutes! % 60,
                              )
                            : const TimeOfDay(hour: 20, minute: 0);
                        final picked = await showTimePicker(
                          context: ctx,
                          initialTime: init,
                        );
                        if (picked != null) {
                          setLocal(
                            () => reminderMinutes =
                                picked.hour * 60 + picked.minute,
                          );
                        }
                      },
                      child: Text(
                        reminderMinutes == null ? 'Set' : 'Change',
                        style: HrText.bodyS.copyWith(
                          color: HrColors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (reminderMinutes != null)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setLocal(() => reminderMinutes = null),
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: HrColors.text3,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  if (existing != null)
                    TextButton.icon(
                      onPressed: () {
                        appState.deleteHabit(existing);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(
                        Icons.delete_outline,
                        color: HrColors.dangerText,
                      ),
                      label: Text(
                        'Delete',
                        style: HrText.body.copyWith(color: HrColors.dangerText),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: 130,
                    child: HrButton(
                      label: existing == null ? 'Add' : 'Save',
                      onPressed: () {
                        final name = controller.text.trim();
                        if (name.isEmpty) {
                          Navigator.pop(ctx);
                          return;
                        }
                        debounce?.cancel();
                        final v = verdict;
                        if (existing == null) {
                          appState.addHabit(
                            name,
                            v.rarity,
                            icon: icon,
                            aiRated: v.fromAi,
                            reason: v.reason,
                            reminderMinutes: reminderMinutes,
                          );
                        } else {
                          appState.editHabit(
                            existing,
                            name: name,
                            rarity: v.rarity,
                            icon: icon,
                            aiRated: v.fromAi,
                            reason: v.reason,
                          );
                          appState.setHabitReminder(existing, reminderMinutes);
                        }
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
                ],
              ),
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
  final color = HrColors.rarity[v.rarity] ?? HrColors.text3;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: HrColors.surface2,
      borderRadius: BorderRadius.circular(HrRadius.md),
    ),
    child: Row(
      children: [
        Icon(Icons.auto_awesome_rounded, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${v.label} · ×${v.multiplier} · ~${estimatedXp(v.rarity)} XP',
                      style: HrText.bodyS.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ratingChip(v, analyzing),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                analyzing
                    ? 'Reading your habit…'
                    : (v.reason.isEmpty
                          ? 'Difficulty set automatically'
                          : v.reason),
                style: HrText.caption,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _ratingChip(DifficultyVerdict v, bool analyzing) {
  if (analyzing) {
    return const SizedBox(
      width: 13,
      height: 13,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
  final ai = v.fromAi;
  final label = ai ? '🤖 AI' : '✨ Auto';
  final c = ai ? HrColors.info : HrColors.text3;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(HrRadius.xs),
    ),
    child: Text(
      label,
      style: HrText.micro.copyWith(color: c, fontWeight: FontWeight.w700),
    ),
  );
}

Color _reflectionScoreColor(int value) {
  final score = value.clamp(1, 10);
  const low = Color(0xFFC6283D);
  const middle = Color(0xFFF4D044);
  const high = Color(0xFF155E34);
  if (score <= 5) return Color.lerp(low, middle, (score - 1) / 4)!;
  return Color.lerp(middle, high, (score - 5) / 5)!;
}

Future<void> showAddReflection(BuildContext context,
    {Reflection? existing}) async {
  final controller = TextEditingController(text: existing?.text ?? '');
  int day = existing?.day ?? 0,
      energy = existing?.energy ?? 0,
      mood = existing?.mood ?? 0,
      focus = existing?.focus ?? 0;

  Widget ratingRow({
    required String label,
    required IconData icon,
    required int value,
    required void Function(int) onPick,
    required StateSetter setLocal,
  }) {
    final selectedColor = value > 0 ? _reflectionScoreColor(value) : HrColors.text3;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      decoration: BoxDecoration(
        color: HrColors.surface2,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: (value > 0 ? selectedColor : HrColors.accent)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: value > 0 ? selectedColor : HrColors.accent,
                  size: 18,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: HrText.bodyS.copyWith(
                    color: HrColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              Text(
                value > 0 ? '$value' : '—',
                style: HrText.stat.copyWith(
                  color: value > 0 ? selectedColor : HrColors.text3,
                  fontSize: 19,
                ),
              ),
              Text(
                ' / 10',
                style: HrText.caption.copyWith(color: HrColors.text3),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: List.generate(10, (i) {
              final n = i + 1;
              final selected = value == n;
              final color = _reflectionScoreColor(n);
              final ink = color.computeLuminance() > 0.48
                  ? const Color(0xFF1C1C1E)
                  : Colors.white;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Semantics(
                    button: true,
                    selected: selected,
                    label: '$label $n out of 10',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setLocal(() => onPick(n)),
                        borderRadius: BorderRadius.circular(9),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? color : const Color(0xFF39393C),
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: selected
                                  ? Colors.white.withValues(alpha: 0.28)
                                  : Colors.white.withValues(alpha: 0.035),
                            ),
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                      color: color.withValues(alpha: 0.34),
                                      blurRadius: 9,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : const [],
                          ),
                          child: Text(
                            '$n',
                            style: HrText.caption.copyWith(
                              color: selected ? ink : HrColors.text2,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: HrColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => Padding(
        padding: EdgeInsets.fromLTRB(
            18, 15, 18, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: HrColors.surface3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(existing == null ? 'Reflect on today' : 'Edit reflection',
                  style: HrText.title1),
              const SizedBox(height: 4),
              Text('Rate your day 1–10, then jot a note.',
                  style: HrText.bodyS.copyWith(color: HrColors.text3)),
              const SizedBox(height: 15),
              ratingRow(
                label: 'How was your day?',
                icon: Icons.wb_sunny_rounded,
                value: day,
                onPick: (v) => day = v,
                setLocal: setLocal,
              ),
              ratingRow(
                label: 'How energetic were you?',
                icon: Icons.bolt_rounded,
                value: energy,
                onPick: (v) => energy = v,
                setLocal: setLocal,
              ),
              ratingRow(
                label: 'How was your mood?',
                icon: Icons.sentiment_satisfied_rounded,
                value: mood,
                onPick: (v) => mood = v,
                setLocal: setLocal,
              ),
              ratingRow(
                label: 'How focused were you?',
                icon: Icons.center_focus_strong_rounded,
                value: focus,
                onPick: (v) => focus = v,
                setLocal: setLocal,
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
                decoration: BoxDecoration(
                  color: HrColors.surface2,
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.055)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.edit_note_rounded,
                            color: HrColors.accent, size: 18),
                        const SizedBox(width: 6),
                        Text('NOTE', style: HrText.labelCaps),
                        const SizedBox(width: 4),
                        Text('OPTIONAL',
                            style: HrText.micro.copyWith(
                              color: HrColors.text3,
                              letterSpacing: 0.7,
                            )),
                      ],
                    ),
                    const SizedBox(height: 5),
                    TextField(
                      controller: controller,
                      minLines: 2,
                      maxLines: 3,
                      style: HrText.body,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText:
                            'A win, a challenge, or anything on your mind…',
                        hintStyle: HrText.bodyS.copyWith(color: HrColors.text3),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                button: true,
                label: existing == null
                    ? 'Save reflection, earn 20 XP'
                    : 'Save changes',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => Navigator.pop(ctx, true),
                    borderRadius: BorderRadius.circular(HrRadius.full),
                    child: Ink(
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [HrColors.accent, HrColors.accentPressed],
                        ),
                        borderRadius: BorderRadius.circular(HrRadius.full),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.19),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: HrColors.accent.withValues(alpha: 0.24),
                            blurRadius: 18,
                            spreadRadius: -4,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            const Icon(Icons.check_rounded,
                                color: Colors.white, size: 21),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                existing == null
                                    ? 'Save reflection'
                                    : 'Save changes',
                                textAlign: TextAlign.center,
                                style: HrText.body.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (existing == null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: HrColors.gold,
                                  borderRadius:
                                      BorderRadius.circular(HrRadius.full),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.star_rounded,
                                        color: Color(0xFF362300), size: 15),
                                    const SizedBox(width: 3),
                                    Text(
                                      '+20 XP',
                                      style: HrText.micro.copyWith(
                                        color: const Color(0xFF362300),
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    ),
  );
  if (saved == true) {
    final t = controller.text.trim();
    final hasContent =
        t.isNotEmpty || day > 0 || energy > 0 || mood > 0 || focus > 0;
    if (existing != null) {
      appState.updateReflection(existing, t,
          day: day, energy: energy, mood: mood, focus: focus);
    } else if (hasContent) {
      appState.addReflection(t,
          day: day, energy: energy, mood: mood, focus: focus);
    }
  }
  controller.dispose();
}

// ── NUTRITION ────────────────────────────────────────────────────────────────
class _NutritionCard extends StatelessWidget {
  const _NutritionCard();
  @override
  Widget build(BuildContext context) {
    final n = appState.todayNutrition();
    final t = appState.targets();
    final score = appState.nutritionScore();
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const NutritionScreen())),
        child: Row(
          children: [
            Icon(Icons.restaurant_rounded, color: HrColors.accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NUTRITION', style: HrText.labelCaps),
                  const SizedBox(height: 3),
                  Text(
                    '${n.calories.round()} / ${t.calories.round()} kcal · ${n.protein.round()}g protein',
                    style: HrText.caption,
                  ),
                ],
              ),
            ),
            Text(
              '$score',
              style: HrText.stat.copyWith(
                fontSize: 20,
                color: HrColors.victory(score),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
          ],
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
        final todays = appState.foodLog.where((e) => e.date == today).toList();
        final score = appState.nutritionScore();
        final t = appState.targets();
        final p = appState.bodyProfile;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Nutrition'),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showAddFood(context),
            backgroundColor: HrColors.accent,
            foregroundColor: HrColors.onAccent,
            icon: const Icon(Icons.add),
            label: const Text('Log food'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              96,
            ),
            children: [
              HrCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('NUTRITION SCORE', style: HrText.labelCaps),
                              Text(
                                '$score / 100',
                                style: HrText.stat.copyWith(
                                  color: HrColors.victory(score),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.restaurant_rounded,
                          color: HrColors.victory(score),
                          size: 32,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _macroBar(
                      'Calories',
                      n.calories,
                      t.calories,
                      'kcal',
                      HrColors.gold,
                    ),
                    _macroBar(
                      'Protein',
                      n.protein,
                      t.protein,
                      'g',
                      HrColors.danger,
                    ),
                    _macroBar('Carbs', n.carbs, t.carbs, 'g', HrColors.info),
                    _macroBar('Fat', n.fat, t.fat, 'g', HrColors.accent),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p == null
                                ? 'Targets: defaults'
                                : 'TDEE ${computeTDEE(p).round()} kcal · ${p.goal}',
                            style: HrText.caption,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const BodyProfileScreen(),
                            ),
                          ),
                          icon: const Icon(
                            Icons.person_rounded,
                            size: 16,
                            color: HrColors.text2,
                          ),
                          label: Text(
                            p == null ? 'Set body profile' : 'Edit profile',
                            style: HrText.bodyS.copyWith(
                              color: HrColors.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (todays.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyState(
                    emoji: '🍎',
                    title: 'No food logged today',
                    subtitle: 'Tap "Log food" to add a meal.',
                  ),
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
  String label,
  double value,
  double target,
  String unit,
  Color color,
) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: HrText.caption.copyWith(color: HrColors.text2)),
            Text(
              '${value.round()} / ${target.round()} $unit',
              style: HrText.caption,
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(HrRadius.full),
          child: LinearProgressIndicator(
            value: (target <= 0 ? 0.0 : value / target)
                .clamp(0.0, 1.0)
                .toDouble(),
            minHeight: 7,
            backgroundColor: HrColors.surface3,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    ),
  );
}

class _FoodTile extends StatelessWidget {
  const _FoodTile(this.e);
  final FoodEntry e;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HrCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.name,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${e.calories.round()} kcal · P${e.protein.round()} C${e.carbs.round()} F${e.fat.round()}',
                    style: HrText.caption,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: HrColors.text3, size: 18),
              onPressed: () => appState.deleteFood(e),
            ),
          ],
        ),
      ),
    );
  }
}

double _parseNum(String s) => double.tryParse(s.trim()) ?? 0;

Widget _numField(
  TextEditingController c,
  String label,
  TextInputType kb, {
  ValueChanged<String>? onChanged,
}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: TextField(
    controller: c,
    keyboardType: kb,
    style: HrText.body,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: HrText.caption,
      filled: true,
      fillColor: HrColors.surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: BorderSide.none,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: const BorderSide(color: HrColors.text, width: 1.5),
      ),
    ),
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
          final est = await estimateNutrition(
            desc,
            enabled: appState.aiEnabled,
            baseUrl: appState.aiBaseUrl,
            model: appState.aiModel,
          );
          if (!ctx.mounted) return;
          setLocal(() => busy = false);
          if (est == null) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: const Text(
                  'AI estimation is unavailable. You can enter the macros manually.',
                ),
              ),
            );
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
          title: const Text('Log food', style: TextStyle(color: kTextPrimary)),
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
                    border: Border.all(color: kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 15,
                            color: kCyan,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Describe your meal',
                            style: TextStyle(
                              color: kTextSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: meal,
                        style: const TextStyle(color: kTextPrimary),
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText:
                              'e.g. 2 eggs, toast with butter, black coffee',
                        ),
                        onSubmitted: (_) => runAi(),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: kPlasma,
                            minimumSize: const Size.fromHeight(40),
                          ),
                          onPressed: busy ? null : runAi,
                          icon: busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 16,
                                ),
                          label: Text(
                            busy ? 'Calculating…' : 'Calculate macros with AI',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                if (aiFilled)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '🤖 AI estimate — adjust anything below',
                      style: TextStyle(color: kCyan, fontSize: 11),
                    ),
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
              child: const Text('Cancel'),
            ),
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
    appState.addFood(
      nm,
      _parseNum(cal.text),
      _parseNum(p.text),
      _parseNum(c.text),
      _parseNum(f.text),
    );
  }
}

// ── COMPANIONS ───────────────────────────────────────────────────────────────
class _CompanionOrb extends StatelessWidget {
  const _CompanionOrb({
    required this.color,
    required this.icon,
    required this.size,
    this.imageAsset,
    this.glowColor, // premium skin tint; null = default behaviour
    this.accessoryEmoji = '', // premium accessory overlay; '' = none
  });
  final Color color;
  final IconData icon;
  final double size;
  final String? imageAsset;
  final Color? glowColor;
  final String accessoryEmoji;

  @override
  Widget build(BuildContext context) {
    final orb = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: imageAsset == null ? null : Colors.black,
        gradient: imageAsset == null
            ? RadialGradient(colors: [color, color.withValues(alpha: 0.25)])
            : null,
        boxShadow: glowColor != null
            ? [
                BoxShadow(
                  color: glowColor!.withValues(alpha: 0.6),
                  blurRadius: size * 0.3,
                  spreadRadius: 1,
                ),
              ]
            : imageAsset == null
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: imageAsset == null
          ? Icon(icon, color: Colors.white, size: size * 0.5)
          : Image.asset(imageAsset!, fit: BoxFit.cover),
    );
    if (accessoryEmoji.isEmpty) return orb;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        orb,
        Positioned(
          top: -size * 0.14,
          right: -size * 0.06,
          child: Text(accessoryEmoji, style: TextStyle(fontSize: size * 0.4)),
        ),
      ]),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const CompanionsScreen())),
        child: Row(
          children: [
            _CompanionOrb(
              color: c.color,
              icon: c.icon,
              size: 46,
              imageAsset: c.imageAsset,
              glowColor: appState.companionSkin == 'classic'
                  ? null
                  : companionGlowColor(appState.companionSkin, c.color),
              accessoryEmoji:
                  companionAccessoryById(appState.companionAccessory).emoji,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HrText.body.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: HrColors.accentSurface,
                          borderRadius: BorderRadius.circular(HrRadius.xs),
                        ),
                        child: Text(
                          'Stage $stage',
                          style: HrText.micro.copyWith(
                            color: HrColors.accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '"$line"',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HrText.caption.copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
          ],
        ),
      ),
    );
  }
}

class CompanionsScreen extends StatelessWidget {
  const CompanionsScreen({super.key});

  // Big preview of the active companion, wearing the chosen skin + accessory.
  Widget _companionPreview() {
    final c = companionByType(appState.activeCompanion);
    return Column(children: [
      _CompanionOrb(
        color: c.color,
        icon: c.icon,
        size: 108,
        imageAsset: c.imageAsset,
        glowColor: appState.companionSkin == 'classic'
            ? null
            : companionGlowColor(appState.companionSkin, c.color),
        accessoryEmoji: companionAccessoryById(appState.companionAccessory).emoji,
      ),
      const SizedBox(height: 12),
      Text(c.name, style: HrText.title2),
      const SizedBox(height: 2),
      Text(c.tagline, style: HrText.caption),
    ]);
  }

  Widget _skinSwatch(CompanionSkin s) {
    final sel = appState.companionSkin == s.id;
    final col = s.id == 'classic'
        ? companionByType(appState.activeCompanion).color
        : s.color;
    return GestureDetector(
      onTap: () => appState.setCompanionSkin(s.id),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [col, col.withValues(alpha: 0.3)]),
            border: Border.all(
                color: sel ? HrColors.accent : HrColors.hairline,
                width: sel ? 2 : 1),
          ),
          child: s.id == 'classic'
              ? const Icon(Icons.auto_awesome_rounded,
                  size: 18, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 4),
        Text(s.name,
            style: HrText.micro
                .copyWith(color: sel ? HrColors.text : HrColors.text3)),
      ]),
    );
  }

  Widget _accessorySwatch(CompanionAccessory a) {
    final sel = appState.companionAccessory == a.id;
    return GestureDetector(
      onTap: () => appState.setCompanionAccessory(a.id),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: HrColors.surface2,
          border: Border.all(
              color: sel ? HrColors.accent : HrColors.hairline,
              width: sel ? 2 : 1),
        ),
        child: a.emoji.isEmpty
            ? const Icon(Icons.block_rounded, size: 18, color: HrColors.text3)
            : Text(a.emoji, style: const TextStyle(fontSize: 22)),
      ),
    );
  }

  // A compact badge of the player's current cosmetic class.
  Widget _classBadge() {
    final cl = classById(appState.playerClass);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: cl.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(HrRadius.full),
          border: Border.all(color: cl.color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(cl.emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Text(cl.name.toUpperCase(),
              style: HrText.micro.copyWith(
                  color: cl.color,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }

  Widget _classSwatch(ClassDef cl) {
    final sel = appState.playerClass == cl.id;
    return GestureDetector(
      onTap: () => appState.setPlayerClass(cl.id),
      child: SizedBox(
        width: 72,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 54,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sel ? cl.color.withValues(alpha: 0.18) : HrColors.surface2,
              border: Border.all(
                  color: sel ? cl.color : HrColors.hairline,
                  width: sel ? 2 : 1),
            ),
            child: Text(cl.emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(height: 5),
          Text(cl.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.micro
                  .copyWith(color: sel ? HrColors.text : HrColors.text3)),
        ]),
      ),
    );
  }

  Widget _customizeSection(BuildContext context) {
    if (!appState.isPremium) {
      return HrCard(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const PremiumScreen())),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: HrColors.accentSurface,
                borderRadius: BorderRadius.circular(HrRadius.md)),
            child: const Icon(Icons.workspace_premium_rounded,
                color: HrColors.gold, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Customize your companion', style: HrText.headline),
            const SizedBox(height: 2),
            Text('Skins & accessories with Premium', style: HrText.caption),
          ])),
          _lockPill(),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HrLabel('Skin'),
      const SizedBox(height: 10),
      Wrap(
          spacing: 12,
          runSpacing: 12,
          children: kCompanionSkins.map(_skinSwatch).toList()),
      const SizedBox(height: 18),
      const HrLabel('Accessory'),
      const SizedBox(height: 10),
      Wrap(
          spacing: 12,
          runSpacing: 12,
          children: kCompanionAccessories.map(_accessorySwatch).toList()),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Companions'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              24,
            ),
            children: [
              _classBadge(),
              const SizedBox(height: 14),
              _companionPreview(),
              const SizedBox(height: 18),
              _customizeSection(context),
              const SizedBox(height: 18),
              const HrLabel('Choose companion'),
              const SizedBox(height: 10),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
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
                    color: HrColors.surface,
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    border: Border(
                      top: BorderSide(
                        color: active ? HrColors.accent : HrColors.hairline,
                        width: active ? 2 : 1,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 54,
                        height: 54,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: Opacity(
                                opacity: unlocked ? 1 : 0.48,
                                child: _CompanionOrb(
                                  color: c.color,
                                  icon: c.icon,
                                  size: 54,
                                  imageAsset: c.imageAsset,
                                ),
                              ),
                            ),
                            if (!unlocked)
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: HrColors.surface2,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.lock_rounded,
                                    size: 12,
                                    color: HrColors.text3,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        c.name,
                        style: HrText.body.copyWith(
                          color: unlocked ? HrColors.text : HrColors.text3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        unlocked ? c.tagline : 'Unlock at Lv ${c.unlockLevel}',
                        textAlign: TextAlign.center,
                        style: HrText.caption,
                      ),
                      if (active) ...[
                        const SizedBox(height: 6),
                        Text(
                          'ACTIVE',
                          style: HrText.micro.copyWith(
                            color: HrColors.accent,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
                }).toList(),
              ),
              const SizedBox(height: 20),
              const HrLabel('Your class'),
              const SizedBox(height: 6),
              Text(classById(appState.playerClass).tagline,
                  style: HrText.caption),
              const SizedBox(height: 4),
              Text('Cosmetic only — never changes XP or difficulty.',
                  style: HrText.micro.copyWith(color: HrColors.text3)),
              const SizedBox(height: 12),
              Wrap(
                  spacing: 12,
                  runSpacing: 14,
                  children: kClasses.map(_classSwatch).toList()),
            ],
          ),
        );
      },
    );
  }
}

// ── PRESTIGE & SEASONS ───────────────────────────────────────────────────────
Future<void> _confirmPrestige(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: HrColors.surface,
      title: Text(
        'Prestige to ★${appState.prestige + 1}?',
        style: HrText.title2,
      ),
      content: Text(
        'You go back to Level 1 and your XP resets. You keep a permanent ★ and +5% XP per star. Habits, streaks and coins stay.',
        style: HrText.bodyS,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not yet'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: HrColors.btnPrimary,
            foregroundColor: HrColors.onBtnPrimary,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Prestige'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState.setCompanionLine(
      companionLine(appState.activeCompanion, 'prestige'),
    );
    appState.doPrestige();
    if (context.mounted) _showPrestige(context, appState.prestige);
  }
}

void _showPrestige(BuildContext context, int prestige) {
  final comp = companionByType(appState.activeCompanion);
  _showMoment(
    context,
    label: 'Prestige',
    labelColor: HrColors.gold,
    emblem: CompanionSticker(
      icon: comp.icon,
      color: comp.color,
      size: 104,
      semanticLabel: comp.name,
      imageAsset: comp.imageAsset,
    ),
    title: 'Reborn.  ${'★' * prestige}',
    subtitle: 'Reborn as Initiate — stronger than before. +5% XP per star.',
    bubble: companionLine(appState.activeCompanion, 'prestige'),
    buttonLabel: 'Rise',
  );
}

void _showChallengeComplete(BuildContext context, ChallengeDef? c) {
  _showMoment(
    context,
    label: 'Challenge complete',
    labelColor: HrColors.gold,
    emblem: SegmentedRing(
      size: 136,
      segments: 1,
      value: 1,
      stroke: 9,
      color: HrColors.gold,
      center: Icon(c?.icon ?? Icons.emoji_events_rounded,
          color: HrColors.gold, size: 52),
    ),
    title: c?.title ?? 'Challenge complete',
    subtitle: '+150 coins',
    bubble: companionLine(appState.activeCompanion, 'challenge_done'),
    buttonLabel: 'Claim',
  );
}

void _showSeasonIntro(BuildContext context) {
  final s = appState.currentSeason + 1;
  _showMoment(
    context,
    label: 'New season',
    labelColor: HrColors.info,
    emblem: SegmentedRing(
      size: 136,
      segments: 4,
      value: 4,
      stroke: 9,
      color: HrColors.info,
      center: Text('4/4', style: HrText.stat),
    ),
    title: 'Season $s',
    subtitle:
        'Four bosses fell. A new season begins — new boss, fresh leaderboard.',
    buttonLabel: 'Begin',
  );
}

// ── BODY PROFILE ─────────────────────────────────────────────────────────────
Widget _dropdown(
  String label,
  String value,
  Map<String, String> opts,
  ValueChanged<String> onChanged,
) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: DropdownButtonFormField<String>(
    initialValue: value,
    dropdownColor: HrColors.surface2,
    style: HrText.body,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: HrText.caption,
      filled: true,
      fillColor: HrColors.surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: BorderSide.none,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: const BorderSide(color: HrColors.text, width: 1.5),
      ),
    ),
    items: opts.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, style: HrText.body),
          ),
        )
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
      text: p != null ? p.weight.toStringAsFixed(0) : '',
    );
    _height = TextEditingController(
      text: p != null ? p.height.toStringAsFixed(0) : '',
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid weight, height, and age')),
      );
      return;
    }
    appState.setBodyProfile(
      BodyProfile(
        weight: w,
        height: h,
        age: a,
        gender: _gender,
        activity: _activity,
        goal: _goal,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final w = double.tryParse(_weight.text) ?? 0;
    final h = double.tryParse(_height.text) ?? 0;
    final a = int.tryParse(_age.text) ?? 0;
    final preview = (w > 0 && h > 0 && a > 0)
        ? computeMacroTargets(
            BodyProfile(
              weight: w,
              height: h,
              age: a,
              gender: _gender,
              activity: _activity,
              goal: _goal,
            ),
          )
        : null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: HrColors.text,
        elevation: 0,
        title: const HrAppBarTitle('Body profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          HrSpace.gutter,
          8,
          HrSpace.gutter,
          24,
        ),
        children: [
          _numField(
            _weight,
            'Weight (kg)',
            TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          _numField(
            _height,
            'Height (cm)',
            TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          _numField(
            _age,
            'Age',
            TextInputType.number,
            onChanged: (_) => setState(() {}),
          ),
          _dropdown('Gender', _gender, const {
            'male': 'Male',
            'female': 'Female',
            'other': 'Other',
          }, (v) => setState(() => _gender = v)),
          _dropdown('Activity', _activity, const {
            'sedentary': 'Sedentary',
            'light': 'Light',
            'moderate': 'Moderate',
            'active': 'Active',
            'very_active': 'Very active',
          }, (v) => setState(() => _activity = v)),
          _dropdown('Goal', _goal, const {
            'cut': 'Cut (lose fat)',
            'maintain': 'Maintain',
            'bulk': 'Bulk (gain)',
          }, (v) => setState(() => _goal = v)),
          const SizedBox(height: 16),
          if (preview != null)
            HrCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HrLabel('Computed targets'),
                  Text(
                    '${preview.calories.round()} kcal',
                    style: HrText.title1,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Protein ${preview.protein.round()}g · Carbs ${preview.carbs.round()}g · Fat ${preview.fat.round()}g',
                    style: HrText.caption,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          HrButton(label: 'Save profile', onPressed: _save),
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
      return HrColors.gold;
    case 'season':
      return HrColors.info;
    case 'streak':
      return HrColors.streak;
    default:
      return HrColors.accent;
  }
}

String _fmtDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${months[d.month - 1]} ${d.day} · $hh:$mm';
}

Widget _bestChip(String label, String value) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  decoration: BoxDecoration(
    color: HrColors.surface2,
    borderRadius: BorderRadius.circular(HrRadius.md),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: HrText.title2),
      Text(label, style: HrText.caption),
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
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Legacy'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              24,
            ),
            children: [
              HrCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HrLabel('Career bests'),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _bestChip('Peak level', '${appState.highestLevel}'),
                        _bestChip('Prestige', '★${appState.prestige}'),
                        _bestChip('Bosses', '${appState.totalBossDefeats}'),
                        _bestChip('Season', '${appState.currentSeason + 1}'),
                        _bestChip('Best streak', '${appState.bestStreak}'),
                      ],
                    ),
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
                    subtitle: 'Level up, defeat the boss, or hit a streak.',
                  ),
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HrColors.surface,
        borderRadius: BorderRadius.circular(HrRadius.md),
        border: const Border(top: BorderSide(color: HrColors.hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.15),
            ),
            child: Icon(_milestoneIcon(m.type), color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.description,
                  style: HrText.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(_fmtDate(m.date), style: HrText.caption),
              ],
            ),
          ),
          if (m.xp > 0)
            Text(
              '+${m.xp}',
              style: HrText.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}

// ── SETTINGS & ACCOUNT ───────────────────────────────────────────────────────
Widget _settingsTile(
  IconData icon,
  String title,
  String subtitle,
  VoidCallback? onTap, {
  bool danger = false,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: HrColors.surface,
      borderRadius: BorderRadius.circular(HrRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                icon,
                color: danger ? HrColors.dangerText : HrColors.text2,
                size: 20,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: HrText.body.copyWith(
                        color: danger ? HrColors.dangerText : HrColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: HrText.caption),
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(String s) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
  child: Text(s.toUpperCase(), style: HrText.labelCaps),
);

// ── "You" hub rows (redesign) ────────────────────────────────────────────────
class _YouRow {
  const _YouRow(
    this.icon,
    this.title,
    this.subtitle,
    this.onTap, {
    this.danger = false,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final bool danger;
}

Widget _youRowWidget(_YouRow r) => Material(
  color: Colors.transparent,
  child: InkWell(
    onTap: r.onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Icon(
            r.icon,
            size: 20,
            color: r.danger ? HrColors.dangerText : HrColors.text2,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.title,
                  style: HrText.body.copyWith(
                    color: r.danger ? HrColors.dangerText : HrColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (r.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    r.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HrText.caption,
                  ),
                ],
              ],
            ),
          ),
          if (r.onTap != null && !r.danger)
            const Icon(Icons.chevron_right_rounded, color: HrColors.text3),
        ],
      ),
    ),
  ),
);

Widget _youGroup(List<_YouRow> rows) => HrCard(
  padding: EdgeInsets.zero,
  child: ClipRRect(
    borderRadius: BorderRadius.circular(HrRadius.lg),
    child: Column(
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          if (i > 0)
            const Divider(
              height: 1,
              thickness: 1,
              color: HrColors.hairline,
              indent: 48,
            ),
          _youRowWidget(rows[i]),
        ],
      ],
    ),
  ),
);

Widget _youQuickCard({
  required IconData icon,
  required Color iconColor,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
  String? imageAsset,
  double imageSize = 44,
}) => HrCard(
  onTap: onTap,
  padding: const EdgeInsets.all(14),
  child: Row(
    children: [
      Container(
        width: imageAsset == null ? 36 : 44,
        height: imageAsset == null ? 36 : 44,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(shape: BoxShape.circle, color: iconColor),
        child: imageAsset == null
            ? Icon(icon, size: 18, color: HrColors.bg)
            : Image.asset(
                imageAsset,
                width: imageSize,
                height: imageSize,
                fit: BoxFit.contain,
              ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.body.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.caption,
            ),
          ],
        ),
      ),
    ],
  ),
);

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, auth]),
      builder: (context, _) {
        final ld = levelFromXp(appState.totalXp);
        final remainingXp = (ld.requiredXp - ld.currentXp).clamp(0, 1 << 30);
        final authed = auth.isAuthed;
        final u = auth.user;
        final handle = (u != null && u.username.isNotEmpty)
            ? '@${u.username} · '
            : '';
        final p = appState.bodyProfile;
        final n = appState.todayNutrition();
        final t = appState.targets();
        final comp = companionByType(appState.activeCompanion);
        final bodySub = p == null
            ? 'Set weight, height & goal'
            : '${p.weight.round()} kg · ${p.goal[0].toUpperCase()}${p.goal.substring(1)} · ${t.calories.round()} kcal';
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter,
                4,
                HrSpace.gutter,
                100,
              ),
              children: [
                Row(
                  children: [
                    Text('Profile', style: HrText.display),
                    const Spacer(),
                    _coinChip(context),
                  ],
                ),
                const SizedBox(height: 16),
                HrCard(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => authed
                            ? const AccountScreen()
                            : const LoginScreen(),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () => _pickProfilePhoto(context),
                              child: _Avatar(size: 52),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          appState.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: HrText.title2,
                                        ),
                                      ),
                                      if (appState.isPremium) ...[
                                        const SizedBox(width: 8),
                                        _premiumTag(),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${handle}Level ${ld.level} · ${levelTitle(ld.level)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HrText.caption,
                                  ),
                                ],
                              ),
                            ),
                            CompanionSticker(
                              icon: comp.icon,
                              color: comp.color,
                              size: 58,
                              semanticLabel: comp.name,
                              imageAsset: comp.imageAsset,
                            ),
                            const SizedBox(width: 2),
                            IconButton(
                              icon: const Icon(
                                Icons.edit_rounded,
                                color: HrColors.gold,
                                size: 18,
                              ),
                              tooltip: 'Edit name',
                              onPressed: () => _editName(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(HrRadius.full),
                          child: LinearProgressIndicator(
                            value: ld.progress.clamp(0.0, 1.0).toDouble(),
                            minHeight: 9,
                            backgroundColor: HrColors.surface3,
                            valueColor: const AlwaysStoppedAnimation(
                              HrColors.gold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              '$remainingXp XP to next level',
                              style: HrText.micro.copyWith(color: HrColors.text2),
                            ),
                            const Spacer(),
                            StreakPill(count: appState.bestStreak, quiet: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const _PremiumYouCard(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _youQuickCard(
                        icon: comp.icon,
                        iconColor: comp.color,
                        title: comp.name,
                        subtitle: 'Companion',
                        imageAsset: comp.imageAsset,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const CompanionsScreen(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _youQuickCard(
                        icon: Icons.monetization_on_rounded,
                        iconColor: Colors.transparent,
                        title: 'Shop',
                        subtitle: '${appState.coins} coins',
                        imageAsset: 'assets/shop/coin_stack.png',
                        imageSize: 44,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ShopScreen()),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const HrLabel('Account'),
                _youGroup([
                  _YouRow(
                    authed ? Icons.person_rounded : Icons.login_rounded,
                    authed ? 'Account' : 'Sign in or create account',
                    authed
                        ? (u?.email ?? 'Manage your account')
                        : 'Back up progress & sync devices',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => authed
                            ? const AccountScreen()
                            : const LoginScreen(),
                      ),
                    ),
                  ),
                  _YouRow(
                    Icons.ios_share_rounded,
                    'Share progress',
                    'Level · streak · score',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ShareCardScreen(),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 18),
                const HrLabel('Preferences'),
                _youGroup([
                  _YouRow(
                    Icons.palette_rounded,
                    'Appearance',
                    'Rings, checks & progress colour',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AppearanceScreen(),
                      ),
                    ),
                  ),
                  _YouRow(
                    Icons.checklist_rounded,
                    'Tasks',
                    appState.openTasksToday > 0
                        ? '${appState.openTasksToday} open today'
                        : 'Dailies & to-dos',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TasksScreen()),
                    ),
                  ),
                  _YouRow(
                    Icons.flag_rounded,
                    'Guided challenges',
                    appState.activeChallenge?.title ?? '7 & 30-day programs',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ChallengesScreen(),
                      ),
                    ),
                  ),
                  _YouRow(
                    Icons.health_and_safety_rounded,
                    'Streak protection',
                    appState.isPremium
                        ? '${appState.premiumStreakSavesLeft} saves left this month'
                        : 'Streak-saves & rest days',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const RecoveryScreen(),
                      ),
                    ),
                  ),
                  _YouRow(
                    Icons.monitor_heart_rounded,
                    'Body profile',
                    bodySub,
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const BodyProfileScreen(),
                      ),
                    ),
                  ),
                  _YouRow(
                    Icons.restaurant_rounded,
                    'Nutrition',
                    '${n.calories.round()} / ${t.calories.round()} kcal today',
                    () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const NutritionScreen(),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 18),
                const HrLabel('Data'),
                _youGroup([
                  _YouRow(
                    Icons.refresh_rounded,
                    'Reset all progress',
                    'Wipe habits, XP & history',
                    () => _confirmReset(context),
                    danger: true,
                  ),
                  if (authed)
                    _YouRow(Icons.logout_rounded, 'Log out', '', () async {
                      await auth.signOut();
                      if (context.mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    }, danger: true),
                ]),
                const SizedBox(height: 22),
                Center(
                  child: Text('Habitrail · v1.0.0', style: HrText.caption),
                ),
              ],
            ),
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
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
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
      backgroundColor: HrColors.surface,
      title: Text('Reset all progress?', style: HrText.title2),
      content: Text(
        'This permanently clears your habits, XP, coins, streaks, nutrition, companions, prestige and history on this device.',
        style: HrText.bodyS,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: HrColors.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reset everything'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState.resetAll();
    hrToast(context, 'Progress reset', icon: Icons.refresh_rounded);
  }
}

// ── APPEARANCE (themes) ──────────────────────────────────────────────────────
Widget _swatch(Color c) => Container(
  width: 22,
  height: 22,
  margin: const EdgeInsets.symmetric(horizontal: 3),
  decoration: BoxDecoration(shape: BoxShape.circle, color: c),
);

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: kElevated));

// Gold affordability-aware buy pill. Affordable → a restrained gold accent;
// otherwise a muted pill that still shows the "not enough coins" toast.
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
                  colors: [Color(0xFFFFD873), Color(0xFFF5A623)],
                )
              : null,
          color: canAfford ? null : kElevated,
          border: canAfford ? null : Border.all(color: kBorder),
          boxShadow: canAfford
              ? [
                  BoxShadow(
                    color: const Color(0xFFF5A623).withValues(alpha: 0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/shop/coin_stack.png',
              width: 16,
              height: 16,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 3),
            Text(
              '$cost',
              style: TextStyle(
                color: canAfford ? const Color(0xFF3A2A05) : kTextSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// Small status chip for an owned/active cosmetic (check + label).
Widget _stateChip(String label, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
  decoration: BoxDecoration(
    color: color.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(HrRadius.sm),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.check_rounded, size: 13, color: color),
      const SizedBox(width: 4),
      Text(
        label,
        style: HrText.micro.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    ],
  ),
);

// Outline pill for a secondary action (Select / Apply an owned cosmetic).
Widget _secondaryPill(String label, VoidCallback onTap) => Material(
  color: HrColors.surface2,
  borderRadius: BorderRadius.circular(HrRadius.full),
  clipBehavior: Clip.antiAlias,
  child: InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Text(
        label,
        style: HrText.bodyS.copyWith(
          color: HrColors.text,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  ),
);

// Section header with an optional right-aligned owned-count ("3 / 7").
Widget _shopSectionHeader(String title, String trailing) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
  child: Row(
    children: [
      Expanded(child: Text(title.toUpperCase(), style: HrText.labelCaps)),
      if (trailing.isNotEmpty) Text(trailing, style: HrText.labelCaps),
    ],
  ),
);

// Coins balance hero at the top of the shop.
Widget _balanceHero() => HrCard(
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
  child: Row(
    children: [
      Image.asset(
        'assets/shop/coin_stack.png',
        width: 64,
        height: 64,
        fit: BoxFit.contain,
        semanticLabel: 'Gold coin stack',
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('YOUR BALANCE', style: HrText.labelCaps),
            const SizedBox(height: 3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${appState.coins}',
                  style: HrText.numeralXl.copyWith(
                    color: HrColors.gold,
                    fontSize: 34,
                  ),
                ),
                const SizedBox(width: 6),
                Text('coins', style: HrText.caption),
              ],
            ),
          ],
        ),
      ),
      if (appState.xpBoostActive)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: HrColors.accentSurface,
            borderRadius: BorderRadius.circular(HrRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '2×',
                style: HrText.bodyS.copyWith(
                  color: HrColors.accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'XP',
                style: HrText.micro.copyWith(
                  color: HrColors.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
    ],
  ),
);

Widget _shopItem({
  required IconData icon,
  required Color color,
  required String title,
  required String desc,
  required int cost,
  required VoidCallback? onBuy,
  String? activeLabel,
  String? imageAsset,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      child: Row(
        children: [
          if (imageAsset == null)
            SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: color, size: 22),
            )
          else
            Image.asset(
              imageAsset,
              width: 46,
              height: 46,
              fit: BoxFit.contain,
              semanticLabel: title,
            ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.caption.copyWith(
                    color: HrColors.text3.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (activeLabel != null)
            _stateChip(activeLabel, HrColors.accent)
          else if (onBuy != null)
            _buyPill(cost: cost, onTap: onBuy)
          else
            _stateChip('OWNED', HrColors.accent),
        ],
      ),
    ),
  );
}

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ownedBorders = kBorders
            .where((b) => appState.ownsBorder(b.id))
            .length;
        // The exclusive premium theme is unlocked by Premium, not bought here.
        final buyableThemes =
            kThemes.where((t) => t.id != kPremiumThemeId).toList();
        final ownedThemes =
            buyableThemes.where((t) => appState.ownsTheme(t.id)).length;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Shop'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              28,
            ),
            children: [
              _balanceHero(),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                child: Text(
                  'Spend coins on power-ups and cosmetics to personalize your journey.',
                  style: HrText.caption,
                ),
              ),
              _shopSectionHeader('POWER-UPS', ''),
              _shopItem(
                icon: Icons.bolt_rounded,
                color: kGold,
                imageAsset: 'assets/powerups/xp_booster.png',
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
                            : 'Not enough coins',
                      ),
                activeLabel: appState.xpBoostActive ? 'ACTIVE' : null,
              ),
              _shopItem(
                icon: Icons.shield_rounded,
                color: kCyan,
                imageAsset: 'assets/powerups/streak_shield.png',
                title: 'Streak Shield',
                desc:
                    'Saves a streak from one missed day · owned: ${appState.streakShields}',
                cost: 100,
                onBuy: () => _toast(
                  context,
                  appState.buyStreakShield()
                      ? 'Streak Shield added!'
                      : 'Not enough coins',
              ),
              ),
              _shopSectionHeader(
                'PROFILE BORDERS',
                '$ownedBorders / ${kBorders.length}',
              ),
              ...kBorders.map((b) => _borderShopTile(context, b)),
              _shopSectionHeader('THEMES', '$ownedThemes / ${buyableThemes.length}'),
              ...buyableThemes.map((t) => _themeShopTile(context, t)),
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
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      padding: const EdgeInsets.all(16),
      color: selected ? HrColors.accentSurface : null,
      child: Row(
        children: [
          _borderPreview(b, size: 42),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              b.name,
              style: HrText.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (owned)
            selected
                ? _stateChip('SELECTED', HrColors.accent)
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
        ],
      ),
    ),
  );
}

Widget _themeShopTile(BuildContext context, AppThemeDef t) {
  final owned = appState.ownsTheme(t.id);
  final active = appState.themeId == t.id;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      padding: const EdgeInsets.all(16),
      color: active ? HrColors.accentSurface : null,
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [_swatch(t.accent), _swatch(t.bright), _swatch(t.glow)],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t.name,
              style: HrText.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (owned)
            active
                ? _stateChip('ACTIVE', HrColors.accent)
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
        ],
      ),
    ),
  );
}

// ── CONFETTI ─────────────────────────────────────────────────────────────────
void celebrate(BuildContext context) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) =>
        Positioned.fill(child: _Confetti(onDone: () => entry.remove())),
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
      kPlasma,
      kCyan,
      kGold,
      const Color(0xFFF472B6),
      kGreen,
      kBlue,
    ];
    for (int i = 0; i < 80; i++) {
      _p.add(
        _Confo(
          r.nextDouble(),
          (r.nextDouble() - 0.5) * 0.4,
          r.nextDouble() * 0.25,
          r.nextDouble() * 6.28,
          (r.nextDouble() - 0.5) * 10,
          colors[r.nextInt(colors.length)],
          6 + r.nextDouble() * 7,
        ),
      );
    }
    _c =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1900),
          )
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
          size: Size.infinite,
          painter: _ConfettiPainter(_p, _c.value),
        ),
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
            center: Offset.zero,
            width: c.size,
            height: c.size * 0.6,
          ),
          const Radius.circular(1.5),
        ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HrLabel('Activity · last 5 weeks'),
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
                    borderRadius: BorderRadius.circular(HrRadius.xs),
                    color: on
                        ? HrColors.victory(c.score)
                              .withValues(alpha: 0.3 + c.score / 100 * 0.7)
                        : HrColors.surface2,
                    border: c.today
                        ? Border.all(color: HrColors.text, width: 1)
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekTrendCard extends StatelessWidget {
  const _WeekTrendCard();
  @override
  Widget build(BuildContext context) {
    final days = appState.weekTrend();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HrLabel('This week · Victory score'),
            SizedBox(
              height: 104,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: days.map((d) {
                  final h = 6.0 + (d.score / 100) * 60;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${d.score}', style: HrText.micro),
                      const SizedBox(height: 3),
                      Container(
                        width: 24,
                        height: h,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(HrRadius.xs),
                          color: HrColors.victory(d.score)
                              .withValues(alpha: d.today ? 1 : 0.5),
                          border: d.today
                              ? Border.all(color: HrColors.text, width: 1)
                              : null,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        d.label,
                        style: HrText.micro.copyWith(
                          color: d.today ? HrColors.text : HrColors.text3,
                          fontWeight: d.today
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
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
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: HrColors.text,
            elevation: 0,
            title: const HrAppBarTitle('Appearance'),
          ),
          body: GridView.count(
            padding: const EdgeInsets.fromLTRB(
              HrSpace.gutter,
              8,
              HrSpace.gutter,
              24,
            ),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.1,
            children: kThemes.map((t) {
              final active = appState.themeId == t.id;
              final isPremiumTheme = t.id == kPremiumThemeId;
              final canUse = appState.canUseTheme(t.id);
              return GestureDetector(
                onTap: canUse ? () => appState.setTheme(t.id) : null,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: HrColors.surface,
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    border: Border(
                      top: BorderSide(
                        color: active ? HrColors.accent : HrColors.hairline,
                        width: active ? 2 : 1,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Opacity(
                        opacity: canUse ? 1 : 0.5,
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
                      Text(
                        t.name,
                        textAlign: TextAlign.center,
                        style: HrText.body.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (active)
                        _stateChip('ACTIVE', HrColors.accent)
                      else if (canUse)
                        _secondaryPill('Apply', () => appState.setTheme(t.id))
                      else if (isPremiumTheme)
                        _secondaryPill(
                            'PREMIUM',
                            () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => const PremiumScreen())))
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
      Text(
        tag,
        style: const TextStyle(
          color: kCyan,
          letterSpacing: 3,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 10),
      Text(
        title,
        textAlign: TextAlign.center,
        style: TextStyle(fontFamily: kHrFont,
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w800,
        ),
      ),
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
    final msg = await aiCoachMessage(
      summary,
      enabled: appState.aiEnabled,
      baseUrl: appState.aiBaseUrl,
      model: appState.aiModel,
    );
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
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
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
        Column(
          children: [
            _CompanionOrb(
              color: who.color,
              icon: who.icon,
              size: 56,
              imageAsset: who.imageAsset,
            ),
            const SizedBox(height: 18),
            if (_coachLoading)
              Column(
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kPlasmaBright,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Reading your day…',
                    style: TextStyle(color: kTextTertiary, fontSize: 13),
                  ),
                ],
              )
            else
              Text(
                '"${_coach ?? _coachFallback()}"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kTextSecondary,
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                ),
              ),
          ],
        ),
      ),
      _briefPanel(
        'BRIEFING',
        'Welcome back, ${appState.displayName}',
        Column(
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [kPlasma, kBlue]),
              ),
              child: Text(
                '${ld.level}',
                style: TextStyle(fontFamily: kHrFont,
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              levelTitle(ld.level).toUpperCase(),
              style: const TextStyle(
                color: kCyan,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Best streak: ${appState.bestStreak} days',
              style: const TextStyle(color: kTextSecondary),
            ),
          ],
        ),
      ),
      _briefPanel(
        'STATUS',
        'Today',
        Column(
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  GlowRing(
                    value: v.score / 100,
                    size: 96,
                    stroke: 8,
                    colors: [
                      victoryColor(v.score),
                      Color.lerp(victoryColor(v.score), Colors.white, 0.35)!,
                    ],
                  ),
                  Text(
                    '${v.score}',
                    style: TextStyle(fontFamily: kHrFont,
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              victoryLabel(v.score),
              style: TextStyle(
                color: victoryColor(v.score),
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${appState.doneTodayCount}/${appState.habits.length} habits · ${appState.coins} coins',
              style: const TextStyle(color: kTextSecondary),
            ),
          ],
        ),
      ),
      _briefPanel(
        'ORDERS',
        "Today's quests",
        Column(
          children: kQuests.map((q) {
            final on = appState.questClaimedIds.contains(q.id);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 16,
                    color: on ? kGreen : kTextTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      q.title,
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    '+${q.xp}',
                    style: TextStyle(
                      color: kPlasmaGlow,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
      _briefPanel(
        'DEPLOY',
        who.name,
        Column(
          children: [
            _CompanionOrb(
              color: who.color,
              icon: who.icon,
              size: 60,
              imageAsset: who.imageAsset,
            ),
            const SizedBox(height: 14),
            Text(
              '"${companionLine(appState.activeCompanion, v.score >= 90 ? 'elite_day' : 'level_up')}"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kTextSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    ];
    final last = panels.length - 1;
    return Dialog.fullscreen(
      backgroundColor: kBase,
      child: SafeArea(
        child: Column(
          children: [
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
                    color: i == _page ? kPlasma : const Color(0x33FFFFFF),
                  ),
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
          ],
        ),
      ),
    );
  }
}
