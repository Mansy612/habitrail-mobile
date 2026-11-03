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
    final violet = HrText.displayXl.copyWith(
      foreground: Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFC9A8FF), Color(0xFF9B6BFF)],
        ).createShader(const Rect.fromLTWH(0, 0, 260, 44)),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 12, HrSpace.gutter, 20),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Semantics(
                        header: true,
                        label: 'Build better habits together',
                        excludeSemantics: true,
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: 'Build\n', style: HrText.displayXl),
                            TextSpan(text: 'better habits\ntogether', style: violet),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'Habitrail turns daily progress into an adventure. Complete goals, earn XP, and stay motivated with friends.',
                                style: HrText.body.copyWith(color: HrColors.text2),
                              ),
                            ),
                          ),
                          const HrHeroArt(width: 150, height: 190),
                        ],
                      ),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
              ),
              HrButton(
                label: 'Create account',
                icon: Icons.person_add_alt_1_rounded,
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const SignUpScreen())),
              ),
              const SizedBox(height: 10),
              HrButton(
                label: 'Log in',
                icon: Icons.login_rounded,
                kind: HrButtonKind.secondary,
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const LoginScreen())),
              ),
              const SizedBox(height: 10),
              HrButton(
                label: 'Continue without an account',
                icon: Icons.arrow_forward_rounded,
                kind: HrButtonKind.secondary,
                onPressed: () => auth.continueAsGuest(),
              ),
              const SizedBox(height: 10),
              Text(
                'You can create an account later to back up and sync your progress.',
                textAlign: TextAlign.center,
                style: HrText.micro.copyWith(color: HrColors.text3),
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
        const SizedBox(height: 20),
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
        const SizedBox(height: 20),
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
  final ok = await backupNow();
  if (!context.mounted) return;
  if (ok) {
    hrToast(context, 'Backed up to your account',
        icon: Icons.cloud_done_rounded);
  } else {
    hrToast(context, "Couldn't back up — check your connection and try again.",
        error: true, icon: Icons.cloud_off_rounded);
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
        final since = _memberSince(u.createdAt);
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const HrAppBarTitle('Account')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Semantics(
                      button: true,
                      label: 'Change profile photo',
                      child: GestureDetector(
                        onTap: () => _pickProfilePhoto(context),
                        child: Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: HrColors.accentBright, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                      color: HrColors.accent.withValues(alpha: 0.55),
                                      blurRadius: 16),
                                ],
                              ),
                              child: _Avatar(size: 76),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: HrColors.accent,
                                  border: Border.all(color: HrColors.surface, width: 2),
                                ),
                                child: const Icon(Icons.camera_alt_rounded,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(u.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HrText.title1),
                          const SizedBox(height: 2),
                          Text.rich(TextSpan(children: [
                            TextSpan(
                              text: 'Level ${ld.level}',
                              style: HrText.bodyS.copyWith(
                                  color: HrColors.accentBright,
                                  fontWeight: FontWeight.w800),
                            ),
                            TextSpan(
                              text: '  ·  ${appState.bestStreak} day streak',
                              style: HrText.bodyS.copyWith(color: HrColors.text2),
                            ),
                          ])),
                          if (u.username.isNotEmpty)
                            Text('@${u.username}', style: HrText.caption),
                          const SizedBox(height: 10),
                          HrButton(
                            label: 'Edit profile',
                            kind: HrButtonKind.secondary,
                            small: true,
                            expand: false,
                            onPressed: () => _editAccountName(context),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(child: _photoActions(context)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: HrStatTile(
                    value: hrNum(appState.totalXp),
                    label: 'Total XP',
                    leading: const Icon(Icons.auto_awesome, size: 26, color: HrColors.gold),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: HrStatTile(
                    value: '${appState.habits.length}',
                    label: 'Habits',
                    leading: const Icon(Icons.check_circle_rounded,
                        size: 26, color: HrColors.success),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: HrStatTile(
                    value: '★${appState.prestige}',
                    label: 'Prestige',
                    leading: Icon(Icons.workspace_premium_rounded,
                        size: 26, color: HrColors.accentBright),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              HrMenuGroup(children: [
                HrMenuRow(
                  icon: Icons.person_rounded,
                  label: 'Profile',
                  subtitle: 'Name and photo',
                  onTap: () => _editAccountName(context),
                ),
                HrMenuRow(
                  icon: Icons.alternate_email_rounded,
                  label: 'Email',
                  subtitle: u.email,
                  chevron: false,
                ),
                HrMenuRow(
                  icon: Icons.ios_share_rounded,
                  label: 'Share progress',
                  subtitle: 'Level · streak · score',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShareCardScreen()),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (!auth.isRemote)
                const HrMenuGroup(children: [
                  HrMenuRow(
                    icon: Icons.cloud_off_rounded,
                    label: 'Cloud sync',
                    subtitle: 'On this device for now — Supabase wires in later',
                    chevron: false,
                  ),
                ])
              else
                HrMenuGroup(title: 'Backup', children: [
                  HrMenuRow(
                    icon: Icons.cloud_upload_rounded,
                    label: 'Back up now',
                    subtitle: appState.lastBackupAt.isEmpty
                        ? 'Save your progress to your account'
                        : 'Last backed up ${_fmtBackup(appState.lastBackupAt)}',
                    onTap: () => _backupNow(context),
                  ),
                  HrMenuRow(
                    icon: Icons.cloud_download_rounded,
                    label: 'Restore from cloud',
                    subtitle: 'Replace this device with your backup',
                    onTap: () => _confirmRestore(context),
                  ),
                ]),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: HrColors.dangerSurface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(HrRadius.lg),
                  border: Border.all(color: HrColors.danger.withValues(alpha: 0.45)),
                ),
                child: HrMenuRow(
                  icon: Icons.delete_forever_rounded,
                  label: 'Account actions',
                  subtitle: 'Delete your account and its data',
                  iconColor: HrColors.dangerText,
                  labelColor: HrColors.dangerText,
                  onTap: () => _confirmDeleteAccount(context),
                ),
              ),
              if (since.isNotEmpty) ...[
                const SizedBox(height: 16),
                Center(child: Text(since, style: HrText.micro)),
              ],
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
                            tooltip: 'Back',
                            icon: const Icon(
                              Icons.chevron_left_rounded,
                              size: 32,
                              color: HrColors.text,
                            ),
                            onPressed: () => _pc.previousPage(
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOut,
                            ),
                          )
                        : null,
                  ),
                  Expanded(
                    child: HrXpBar(
                      value: (_page + 1) / (_last + 1),
                      height: 9,
                      color: HrColors.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${_page + 1} / ${_last + 1}',
                    style: HrText.bodyS.copyWith(
                        color: HrColors.text, fontWeight: FontWeight.w800),
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
                label: last ? "Let's go" : 'Next',
                icon: last ? Icons.rocket_launch_rounded : Icons.arrow_forward_rounded,
                onPressed: _canAdvance ? _next : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quizPage(String title, String? subtitle, Widget content,
          {bool art = false}) =>
      ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 12, HrSpace.gutter, 16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: HrText.display.copyWith(height: 1.1)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 8),
                      Text(subtitle, style: HrText.bodyS),
                    ],
                  ],
                ),
              ),
              if (art) const HrHeroArt(width: 116, height: 128),
            ],
          ),
          const SizedBox(height: 24),
          content,
        ],
      );

  Widget _areasPage() => _quizPage(
    'Personalize your journey',
    "What do you want to focus on? Pick a few — we'll set up starter habits for each.",
    art: true,
    HrCard(
      padding: const EdgeInsets.all(12),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.1,
        children: [for (final a in _kAreas) _areaChip(a.$1, a.$2, a.$3)],
      ),
    ),
  );

  Widget _areaChip(String id, String label, String emoji) {
    final on = _areas.contains(id);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: HrPressable(
        onTap: () => setState(() => on ? _areas.remove(id) : _areas.add(id)),
        child: AnimatedContainer(
          duration: HrMotion.of(context, HrMotion.base),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HrRadius.md),
            color: on ? HrColors.goldSurface : HrColors.surface2,
            border: Border.all(
              color: on ? HrColors.gold : HrColors.cardEdge,
              width: on ? 1.6 : 1,
            ),
            boxShadow: on
                ? [BoxShadow(color: HrColors.gold.withValues(alpha: 0.3), blurRadius: 12)]
                : null,
          ),
          child: Row(
            children: [
              HrIconTile(emoji: emoji, size: 34),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: HrText.bodyS.copyWith(
                      color: HrColors.text,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              HrCheck(done: on, size: 20),
            ],
          ),
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
    decoration: HrCard.decoration(radius: HrRadius.md),
    child: Row(
      children: [
        HrIconTile(icon: icon, size: 40),
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
            borderSide: const BorderSide(color: HrColors.cardEdge),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HrRadius.md),
            borderSide: const BorderSide(color: HrColors.cardEdge),
          ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        borderSide: BorderSide(color: HrColors.accent, width: 1.5),
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
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: HrPressable(
          onTap: () => onTap(id),
          child: AnimatedContainer(
            duration: HrMotion.of(context, HrMotion.base),
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(HrRadius.md),
              color: on ? HrColors.goldSurface : HrColors.surface,
              border: Border.all(
                color: on ? HrColors.gold : HrColors.cardEdge,
                width: on ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                HrIconTile(emoji: emoji, size: 40),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                HrCheck(done: on, size: 24),
              ],
            ),
          ),
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
  const _Avatar({this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final b = borderById(appState.selectedBorder);
    final hasBorder = b.id != 'none';
    // Thicker, glowing ring with a thin dark gap so the colour reads as a
    // distinct border against both the avatar and the cosmic background.
    final ringW = hasBorder
        ? (size * 0.11).clamp(3.0, 7.0)
        : (size * 0.06).clamp(2.0, 4.0);
    final gapW = hasBorder && b.frameAsset == null
        ? (size * 0.03).clamp(1.5, 3.0)
        : 0.0;
    final frameAsset = b.frameAsset;
    final inner = frameAsset != null ? size * 0.72 : size - (ringW + gapW) * 2;
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
                const Padding(
                padding: EdgeInsets.symmetric(horizontal: HrSpace.gutter),
                child: HrLabel('Today'),
              ),
                if (hasTasks) const _TasksCard(),
                if (hasChallenge) const _ChallengeTodayCard(),
                const SizedBox(height: 12),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: HrSpace.gutter),
                child: HrLabel('Your progress'),
              ),
              const _VictoryCard(),
              const _NutritionCard(),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: HrSpace.gutter),
                child: HrLabel('Adventure'),
              ),
              const _BossCard(),
              const _QuestsPanel(),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: HrSpace.gutter),
                child: HrLabel('Coach'),
              ),
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

/// "Level 9 · XP to next level 420 / 1,000" with the gold bar — shared by
/// Today and Profile so both read the same.
class _LevelPanel extends StatelessWidget {
  const _LevelPanel({this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
                if (appState.xpBoostActive) ...[
                  const HrXpChip(0, label: '2× XP'),
                  const SizedBox(width: 8),
                ],
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
                  Text('Victory score', style: HrText.caption.copyWith(color: HrColors.text2, fontWeight: FontWeight.w800)),
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final claimed = appState.questClaimedIds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Daily quests', style: HrText.headline)),
                const Icon(Icons.auto_awesome, size: 14, color: HrColors.gold),
                const SizedBox(width: 5),
                Text(
                  '${claimed.length} / ${kQuests.length}',
                  style: HrText.bodyS.copyWith(
                      color: HrColors.text, fontWeight: FontWeight.w900),
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
                    HrCheck(done: on, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        q.title,
                        style: HrText.bodyS.copyWith(
                          color: on ? HrColors.text2 : HrColors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    HrXpChip(q.xp),
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final left = appState.coachUsesLeft;
    final atLimit = !appState.canUseCoach;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 8),
      child: HrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Your coach', style: HrText.headline)),
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
          const SizedBox.shrink(),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(top: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: HrColors.gold, width: 1.6),
          ),
          child: Icon(icon, color: HrColors.gold, size: 13),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: HrText.body.copyWith(fontWeight: FontWeight.w800)),
            Text(sub, style: HrText.caption),
          ]),
        ),
      ]),
    );
  }
}

// Entry card on the Profile screen: upsell when free, status when Premium.
class _PremiumYouCard extends StatelessWidget {
  const _PremiumYouCard();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final premium = appState.isPremium;
    return HrCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PremiumScreen()),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(children: [
        const HrIconTile(
            icon: Icons.workspace_premium_rounded, color: HrColors.gold, size: 46),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: premium ? 'Habitrail ' : 'Go ', style: HrText.headline),
              TextSpan(
                  text: 'Premium',
                  style: HrText.headline.copyWith(color: HrColors.gold)),
            ])),
            const SizedBox(height: 2),
            Text(premium ? 'Active — manage your plan' : 'Coach, insights & more',
                style: HrText.caption),
          ]),
        ),
        if (premium)
          _premiumTag()
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [HrColors.goldBright, HrColors.goldDeep],
              ),
              borderRadius: BorderRadius.circular(HrRadius.sm),
            ),
            child: Text('Upgrade',
                style: HrText.bodyS.copyWith(
                    color: HrColors.onBtnPrimary, fontWeight: FontWeight.w900)),
          ),
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
        _PremiumProp(Icons.check_rounded, 'AI coach & plans',
            '$kPremiumCoachLimit prompts a week, a Weekly Report and a Weekly Plan'),
        const _PremiumProp(Icons.check_rounded, 'Deeper insights',
            'Consistency trends, best days, and cross-habit patterns'),
        const _PremiumProp(Icons.check_rounded, 'Challenges & recovery',
            'Guided 7 & 30-day programs, streak-saves and rest days'),
        const _PremiumProp(Icons.check_rounded, 'Make it yours',
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
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
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

  // Gold Monthly / Yearly switch with the annual saving.
  Widget _planToggle() {
    Widget seg(String id, String label, {String? badge}) {
      final on = _plan == id;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: label,
          child: HrPressable(
            onTap: () => setState(() => _plan = id),
            child: AnimatedContainer(
              duration: HrMotion.of(context, HrMotion.base),
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(HrRadius.md - 3),
                gradient: on
                    ? const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [HrColors.goldBright, HrColors.goldDeep],
                      )
                    : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style: HrText.bodyS.copyWith(
                        color: on ? HrColors.onBtnPrimary : HrColors.text2,
                        fontWeight: FontWeight.w900)),
                if (badge != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: on ? const Color(0x33000000) : HrColors.goldSurface,
                      borderRadius: BorderRadius.circular(HrRadius.xs),
                    ),
                    child: Text(badge,
                        style: HrText.micro.copyWith(
                            color: on ? HrColors.onBtnPrimary : HrColors.gold,
                            fontWeight: FontWeight.w900)),
                  ),
                ],
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1220),
        borderRadius: BorderRadius.circular(HrRadius.md),
        border: Border.all(color: HrColors.cardEdge),
      ),
      child: Row(children: [
        seg('monthly', 'Monthly'),
        seg('annual', 'Yearly', badge: 'Save $kPremiumAnnualSavingsPct%'),
      ]),
    );
  }

  Widget _tierCard({
    required String name,
    required String price,
    required String per,
    required List<String> features,
    bool premium = false,
  }) =>
      HrCard(
        highlight: premium,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (premium) ...[
              const Icon(Icons.workspace_premium_rounded,
                  size: 18, color: HrColors.gold),
              const SizedBox(width: 4),
            ],
            Expanded(child: Text(name, style: HrText.headline)),
            if (premium) const HrCheck(done: true, size: 20),
          ]),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(TextSpan(children: [
              TextSpan(text: price, style: HrText.title1),
              TextSpan(text: ' $per', style: HrText.caption),
            ])),
          ),
          const SizedBox(height: 10),
          for (final f in features)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_rounded,
                    size: 15, color: premium ? HrColors.gold : HrColors.text2),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(f,
                      style: HrText.micro.copyWith(
                          color: premium ? HrColors.text : HrColors.text2)),
                ),
              ]),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, purchases]),
      builder: (context, _) {
        final premium = appState.isPremium;
        final annual = _plan == 'annual';
        final price = annual
            ? purchases.priceFor('annual', kPremiumAnnualPrice)
            : purchases.priceFor('monthly', kPremiumMonthlyPrice);
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 32),
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.workspace_premium_rounded,
                        size: 40, color: HrColors.gold),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: 'Habitrail\n', style: HrText.display),
                        TextSpan(
                            text: 'Premium',
                            style: HrText.display.copyWith(color: HrColors.gold)),
                      ]),
                    ),
                    const SizedBox(height: 6),
                    Text(
                        premium
                            ? 'Thanks for supporting Habitrail.'
                            : 'More progress. More together.',
                        style: HrText.bodyS),
                  ]),
                ),
                const HrHeroArt(width: 140, height: 160),
              ]),
              const SizedBox(height: 18),
              if (premium) ...[
                HrCard(
                  highlight: true,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const HrCheck(done: true, size: 22),
                          const SizedBox(width: 10),
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
                ..._props(),
                const SizedBox(height: 18),
                HrButton(
                    label: 'Manage subscription',
                    kind: HrButtonKind.secondary,
                    onPressed: _manage),
              ] else ...[
                ..._props(),
                const SizedBox(height: 14),
                _planToggle(),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _tierCard(
                          name: 'Free',
                          price: r'$0',
                          per: '',
                          features: const [
                            'Core habit tracking',
                            'Join parties & guilds',
                            'Basic companion',
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _tierCard(
                          name: 'Premium',
                          premium: true,
                          price: price,
                          per: annual ? '/ year' : '/ month',
                          features: [
                            'All Free features',
                            if (annual) '≈ $kPremiumAnnualPerMonth / month',
                            'AI coach & plans',
                            'Advanced insights',
                            'Companion skins',
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                HrButton(
                  label: purchases.busy
                      ? 'Processing…'
                      : 'Start Premium — $price${annual ? '/yr' : '/mo'}',
                  icon: Icons.workspace_premium_rounded,
                  loading: purchases.busy,
                  onPressed: purchases.busy ? null : _start,
                ),
                if (purchases.error != null) ...[
                  const SizedBox(height: 8),
                  Text(purchases.error!,
                      style: HrText.caption.copyWith(color: HrColors.dangerText),
                      textAlign: TextAlign.center),
                ],
                if (purchases.available)
                  Center(
                    child: TextButton(
                        onPressed: purchases.restore,
                        child: Text('Restore purchases', style: HrText.caption)),
                  ),
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
        child: _premiumLockCard(context, 'Challenges are Premium',
            'Unlock to start a guided program'),
      );

  Widget _activeCard(BuildContext context, ChallengeDef c) {
    final done = appState.challengeCheckInCount;
    final checkedToday = appState.challengeCheckedInToday;
    final dots = c.days <= 10 ? c.days : 10; // 30-day programs show tenths
    final lit = c.days <= 10 ? done : (done * 10 / c.days).floor();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: HrCard(
        highlight: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emoji_events_rounded, color: HrColors.gold, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Active challenge',
                    style: HrText.micro.copyWith(color: HrColors.text2)),
                Text(c.title,
                    style: HrText.headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ]),
            ),
            Text.rich(TextSpan(children: [
              TextSpan(text: '$done', style: HrText.title2.copyWith(color: HrColors.gold)),
              TextSpan(text: ' / ${c.days}', style: HrText.title2.copyWith(color: HrColors.text2)),
            ])),
          ]),
          const SizedBox(height: 6),
          Text(c.focus, style: HrText.bodyS.copyWith(color: HrColors.text2)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < dots; i++)
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: i < lit
                        ? const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [HrColors.goldBright, HrColors.goldDeep])
                        : null,
                    color: i < lit ? null : const Color(0xFF1C1F33),
                    border: i < lit ? null : Border.all(color: HrColors.cardEdge),
                    boxShadow: i < lit
                        ? [BoxShadow(color: HrColors.gold.withValues(alpha: 0.45), blurRadius: 8)]
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _challengeMilestones(c.days, done),
          const SizedBox(height: 16),
          if (checkedToday)
            Row(children: [
              const HrCheck(done: true, size: 22),
              const SizedBox(width: 10),
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
      child: HrQuestRow(
        title: c.title,
        done: done,
        leading: HrIconTile(icon: c.icon, size: 52),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.blurb,
              style: HrText.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Row(children: [
            _challengeDayTag(c.days),
            if (isActive) ...[
              const SizedBox(width: 8),
              Expanded(child: HrXpBar(value: appState.challengeProgress, height: 7)),
            ],
          ]),
        ]),
        trailing: isActive
            ? Text('${appState.challengeCheckInCount}/${c.days}',
                style: HrText.bodyS.copyWith(color: HrColors.gold, fontWeight: FontWeight.w900))
            : done
                ? const HrCheck(done: true, size: 30)
                : HrButton(
                    label: 'Start',
                    small: true,
                    expand: false,
                    kind: HrButtonKind.accent,
                    onPressed: () => _start(context, c),
                  ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ChallengeFilter(builder: (context, seg, segmented) {
      return ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final active = appState.activeChallenge;
          final shown = kChallenges
              .where((c) => seg == 0 || (seg == 1 ? c.days <= 7 : c.days > 7))
              .toList();
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const HrAppBarTitle('Challenges',
                  subtitle: 'Push your limits. Build a better you.'),
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(
                  HrSpace.gutter, 6, HrSpace.gutter, 28),
              children: [
                segmented,
                const SizedBox(height: 16),
                if (!appState.isPremium) _premiumBanner(context),
                if (active != null) _activeCard(context, active),
                const HrLabel('Programs'),
                ...shown.map((c) => _catalogTile(context, c)),
              ],
            ),
          );
        },
      );
    });
  }
}

/// Holds the All / 7-day / 30-day filter for the stateless challenges page.
class _ChallengeFilter extends StatefulWidget {
  const _ChallengeFilter({required this.builder});
  final Widget Function(BuildContext context, int seg, Widget segmented) builder;
  @override
  State<_ChallengeFilter> createState() => _ChallengeFilterState();
}

class _ChallengeFilterState extends State<_ChallengeFilter> {
  int _seg = 0;
  @override
  Widget build(BuildContext context) => widget.builder(
        context,
        _seg,
        HrSegmented(
          items: const ['All', '7-day', '30-day'],
          index: _seg,
          onChanged: (i) => setState(() => _seg = i),
        ),
      );
}

/// Shared Premium upsell card for locked features.
Widget _premiumLockCard(BuildContext context, String title, String sub) => HrCard(
  onTap: () => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const PremiumScreen())),
  child: Row(children: [
    const HrIconTile(
        icon: Icons.workspace_premium_rounded, color: HrColors.gold, size: 44),
    const SizedBox(width: 12),
    Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: HrText.headline),
      const SizedBox(height: 2),
      Text(sub, style: HrText.caption),
    ])),
    _lockPill(),
  ]),
);

// ── Premium: Streak recovery ────────────────────────────────────────────────
class RecoveryScreen extends StatelessWidget {
  const RecoveryScreen({super.key});

  void _restDay(BuildContext context) {
    if (!appState.isPremium) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const PremiumScreen()));
      return;
    }
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

  Widget _resetTile({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    required String action,
    required VoidCallback? onTap,
  }) =>
      HrCard(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
        radius: HrRadius.md,
        child: Column(children: [
          Icon(icon, size: 34, color: color, shadows: [
            Shadow(color: color.withValues(alpha: 0.6), blurRadius: 14),
          ]),
          const SizedBox(height: 6),
          Text(title,
              textAlign: TextAlign.center,
              style: HrText.bodyS.copyWith(
                  color: HrColors.text, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Expanded(
            child: Text(body,
                textAlign: TextAlign.center,
                style: HrText.micro.copyWith(color: HrColors.text2)),
          ),
          const SizedBox(height: 6),
          HrPressable(
            onTap: onTap,
            child: Container(
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: onTap == null ? HrColors.surface2 : HrColors.accent,
                borderRadius: BorderRadius.circular(HrRadius.sm),
                boxShadow: onTap == null
                    ? null
                    : [BoxShadow(color: HrColors.accent.withValues(alpha: 0.4), blurRadius: 10)],
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(action,
                      style: HrText.micro.copyWith(
                          color: onTap == null ? HrColors.text2 : HrColors.text,
                          fontWeight: FontWeight.w900)),
                ),
              ),
            ),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final premium = appState.isPremium;
        final left = appState.premiumStreakSavesLeft;
        final resting = appState.restDayActiveToday;
        final shields = appState.streakShields;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Recovery',
                subtitle: 'Rest, reset, and keep your streak alive.'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Streak Repair', style: HrText.title2),
                                const SizedBox(height: 6),
                                Text(
                                    'Missed a day? No worries. Shields'
                                    '${premium ? ' and your Premium saves' : ''} '
                                    'are spent automatically to keep your streak going.',
                                    style: HrText.bodyS),
                              ]),
                        ),
                        const SizedBox(width: 10),
                        Column(children: [
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Image.asset('assets/powerups/streak_shield.png',
                                width: 40, height: 40),
                            const SizedBox(width: 6),
                            Text('$shields',
                                style: HrText.title1.copyWith(color: HrColors.gold)),
                          ]),
                          Text('Streak shields',
                              style: HrText.micro.copyWith(color: HrColors.text2)),
                        ]),
                      ]),
                      if (premium) ...[
                        const SizedBox(height: 14),
                        Row(children: [
                          Text('Premium saves',
                              style: HrText.bodyS.copyWith(
                                  color: HrColors.text, fontWeight: FontWeight.w800)),
                          const Spacer(),
                          Text('$left of $kPremiumStreakSavesPerMonth',
                              style: HrText.bodyS.copyWith(
                                  color: HrColors.gold, fontWeight: FontWeight.w900)),
                        ]),
                        const SizedBox(height: 6),
                        HrXpBar(
                            value: left / kPremiumStreakSavesPerMonth,
                            height: 8,
                            color: HrColors.accent),
                        const SizedBox(height: 4),
                        Text('Refreshes at the start of each month.',
                            style: HrText.micro),
                      ],
                      const SizedBox(height: 14),
                      HrButton(
                        label: 'Get Streak Shields',
                        icon: Icons.shield_rounded,
                        kind: HrButtonKind.accent,
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const ShopScreen())),
                      ),
                    ]),
              ),
              const SizedBox(height: 18),
              const HrLabel('Take a reset'),
              SizedBox(
                height: 200,
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: _resetTile(
                      icon: Icons.nightlight_round,
                      color: const Color(0xFFB07CFF),
                      title: 'Rest Day',
                      body: premium
                          ? "It's okay to pause. Uses one save."
                          : 'Planned rest days are Premium.',
                      action: resting
                          ? 'Resting today'
                          : (premium ? 'Take Rest Day' : 'Unlock'),
                      onTap: resting || (premium && left <= 0)
                          ? null
                          : () => _restDay(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _resetTile(
                      icon: Icons.eco_rounded,
                      color: HrColors.success,
                      title: 'Focus Reset',
                      body: 'A short focus session to get back on track.',
                      action: 'Open Focus',
                      onTap: () {
                        shellTab.value = 1;
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _resetTile(
                      icon: Icons.spa_rounded,
                      color: const Color(0xFFFF6EB4),
                      title: 'Mindful Break',
                      body: 'Write a quick reflection to reset your head.',
                      action: 'Reflect',
                      onTap: () => showAddReflection(context),
                    ),
                  ),
                ]),
              ),
              if (!premium) ...[
                const SizedBox(height: 16),
                _premiumLockCard(context, 'Streak protection is Premium',
                    'Monthly streak-saves & planned rest days'),
              ],
            ],
          ),
        );
      },
    );
  }
}

// A sheet or dialog's future completes as soon as it starts closing, while
// its text fields still paint during the exit animation — so controllers
// are disposed only after that animation has finished.
void _disposeAfterClose(List<ChangeNotifier> controllers) {
  Future<void>.delayed(const Duration(milliseconds: 600), () {
    for (final c in controllers) {
      c.dispose();
    }
  });
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
            HrCheck(done: done, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.icon.isEmpty ? t.title : '${t.icon}  ${t.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(
                          fontWeight: FontWeight.w700,
                          color: done ? HrColors.text2 : HrColors.text,
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
                    Text('Tasks', style: HrText.headline),
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

// Quest-style task card for the Tasks screen: tile, title, XP chip, check.
Widget _taskRow(BuildContext context, TaskItem t) {
  final done = appState.taskDoneToday(t);
  final meta = _taskMeta(t);
  final daily = t.kind == TaskKind.daily;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: HrQuestRow(
      title: t.title,
      done: done,
      leading: t.icon.trim().isEmpty
          ? HrIconTile(
              icon: daily ? Icons.repeat_rounded : Icons.event_note_rounded,
              color: daily ? const Color(0xFF62D5FF) : const Color(0xFFFF9F43),
              size: 52)
          : HrIconTile(emoji: t.icon, size: 52),
      subtitle: Row(children: [
        HrXpChip(daily ? kDailyXp : kTodoXp),
        if (meta.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HrText.micro.copyWith(color: HrColors.text2)),
          ),
        ],
      ]),
      onTap: () => appState.toggleTask(t),
      onLongPress: () => _showTaskEditor(context, existing: t),
    ),
  );
}

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  int _seg = 0; // Today · Dailies · To-Dos

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final items = switch (_seg) {
          0 => [...appState.dailiesToday, ...appState.openTodos],
          1 => appState.allDailies,
          _ => appState.allTodos,
        };
        final empty = switch (_seg) {
          0 => 'Nothing due today — add a daily or a to-do.',
          1 => 'No dailies yet — add a recurring task.',
          _ => 'No to-dos yet — add a one-off task.',
        };
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Tasks',
                subtitle: 'Turn good habits into epic progress.'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: HrHeaderButton(
                  icon: Icons.add_rounded,
                  tooltip: 'New task',
                  color: HrColors.text,
                  onPressed: () => _showTaskEditor(context),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrSegmented(
                items: const ['Today', 'Dailies', 'To-Dos'],
                index: _seg,
                onChanged: (i) => setState(() => _seg = i),
              ),
              const SizedBox(height: 16),
              if (items.isEmpty)
                HrCard(
                  padding: const EdgeInsets.all(18),
                  child: Text(empty, style: HrText.bodyS),
                )
              else
                for (final t in items) _taskRow(context, t),
              const SizedBox(height: 8),
              Text('Tap to check off · long-press to edit',
                  textAlign: TextAlign.center, style: HrText.micro),
              const SizedBox(height: 16),
              HrButton(
                  label: 'Add a task',
                  icon: Icons.add_rounded,
                  kind: HrButtonKind.accent,
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
      counterText: '',
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
  ).whenComplete(() => _disposeAfterClose([titleCtrl, iconCtrl]));
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final name = (_party?['name'] ?? 'My Party').toString();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: HrAppBarTitle(_party == null ? 'Party' : name,
            subtitle: 'Stay consistent together.'),
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (!backendEnabled || currentUserId == null) {
      return _socialGate(context, Icons.groups_rounded, 'Parties need an account',
          'Sign in to start a party and invite friends to a shared weekly goal.');
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_party == null) return _noParty(context);
    return _partyView(context);
  }

  Widget _noParty(BuildContext context) => ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
        children: [
          const Center(child: HrHeroArt(width: 160, height: 150)),
          const SizedBox(height: 8),
          HrCard(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                const HrLabel('Start a party'),
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
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                const HrLabel('Join with a code'),
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

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    hrToast(context, 'Invite code copied', icon: Icons.copy_rounded);
  }

  Widget _memberAvatar(Map<String, dynamic> m, {required bool owner}) {
    final name = (m['name'] ?? m['username'] ?? 'Player').toString();
    final isMe = m['id'] == currentUserId;
    return SizedBox(
      width: 64,
      child: Column(children: [
        Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: owner ? HrColors.gold : HrColors.accentBright, width: 2),
              boxShadow: [
                BoxShadow(
                    color: (owner ? HrColors.gold : HrColors.accent)
                        .withValues(alpha: 0.4),
                    blurRadius: 10),
              ],
            ),
            child: isMe
                ? _Avatar(size: 48)
                : _FriendAvatar(
                    name: name,
                    borderId: (m['border_id'] ?? 'none').toString(),
                    size: 48),
          ),
          if (owner)
            const Positioned(
              top: -14,
              child: SizedBox(
                  width: 22, height: 16, child: CustomPaint(painter: _CrownPainter())),
            ),
        ]),
        const SizedBox(height: 4),
        Text(isMe ? 'You' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HrText.micro.copyWith(
                color: isMe ? HrColors.gold : HrColors.text,
                fontWeight: FontWeight.w800)),
      ]),
    );
  }

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
    final members = [..._members]
      ..sort((a, b) => _memberGain(b).compareTo(_memberGain(a)));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding:
            const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
        children: [
          // Member avatars with the owner crowned, then an invite bubble.
          SizedBox(
            height: 92,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(top: 14),
              children: [
                for (final m in _members) ...[
                  _memberAvatar(m, owner: m['id'] == p['owner_id']),
                  const SizedBox(width: 8),
                ],
                Semantics(
                  button: true,
                  label: 'Copy invite code',
                  child: GestureDetector(
                    onTap: () => _copyCode(code),
                    child: SizedBox(
                      width: 64,
                      child: Column(children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: HrColors.surface,
                            border: Border.all(color: HrColors.cardEdge, width: 1.5),
                          ),
                          child: const Icon(Icons.add_rounded, color: HrColors.text2),
                        ),
                        const SizedBox(height: 4),
                        Text('Invite',
                            style: HrText.micro.copyWith(color: HrColors.text2)),
                      ]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          HrCard(
            onTap: () => _copyCode(code),
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            radius: HrRadius.md,
            child: Row(children: [
              const Icon(Icons.key_rounded, size: 20, color: HrColors.gold),
              const SizedBox(width: 10),
              Text('Invite code', style: HrText.bodyS),
              const Spacer(),
              Text(code, style: HrText.headline.copyWith(letterSpacing: 2)),
              const SizedBox(width: 8),
              const Icon(Icons.copy_rounded, size: 16, color: HrColors.text3),
            ]),
          ),
          const SizedBox(height: 12),
          // Weekly co-op quest.
          HrCard(
            highlight: defeated && !claimed,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                HrIconTile(emoji: quest?.emoji ?? '⚔️', size: 52),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Weekly co-op quest',
                        style: HrText.micro.copyWith(color: HrColors.text2)),
                    Text(quest?.name ?? 'No quest yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.headline),
                  ]),
                ),
                if (owner)
                  HrButton(
                    label: quest == null ? 'Start' : 'Change',
                    small: true,
                    expand: false,
                    kind: HrButtonKind.accent,
                    onPressed: _pickQuest,
                  ),
              ]),
              const SizedBox(height: 12),
              if (quest != null) ...[
                Row(children: [
                  Expanded(
                    child: HrXpBar(
                        value: (gained / quest.target).clamp(0.0, 1.0), height: 10),
                  ),
                  const SizedBox(width: 10),
                  Text.rich(TextSpan(children: [
                    TextSpan(
                        text: hrNum(gained),
                        style: HrText.bodyS.copyWith(
                            color: HrColors.gold, fontWeight: FontWeight.w900)),
                    TextSpan(
                        text: ' / ${hrNum(quest.target)} XP',
                        style: HrText.bodyS.copyWith(color: HrColors.text2)),
                  ])),
                ]),
                const SizedBox(height: 10),
                if (defeated)
                  claimed
                      ? Row(children: [
                          const HrCheck(done: true, size: 20),
                          const SizedBox(width: 8),
                          Text('Boss defeated — reward claimed',
                              style: HrText.caption.copyWith(color: HrColors.gold)),
                        ])
                      : HrButton(
                          label: 'Boss down! Claim +${quest.reward} coins',
                          icon: Icons.emoji_events_rounded,
                          onPressed: () => _claimQuest(claimKey, quest.reward),
                        )
                else
                  Row(children: [
                    Icon(Icons.groups_rounded, size: 18, color: HrColors.accentBright),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('+${quest.reward} coins each when the party wins',
                          style: HrText.caption.copyWith(color: HrColors.text2)),
                    ),
                  ]),
              ] else
                Text(
                    owner
                        ? 'Start a co-op quest — the party fights a boss together.'
                        : "The owner hasn't started a quest yet.",
                    style: HrText.bodyS),
            ]),
          ),
          const SizedBox(height: 10),
          HrButton(
            label: 'Party chat',
            icon: Icons.chat_bubble_rounded,
            kind: HrButtonKind.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PartyChatScreen(
                    partyId: p['id'].toString(),
                    title: (p['name'] ?? 'Party').toString()))),
          ),
          const SizedBox(height: 18),
          const HrLabel("This week's progress"),
          HrMenuGroup(children: members.map(_memberRow).toList()),
          const SizedBox(height: 18),
          Center(
              child: TextButton(
                  onPressed: _leave,
                  child: Text(owner ? 'Disband party' : 'Leave party',
                      style: HrText.bodyS.copyWith(color: HrColors.dangerText)))),
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
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(children: [
        isMe
            ? _Avatar(size: 40)
            : _FriendAvatar(
                name: name,
                borderId: (m['border_id'] ?? 'none').toString(),
                size: 40),
        const SizedBox(width: 12),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
                child: Text(isMe ? 'You' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w800))),
          ]),
          Text('Level ${ld.level}', style: HrText.caption),
        ])),
        if (gain > 0) ...[HrXpChip(gain), const SizedBox(width: 10)],
        Image.asset('assets/streaks/enamel_flame.png', width: 18, height: 18),
        const SizedBox(width: 3),
        Text('$streak',
            style: HrText.bodyS.copyWith(
                color: HrColors.text2, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// Signed-out gate for the social screens, with a way to sign in.
Widget _socialGate(BuildContext context, IconData icon, String title, String body) =>
    Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          HrHeroArt(
            width: 170,
            height: 150,
            child: HrIconTile(icon: icon, size: 76),
          ),
          const SizedBox(height: 12),
          Text(title, style: HrText.title2, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(body, style: HrText.bodyS, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          HrButton(
            label: 'Sign in or create account',
            icon: Icons.login_rounded,
            kind: HrButtonKind.accent,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LoginScreen())),
          ),
        ]),
      ),
    );

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
            child: _chatComposer(
              controller: _ctrl,
              hint: 'Say something to your party',
              sending: _sending,
              onSend: _send),
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
      child: _chatBubble(
          mine: mine,
          author: author,
          body: body,
          time: m['created_at']?.toString()),
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
    ).whenComplete(() => _disposeAfterClose([nameCtrl, descCtrl]));
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = backendEnabled && currentUserId != null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const HrAppBarTitle('Guilds',
            subtitle: 'Find your people. Build better habits together.'),
        actions: signedIn
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: HrHeaderButton(
                      icon: Icons.add_rounded,
                      tooltip: 'New guild',
                      color: HrColors.text,
                      onPressed: _create),
                ),
              ]
            : null,
      ),
      body: !signedIn
          ? _socialGate(context, Icons.shield_rounded, 'Guilds need an account',
              'Sign in to discover and join public guilds.')
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    HrSpace.gutter, 6, HrSpace.gutter, 12),
                child: HrFilterChips(
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
          TextField(
            controller: _searchCtrl,
            style: HrText.body,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: 'Search guilds…',
              prefixIcon: const Icon(Icons.search_rounded, color: HrColors.text2),
              suffixIcon: IconButton(
                tooltip: 'Search',
                onPressed: _load,
                icon: const Icon(Icons.arrow_forward_rounded, color: HrColors.text2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (_discover.isEmpty)
            HrCard(
              padding: const EdgeInsets.all(18),
              child: Text('No guilds yet — create the first one.',
                  style: HrText.bodyS),
            )
          else
            ..._discover.map((g) => _guildCard(g, showJoin: true)),
        ],
      );

  Widget _mineTab() => _mine.isEmpty
      ? ListView(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 28),
          children: [
            HrCard(
              padding: const EdgeInsets.all(18),
              child: Text("You haven't joined any guilds yet. Find one in Discover.",
                  style: HrText.bodyS),
            ),
          ],
        )
      : ListView(
          padding:
              const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 28),
          children: _mine.map((g) => _guildCard(g, showJoin: false)).toList(),
        );

  Widget _guildCard(Map<String, dynamic> g, {required bool showJoin}) {
    final isMember = g['is_member'] == true;
    final count = (g['member_count'] as num?)?.toInt() ?? 0;
    final desc = (g['description'] ?? '').toString();
    final name = (g['name'] ?? 'Guild').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HrCard(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => GuildDetailScreen(
                  guildId: g['id'].toString(),
                  name: name,
                  description: desc,
                  ownerId: (g['owner_id'] ?? '').toString(),
                  goalTarget: (g['goal_target'] as num?)?.toInt() ?? 0,
                  goalWeek: (g['goal_week'] ?? '').toString())));
          await _load();
        },
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(children: [
          HrIconTile(icon: Icons.shield_rounded, color: _guildTint(name), size: 54),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(name,
                    style: HrText.headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.groups_rounded, size: 14, color: HrColors.gold),
                  const SizedBox(width: 4),
                  Text('${hrNum(count)} member${count == 1 ? '' : 's'}',
                      style: HrText.micro.copyWith(color: HrColors.text2)),
                ]),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(desc,
                      style: HrText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ])),
          const SizedBox(width: 10),
          if (showJoin && !isMember)
            HrButton(
                label: 'Join',
                small: true,
                expand: false,
                onPressed: () => _join(g))
          else if (isMember)
            const HrCheck(done: true, size: 28)
          else
            const Icon(Icons.chevron_right_rounded, color: HrColors.text2),
        ]),
      ),
    );
  }
}

// Stable colour per guild name for its icon tile.
Color _guildTint(String name) =>
    _kQuestTints[name.codeUnits.fold<int>(0, (a, c) => a + c) % _kQuestTints.length];

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
    _disposeAfterClose([ctrl]);
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

  void _invite() {
    SharePlus.instance.share(ShareParams(
      text: 'Join my guild "${widget.name}" on Habitrail — '
          'search for it in Friends → Guilds and build better habits with us.',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final gained = _members.fold<int>(0, (a, m) => a + _memberGain(m));
    final pct = _goalTarget > 0 ? (gained / _goalTarget).clamp(0.0, 1.0) : 0.0;
    final bestStreak = _members.fold<int>(
        0, (a, m) => max(a, (m['streak'] as num?)?.toInt() ?? 0));
    final members = [..._members]
      ..sort((a, b) => ((b['total_xp'] as num?) ?? 0)
          .compareTo((a['total_xp'] as num?) ?? 0));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: HrAppBarTitle(widget.name,
            subtitle: widget.description.isEmpty ? 'Guild' : widget.description),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  HrSpace.gutter, 6, HrSpace.gutter, 28),
              children: [
                Row(children: [
                  Expanded(
                    child: HrStatTile(
                      value: '${_members.length}',
                      label: 'Members',
                      leading: Icon(Icons.groups_rounded,
                          size: 28, color: HrColors.accentBright),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: HrStatTile(
                      value: '$bestStreak',
                      label: 'Best streak',
                      leading: Image.asset('assets/streaks/enamel_flame.png',
                          width: 28, height: 28),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: HrStatTile(
                      value: hrNum(gained),
                      label: 'XP this week',
                      leading: const Icon(Icons.emoji_events_rounded,
                          size: 28, color: HrColors.gold),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                HrCard(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      Row(children: [
                        const HrIconTile(emoji: '⚔️', size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Shared challenge',
                                    style: HrText.micro
                                        .copyWith(color: HrColors.text2)),
                                Text('Weekly guild goal', style: HrText.headline),
                              ]),
                        ),
                        if (_isOwner)
                          HrButton(
                            label: _goalTarget > 0 ? 'Edit' : 'Set',
                            small: true,
                            expand: false,
                            kind: HrButtonKind.accent,
                            onPressed: _setGoal,
                          ),
                      ]),
                      const SizedBox(height: 12),
                      if (_goalTarget > 0)
                        Row(children: [
                          Expanded(child: HrXpBar(value: pct, height: 10)),
                          const SizedBox(width: 10),
                          Text.rich(TextSpan(children: [
                            TextSpan(
                                text: hrNum(gained),
                                style: HrText.bodyS.copyWith(
                                    color: HrColors.gold,
                                    fontWeight: FontWeight.w900)),
                            TextSpan(
                                text: ' / ${hrNum(_goalTarget)} XP',
                                style: HrText.bodyS
                                    .copyWith(color: HrColors.text2)),
                          ])),
                        ])
                      else
                        Text(
                            _isOwner
                                ? 'Set a combined weekly XP target for the guild.'
                                : "The owner hasn't set a goal yet.",
                            style: HrText.bodyS),
                    ])),
                const SizedBox(height: 10),
                HrButton(
                  label: 'Guild chat',
                  icon: Icons.chat_bubble_rounded,
                  kind: HrButtonKind.secondary,
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => GuildChatScreen(
                              guildId: widget.guildId, title: widget.name))),
                ),
                const SizedBox(height: 18),
                HrLabel('Members (${_members.length})'),
                HrMenuGroup(children: members.map(_row).toList()),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(
                    child: HrButton(
                      label: 'Leave guild',
                      kind: HrButtonKind.secondary,
                      onPressed: _leave,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: HrButton(
                      label: 'Invite friends',
                      icon: Icons.ios_share_rounded,
                      onPressed: _invite,
                    ),
                  ),
                ]),
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
    final isOwner = m['id'] == widget.ownerId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(children: [
        isMe
            ? _Avatar(size: 40)
            : _FriendAvatar(
                name: name,
                borderId: (m['border_id'] ?? 'none').toString(),
                size: 40),
        const SizedBox(width: 12),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(
                child: Text(isMe ? 'You' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w800))),
            if (isOwner) ...[
              const SizedBox(width: 6),
              const SizedBox(
                  width: 18, height: 13, child: CustomPaint(painter: _CrownPainter())),
            ],
          ]),
          Row(children: [
            Image.asset('assets/streaks/enamel_flame.png', width: 13, height: 13),
            const SizedBox(width: 3),
            Text(
                _goalTarget > 0
                    ? '$streak · +${hrNum(_memberGain(m))} XP this week'
                    : '$streak day streak',
                style: HrText.caption),
          ]),
        ])),
        Text('Level ${ld.level}',
            style: HrText.bodyS.copyWith(
                color: HrColors.text2, fontWeight: FontWeight.w800)),
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
            child: _chatComposer(
              controller: _ctrl,
              hint: 'Say something to your guild',
              sending: _sending,
              onSend: _send),
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
      child: _chatBubble(
          mine: mine,
          author: author,
          body: body,
          time: m['created_at']?.toString()),
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
        title: const HrAppBarTitle('Global chat',
            subtitle: 'A kind place for real progress.'),
      ),
      body: !_signedIn
          ? _socialGate(context, Icons.forum_rounded,
              'Sign in to join the global chat',
              'Everyone with an account can talk here — no joining.')
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
                  child: _chatComposer(
                    controller: _ctrl,
                    hint: 'Say something to everyone',
                    sending: _sending,
                    onSend: _send),
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
      child: _chatBubble(
          mine: mine,
          author: author,
          body: body,
          time: m['created_at']?.toString()),
    );
  }
}

String _chatTime(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// One chat message: avatar + name + time over a navy bubble, or a violet
// right-aligned bubble for your own messages.
Widget _chatBubble({
  required bool mine,
  required String author,
  required String body,
  String? time,
}) {
  final t = _chatTime(time);
  final bubble = Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      gradient: mine
          ? LinearGradient(colors: [
              Color.lerp(HrColors.accent, Colors.white, 0.12)!,
              HrColors.accent,
            ])
          : null,
      color: mine ? null : HrColors.surface2,
      border: mine ? null : Border.all(color: HrColors.cardEdge),
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(mine ? 16 : 4),
        topRight: Radius.circular(mine ? 4 : 16),
        bottomLeft: const Radius.circular(16),
        bottomRight: const Radius.circular(16),
      ),
      boxShadow: mine
          ? [BoxShadow(color: HrColors.accent.withValues(alpha: 0.35), blurRadius: 12)]
          : null,
    ),
    child: Text(body,
        style: HrText.bodyS.copyWith(color: HrColors.text, fontWeight: FontWeight.w600)),
  );
  final meta = Text.rich(TextSpan(children: [
    TextSpan(
      text: mine ? 'You' : author,
      style: HrText.micro.copyWith(color: HrColors.text, fontWeight: FontWeight.w800),
    ),
    if (t.isNotEmpty)
      TextSpan(text: '  $t', style: HrText.micro.copyWith(color: HrColors.text3)),
  ]));
  if (mine) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 56),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        meta,
        const SizedBox(height: 4),
        bubble,
      ]),
    );
  }
  return Padding(
    padding: const EdgeInsets.only(bottom: 12, right: 40),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [HrColors.accentBright, kBlue]),
          border: Border.all(color: HrColors.cardEdge),
        ),
        child: Text(author.isEmpty ? '?' : author[0].toUpperCase(),
            style: HrText.bodyS.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          meta,
          const SizedBox(height: 4),
          bubble,
        ]),
      ),
    ]),
  );
}

// Pill message field with a violet send button.
Widget _chatComposer({
  required TextEditingController controller,
  required String hint,
  required bool sending,
  required VoidCallback onSend,
}) =>
    Row(children: [
      Expanded(
        child: TextField(
          controller: controller,
          style: HrText.body,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => onSend(),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: HrColors.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.full),
              borderSide: const BorderSide(color: HrColors.cardEdge),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.full),
              borderSide: const BorderSide(color: HrColors.cardEdge),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(HrRadius.full),
              borderSide: BorderSide(color: HrColors.accent, width: 1.5),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Semantics(
        button: true,
        label: 'Send',
        child: HrPressable(
          onTap: sending ? null : onSend,
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [
                Color.lerp(HrColors.accent, Colors.white, 0.15)!,
                HrColors.accent,
              ]),
              boxShadow: [
                BoxShadow(color: HrColors.accent.withValues(alpha: 0.5), blurRadius: 12),
              ],
            ),
            child: sending
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send_rounded, color: Colors.white, size: 22),
          ),
        ),
      ),
    ]);

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
        const SizedBox.shrink(),
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
        decoration: HrCard.decoration(radius: HrRadius.xl, highlight: true),
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
            HrHeroArt(width: 190, height: 150, child: emblem),
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
            HrButton(
                label: buttonLabel,
                kind: HrButtonKind.accent,
                onPressed: () => Navigator.pop(ctx)),
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

// ── CALENDAR (Progress tab) ─────────────────────────────────────────────────
// A weekly streak ring + a month grid coloured by each day's victory score.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({this.embedded = false, super.key});
  final bool embedded;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

/// Page chrome for screens that can also be embedded: a transparent Scaffold
/// with the heavy page title when standalone, the bare body when embedded.
Widget _hrPage({
  required String title,
  required Widget body,
  String? subtitle,
  List<Widget>? actions,
  bool embedded = false,
}) =>
    embedded
        ? body
        : Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: HrAppBarTitle(title, subtitle: subtitle),
              actions: actions,
            ),
            body: body,
          );

/// Any activity recorded on a day (quests, focus, a perfect day or a score).
bool _activeOn(String k) =>
    (appState.dailyDone[k] ?? 0) > 0 ||
    (appState.dailyFocus[k] ?? 0) > 0 ||
    appState.perfectDays.contains(k) ||
    (appState.dailyScore[k] ?? 0) > 0;

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month;
  late DateTime _selected;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
    _selected = DateTime(now.year, now.month, now.day);
  }

  void _shift(int d) =>
      setState(() => _month = DateTime(_month.year, _month.month + d, 1));

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return _hrPage(
      title: 'Calendar',
      embedded: widget.embedded,
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 4, HrSpace.gutter, 32),
          children: [
            _monthCard(context, now),
            const SizedBox(height: 14),
            _dayCard(now),
          ],
        ),
      ),
    );
  }

  Widget _monthCard(BuildContext context, DateTime now) {
    final first = _month;
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final leading = first.weekday - 1; // Monday = 0 leading cells
    final todayK = dateKey(now);
    final atCurrentMonth = first.year == now.year && first.month == now.month;
    return HrCard(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _shift(-1),
                tooltip: 'Previous month',
                icon: const Icon(Icons.chevron_left_rounded, color: HrColors.text),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_kMonthsFull[first.month - 1]} ${first.year}',
                    style: HrText.headline,
                  ),
                ),
              ),
              IconButton(
                onPressed: atCurrentMonth ? null : () => _shift(1),
                tooltip: 'Next month',
                icon: Icon(Icons.chevron_right_rounded,
                    color: atCurrentMonth ? HrColors.textDisabled : HrColors.text),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final d in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
                Expanded(
                  child: Center(
                    child: Text(d,
                        style: HrText.micro.copyWith(color: HrColors.text2)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 0.9,
            children: [
              for (int i = 0; i < leading; i++) const SizedBox.shrink(),
              for (int day = 1; day <= daysInMonth; day++)
                _dayCell(DateTime(first.year, first.month, day), todayK, now),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(DateTime date, String todayK, DateTime now) {
    final k = dateKey(date);
    final isToday = k == todayK;
    final isSelected = dateKey(_selected) == k;
    final isFuture = date.isAfter(DateTime(now.year, now.month, now.day));
    final active = _activeOn(k);
    final perfect = appState.perfectDays.contains(k);
    return Semantics(
      button: !isFuture,
      selected: isSelected,
      label: '${date.day}${active ? ', active' : ''}${perfect ? ', perfect day' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: isFuture ? null : () => setState(() => _selected = date),
        child: Opacity(
          opacity: isFuture ? 0.35 : 1,
          child: AnimatedContainer(
            duration: HrMotion.of(context, HrMotion.base),
            decoration: BoxDecoration(
              gradient: isSelected
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [HrColors.accentBright, HrColors.accent],
                    )
                  : null,
              borderRadius: BorderRadius.circular(HrRadius.sm),
              border: isToday && !isSelected
                  ? Border.all(color: HrColors.accentBright, width: 1.4)
                  : null,
              boxShadow: isSelected
                  ? [BoxShadow(color: HrColors.accent.withValues(alpha: 0.55), blurRadius: 12)]
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${date.day}',
                  style: HrText.bodyS.copyWith(
                    color: isSelected || isToday ? HrColors.text : HrColors.text2,
                    fontWeight: isSelected || isToday ? FontWeight.w900 : FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active
                        ? (perfect ? HrColors.goldBright : HrColors.gold)
                        : Colors.transparent,
                    boxShadow: active
                        ? [BoxShadow(color: HrColors.gold.withValues(alpha: 0.6), blurRadius: 5)]
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The selected day: today's quests with their checks, or a past day's recap.
  Widget _dayCard(DateTime now) {
    final d = _selected;
    final k = dateKey(d);
    final isToday = k == dateKey(now);
    final done = isToday ? appState.doneTodayCount : (appState.dailyDone[k] ?? 0);
    final total = appState.habits.length;
    final score = appState.dailyScore[k];
    final focus = appState.dailyFocus[k] ?? 0;
    final xp = appState.dailyXp[k] ?? 0;
    return HrCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_kMonthsFull[d.month - 1]} ${d.day}, ${d.year}',
                  style: HrText.headline,
                ),
              ),
              if (isToday && total > 0)
                Text.rich(TextSpan(children: [
                  TextSpan(
                    text: '$done',
                    style: HrText.bodyS.copyWith(
                        color: HrColors.gold, fontWeight: FontWeight.w900),
                  ),
                  TextSpan(
                    text: ' / $total complete',
                    style: HrText.bodyS.copyWith(color: HrColors.text2),
                  ),
                ])),
            ],
          ),
          const SizedBox(height: 10),
          if (isToday && appState.habits.isNotEmpty)
            for (final h in appState.habits)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    _questIcon(h, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        h.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    HrCheck(done: appState.doneToday(h), size: 26),
                  ],
                ),
              )
          else if (!_activeOn(k))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('No activity recorded for this day.', style: HrText.bodyS),
            )
          else ...[
            if (score != null)
              _dayStat(Icons.insights_rounded, 'Victory score',
                  '$score · ${victoryLabel(score)}', HrColors.victory(score)),
            _dayStat(Icons.check_circle_rounded, 'Quests completed', '$done',
                HrColors.success),
            _dayStat(Icons.timer_rounded, 'Focus', '$focus min', HrColors.accentBright),
            _dayStat(Icons.auto_awesome, 'XP earned', hrNum(xp), HrColors.gold),
            if (appState.perfectDays.contains(k))
              _dayStat(Icons.stars_rounded, 'Perfect day', 'All habits done',
                  HrColors.goldBright),
          ],
        ],
      ),
    );
  }

  Widget _dayStat(IconData icon, String label, String value, Color color) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: HrText.body)),
            Text(value,
                style: HrText.bodyS.copyWith(
                    color: HrColors.text, fontWeight: FontWeight.w800)),
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

class StatsScreen extends StatefulWidget {
  const StatsScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  int _weekOffset = 0; // 0 = this week, -1 = last week

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  DateTime _monday(int offset) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day - (now.weekday - 1) + 7 * offset);
  }

  @override
  Widget build(BuildContext context) {
    return _hrPage(
      title: 'Stats',
      embedded: widget.embedded,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: PopupMenuButton<int>(
            tooltip: 'Choose week',
            initialValue: _weekOffset,
            onSelected: (v) => setState(() => _weekOffset = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('This week')),
              PopupMenuItem(value: -1, child: Text('Last week')),
            ],
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              decoration: BoxDecoration(
                color: HrColors.surface,
                borderRadius: BorderRadius.circular(HrRadius.sm),
                border: Border.all(color: HrColors.cardEdge),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_weekOffset == 0 ? 'This week' : 'Last week',
                      style: HrText.bodyS.copyWith(
                          color: HrColors.text, fontWeight: FontWeight.w700)),
                  const Icon(Icons.keyboard_arrow_down_rounded,
                      color: HrColors.text2),
                ],
              ),
            ),
          ),
        ),
      ],
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final mon = _monday(_weekOffset);
    final next = mon.add(const Duration(days: 7));
    final prevMon = mon.subtract(const Duration(days: 7));
    final xp = [
      for (var i = 0; i < 7; i++) appState.dailyXp[dateKey(mon.add(Duration(days: i)))] ?? 0,
    ];
    final now = DateTime.now();
    final elapsed = _weekOffset == 0 ? now.weekday : 7;
    final doneWeek = appState.sumDays(appState.dailyDone, mon, next);
    // Compare against the same number of days of the week before.
    final donePrev = appState.sumDays(
        appState.dailyDone, prevMon, prevMon.add(Duration(days: elapsed)));
    final change = donePrev == 0 ? null : ((doneWeek - donePrev) / donePrev * 100).round();
    final possible = appState.habits.length * elapsed;
    final pct = possible == 0 ? 0.0 : (doneWeek / possible).clamp(0.0, 1.0);
    final tiles = <(String, String, Widget)>[
      ('Level', '${ld.level}', Icon(Icons.workspace_premium_rounded, size: 28, color: HrColors.accentBright)),
      ('Perfect days', '${appState.totalPerfectDays}', const Icon(Icons.stars_rounded, size: 28, color: HrColors.goldBright)),
      ('Avg score 7d', '${appState.avgScoreLastDays(7).round()}', const Icon(Icons.insights_rounded, size: 28, color: HrColors.info)),
    ];
    // The premium/history cards below carry their own gutter.
    Widget g(Widget w) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
          child: w,
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 32),
      children: [
        g(_weekChart(xp, mon)),
        const SizedBox(height: 12),
        g(Row(
          children: [
            Expanded(
              child: HrStatTile(
                value: '${appState.bestStreak}',
                label: 'day streak',
                leading: Image.asset('assets/streaks/enamel_flame.png', width: 30, height: 30),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HrStatTile(
                value: hrNum(appState.totalXp),
                label: 'total XP',
                leading: const Icon(Icons.auto_awesome, size: 28, color: HrColors.gold),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HrStatTile(
                value: hrNum(doneWeek),
                label: 'habits done',
                leading: const Icon(Icons.emoji_events_rounded, size: 28, color: HrColors.gold),
              ),
            ),
          ],
        )),
        const SizedBox(height: 12),
        g(HrCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (change ?? 0) >= 0 && doneWeek > 0
                          ? "You're on fire! 🔥"
                          : 'Keep the trail going',
                      style: HrText.title2,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      change == null
                          ? 'You completed $doneWeek ${doneWeek == 1 ? 'habit' : 'habits'} ${_weekOffset == 0 ? 'this week' : 'that week'}.'
                          : 'You completed $doneWeek ${doneWeek == 1 ? 'habit' : 'habits'} ${_weekOffset == 0 ? 'this week' : 'that week'}, '
                              '${change.abs()}% ${change >= 0 ? 'more' : 'fewer'} than the same days the week before.',
                      style: HrText.bodyS,
                    ),
                  ],
                ),
              ),
              const HrHeroArt(width: 104, height: 104),
            ],
          ),
        )),
        const SizedBox(height: 12),
        g(HrCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 76,
                height: 76,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SegmentedRing(
                      size: 76,
                      segments: 1,
                      value: pct.toDouble(),
                      stroke: 8,
                      color: HrColors.gold,
                    ),
                    Text('${(pct * 100).round()}%',
                        style: HrText.headline.copyWith(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Weekly completion', style: HrText.headline),
                    const SizedBox(height: 4),
                    Text('$doneWeek of $possible habits', style: HrText.bodyS),
                  ],
                ),
              ),
            ],
          ),
        )),
        const SizedBox(height: 12),
        g(Row(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: HrStatTile(value: tiles[i].$2, label: tiles[i].$1, leading: tiles[i].$3),
              ),
            ],
          ],
        )),
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
        g(_legacyLink(context)),
      ],
    );
  }

  // Seven XP bars, the best day in gold with its total above it.
  Widget _weekChart(List<int> xp, DateTime mon) {
    final maxV = xp.fold<int>(0, max);
    final peak = maxV == 0 ? -1 : xp.indexOf(maxV);
    const chartH = 120.0;
    return HrCard(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        children: [
          SizedBox(
            height: chartH + 28,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (i == peak)
                          Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: HrColors.goldSurface,
                              borderRadius: BorderRadius.circular(HrRadius.xs),
                              border: Border.all(color: HrColors.gold),
                            ),
                            child: FittedBox(
                              child: Text('${hrNum(maxV)} XP',
                                  style: HrText.micro.copyWith(color: HrColors.gold)),
                            ),
                          ),
                        Container(
                          width: 26,
                          height: maxV == 0 ? 6 : max(6.0, chartH * xp[i] / maxV),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: i == peak
                                  ? const [HrColors.goldBright, HrColors.goldDeep]
                                  : [HrColors.accentBright, HrColors.accent],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (i == peak ? HrColors.gold : HrColors.accent)
                                    .withValues(alpha: 0.45),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Column(
                    children: [
                      Text(_days[i], style: HrText.micro.copyWith(color: HrColors.text2)),
                      const SizedBox(height: 4),
                      Icon(
                        Icons.auto_awesome,
                        size: 13,
                        color: _activeOn(dateKey(mon.add(Duration(days: i))))
                            ? HrColors.gold
                            : HrColors.surface3,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
        final streak = appState.bestStreak;
        final cardWidth = min(
          360.0,
          MediaQuery.sizeOf(context).width - HrSpace.gutter * 2,
        );
        Widget statLine(Widget icon, String value, String label) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                SizedBox(width: 28, child: Center(child: icon)),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(value,
                      style: HrText.title2.copyWith(height: 1.1)),
                  Text(label, style: HrText.micro.copyWith(color: HrColors.text2)),
                ]),
              ]),
            );
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Share progress',
                subtitle: 'Preview of your share image'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 32),
            children: [
              Center(
                child: RepaintBoundary(
                  key: _cardKey,
                  child: SizedBox(
                    width: cardWidth,
                    height: cardWidth * 16 / 9,
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF221548), Color(0xFF120E28), Color(0xFF0A0B12)],
                          stops: [0, 0.55, 1],
                        ),
                        borderRadius: BorderRadius.circular(HrRadius.xl),
                        border: Border.all(color: HrColors.accent.withValues(alpha: 0.6), width: 1.4),
                        boxShadow: [
                          BoxShadow(color: HrColors.accent.withValues(alpha: 0.35), blurRadius: 24),
                        ],
                      ),
                      child: Stack(
                        children: [
                          // Night landscape: moon, stars and mountains.
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            height: cardWidth * 0.95,
                            child: CustomPaint(
                                painter: _JournalLandscapePainter(HrColors.accent)),
                          ),
                          Positioned(
                            right: -12,
                            top: cardWidth * 0.42,
                            child: HrHeroArt(
                              width: cardWidth * 0.62,
                              height: cardWidth * 0.78,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.route_rounded,
                                      size: 17, color: HrColors.lavender),
                                  const SizedBox(width: 7),
                                  Text('HABITRAIL',
                                      style: HrText.caption.copyWith(
                                          color: HrColors.text,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 2.2)),
                                ]),
                                const SizedBox(height: 22),
                                Text('$streak day',
                                    style: HrText.displayXl.copyWith(fontSize: 52, height: 1)),
                                Text('streak',
                                    style: HrText.displayXl.copyWith(
                                        fontSize: 44, height: 1.05, color: HrColors.gold)),
                                const SizedBox(height: 26),
                                statLine(
                                    Image.asset('assets/streaks/enamel_flame.png',
                                        width: 24, height: 24),
                                    '$streak',
                                    streak == 1 ? 'day streak' : 'days in a row'),
                                statLine(
                                    const Icon(Icons.auto_awesome, color: HrColors.gold, size: 22),
                                    hrNum(appState.totalXp),
                                    'total XP'),
                                statLine(
                                    Icon(Icons.workspace_premium_rounded,
                                        color: HrColors.accentBright, size: 24),
                                    'Level ${ld.level}',
                                    levelTitle(ld.level)),
                                statLine(
                                    const Icon(Icons.emoji_events_rounded,
                                        color: HrColors.gold, size: 22),
                                    '${v.score}',
                                    'daily score'),
                                const Spacer(),
                                Row(children: [
                                  _Avatar(size: 46),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(appState.displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: HrText.headline),
                                          Text('Build your own streak with Habitrail.',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: HrText.micro.copyWith(
                                                  color: HrColors.text2)),
                                        ]),
                                  ),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
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
        void push(Widget page) => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => page));
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                HrPageHeader(
                  title: 'Friends',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HrHeaderButton(
                        icon: Icons.forum_rounded,
                        tooltip: 'Global chat',
                        onPressed: () => push(const GlobalChatScreen()),
                      ),
                      const SizedBox(width: 8),
                      HrHeaderButton(
                        icon: Icons.shield_rounded,
                        tooltip: 'Guilds',
                        onPressed: () => push(const GuildsScreen()),
                      ),
                      const SizedBox(width: 8),
                      HrHeaderButton(
                        icon: Icons.groups_rounded,
                        tooltip: 'Party',
                        onPressed: () => push(const PartyScreen()),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HrSpace.gutter,
                    14,
                    HrSpace.gutter,
                    4,
                  ),
                  child: HrSegmented(
                    items: const ['Leaderboard', 'Add Friends'],
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
        0,
        HrSpace.gutter,
        28,
      ),
      children: [
        _podium(context, board),
        const SizedBox(height: 14),
        for (int i = 3; i < board.length; i++)
          _leaderRow(context, i + 1, board[i]),
        if (board.length < 4) ...[
          HrCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Climb together', style: HrText.headline),
                const SizedBox(height: 4),
                Text(
                  'Add friends to fill the board and race each other on XP and streaks.',
                  style: HrText.bodyS,
                ),
                const SizedBox(height: 14),
                HrButton(
                  label: 'Invite friends',
                  icon: Icons.person_add_alt_1_rounded,
                  onPressed: () => setState(() => _seg = 1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 4),
        _leaderboardStatusCard(
          rank: rank,
          myXp: myXp,
          opponent: opponent,
          isLeading: isLeading,
        ),
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
      decoration: HrCard.decoration(),
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
  });
  final String name;
  final String borderId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = borderById(borderId);
    final hasBorder = b.id != 'none';
    final ringW = hasBorder
        ? (size * 0.1).clamp(3.0, 6.0)
        : (size * 0.06).clamp(2.0, 4.0);
    final frameAsset = b.frameAsset;
    final inner = frameAsset != null ? size * 0.72 : size - ringW * 2;
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

// Top three on 3D podium blocks: avatar, rank medal, name and gold XP.
Widget _podium(BuildContext context, List<_Ranked> board) {
  final top = board.take(3).toList();
  _Ranked? at(int r) => top.length >= r ? top[r - 1] : null;
  void openProfile(_Ranked? entry) {
    if (entry?.friendId == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(friendId: entry!.friendId!),
      ),
    );
  }

  // (medal colours, block top, block bottom) per rank.
  (List<Color>, Color, Color) palette(int rank) => switch (rank) {
    1 => (
      const [Color(0xFFFFE45C), Color(0xFFF2AE12)],
      const Color(0xFF3B2F72),
      const Color(0xFF1B173A),
    ),
    2 => (
      const [Color(0xFFE6E8F5), Color(0xFF8E92AE)],
      const Color(0xFF4A3E86),
      const Color(0xFF221D44),
    ),
    _ => (
      const [Color(0xFFFFB37A), Color(0xFFC0642C)],
      const Color(0xFF6B4026),
      const Color(0xFF2E1D17),
    ),
  };

  Widget column(int rank, double blockH, double avatar) {
    final entry = at(rank);
    final (medal, blockTop, blockBottom) = palette(rank);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => openProfile(entry),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (rank == 1)
              const SizedBox(
                width: 34,
                height: 26,
                child: CustomPaint(painter: _CrownPainter()),
              ),
            // Avatar on a soft violet glow.
            Container(
              width: avatar + 16,
              height: avatar + 16,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  (rank == 1 ? HrColors.gold : HrColors.accent)
                      .withValues(alpha: 0.35),
                  Colors.transparent,
                ]),
              ),
              child: entry == null
                  ? Container(
                      width: avatar * 0.8,
                      height: avatar * 0.8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: HrColors.surface2,
                        border: Border.all(color: HrColors.cardEdge),
                      ),
                      child: const Icon(Icons.person_add_alt_1_rounded,
                          color: HrColors.text3),
                    )
                  : entry.isMe
                  ? _Avatar(size: avatar)
                  : _FriendAvatar(
                      name: entry.name,
                      borderId: entry.borderId,
                      size: avatar,
                    ),
            ),
            const SizedBox(height: 4),
            // The block: a lit top face over a deeper body.
            SizedBox(
              height: blockH,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  Positioned.fill(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [blockTop, blockBottom],
                        ),
                        border: Border(
                          top: BorderSide(
                              color: Color.lerp(blockTop, Colors.white, 0.35)!,
                              width: 2),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (rank == 1 ? HrColors.accent : blockTop)
                                .withValues(alpha: 0.35),
                            blurRadius: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: -14,
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: medal,
                        ),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.5)),
                        boxShadow: [
                          BoxShadow(
                              color: medal.last.withValues(alpha: 0.6),
                              blurRadius: 10),
                        ],
                      ),
                      child: Text(
                        '$rank',
                        style: HrText.headline.copyWith(
                            color: const Color(0xFF1A1426),
                            fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    right: 6,
                    top: 22,
                    child: Column(
                      children: [
                        Text(
                          entry == null
                              ? '—'
                              : (entry.isMe ? 'You' : entry.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HrText.body.copyWith(
                              fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                        if (entry != null)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${hrNum(entry.totalXp)} XP',
                              style: HrText.body.copyWith(
                                color: HrColors.gold,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  return Stack(
    children: [
      const Positioned.fill(
        child: IgnorePointer(child: CustomPaint(painter: _PodiumSparkles())),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            column(2, 96, 70),
            column(1, 120, 84),
            column(3, 86, 66),
          ],
        ),
      ),
    ],
  );
}

// A small gold crown for the leaderboard's first place.
class _CrownPainter extends CustomPainter {
  const _CrownPainter();
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final crown = Path()
      ..moveTo(w * 0.08, h * 0.88)
      ..lineTo(w * 0.02, h * 0.3)
      ..lineTo(w * 0.3, h * 0.55)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.7, h * 0.55)
      ..lineTo(w * 0.98, h * 0.3)
      ..lineTo(w * 0.92, h * 0.88)
      ..close();
    canvas.drawPath(
      crown,
      Paint()
        ..color = HrColors.gold.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      crown,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [HrColors.goldBright, HrColors.goldDeep],
        ).createShader(Offset.zero & s),
    );
    final gem = Paint()..color = const Color(0xFFFFF4C2);
    for (final x in [0.02, 0.5, 0.98]) {
      canvas.drawCircle(Offset(w * x, h * (x == 0.5 ? 0.08 : 0.3)), w * 0.06, gem);
    }
  }

  @override
  bool shouldRepaint(_CrownPainter oldDelegate) => false;
}

class _PodiumSparkles extends CustomPainter {
  const _PodiumSparkles();
  @override
  void paint(Canvas canvas, Size s) {
    hrDrawSparkle(canvas, Offset(s.width * 0.06, s.height * 0.2), 7, HrColors.gold);
    hrDrawSparkle(canvas, Offset(s.width * 0.3, s.height * 0.08), 5, HrColors.goldBright);
    hrDrawSparkle(canvas, Offset(s.width * 0.93, s.height * 0.12), 6, HrColors.gold);
    hrDrawSparkle(canvas, Offset(s.width * 0.67, s.height * 0.32), 4, HrColors.gold);
    final violet = Paint()..color = const Color(0xCC9B6BFF);
    for (final (x, y) in [(0.2, 0.15), (0.74, 0.06), (0.86, 0.3), (0.12, 0.42)]) {
      canvas.drawRect(
          Rect.fromCenter(center: Offset(s.width * x, s.height * y), width: 5, height: 5),
          violet);
    }
  }

  @override
  bool shouldRepaint(_PodiumSparkles oldDelegate) => false;
}

Widget _leaderRow(BuildContext context, int rank, _Ranked e) {
  final row = Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: HrCard(
      highlight: e.isMe,
      radius: HrRadius.md,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '$rank',
              style: HrText.headline.copyWith(
                  color: HrColors.text2, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 6),
          e.isMe
              ? _Avatar(size: 42)
              : _FriendAvatar(name: e.name, borderId: e.borderId, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
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
          ),
          const SizedBox(width: 8),
          Text(
            '${hrNum(e.totalXp)} XP',
            style: HrText.bodyS.copyWith(
                color: HrColors.gold, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 14),
          Image.asset('assets/streaks/enamel_flame.png', width: 20, height: 20),
          const SizedBox(width: 4),
          SizedBox(
            width: 22,
            child: Text(
              '${e.streak}',
              style: HrText.bodyS.copyWith(
                  color: HrColors.text2, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );
  return Semantics(
    label:
        'Rank $rank, ${e.isMe ? 'you' : e.name}, ${e.totalXp} XP, ${e.streak} day streak',
    button: e.friendId != null,
    child: e.friendId == null
        ? row
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => FriendProfileScreen(friendId: e.friendId!),
              ),
            ),
            child: row,
          ),
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
            decoration: const InputDecoration(
              hintText: 'Add by username',
              prefixIcon: Icon(
                Icons.alternate_email_rounded,
                size: 18,
                color: HrColors.text3,
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
            appBar: AppBar(),
            body: Center(
              child: Text('This friend was removed.', style: HrText.bodyS),
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
            ? '${f.name} leads you by ${hrNum(diff)} XP.'
            : 'You lead ${f.name} by ${hrNum(-diff)} XP.';
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 32),
            children: [
              HrCard(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: HrColors.gold, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                            color: HrColors.gold.withValues(alpha: 0.4), blurRadius: 16),
                      ],
                    ),
                    child: _FriendAvatar(name: f.name, borderId: f.borderId, size: 84),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(f.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HrText.title1),
                        ),
                        if (f.prestige > 0) ...[
                          const SizedBox(width: 6),
                          Text('★${f.prestige}',
                              style: HrText.title2.copyWith(color: HrColors.gold)),
                        ],
                      ]),
                      Text('@${f.username}', style: HrText.bodyS),
                      const SizedBox(height: 2),
                      Text(levelTitle(ld.level),
                          style: HrText.caption.copyWith(color: HrColors.lavender)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: HrColors.accentSurface,
                          borderRadius: BorderRadius.circular(HrRadius.sm),
                          border: Border.all(color: HrColors.accent),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.check_rounded, size: 15, color: HrColors.accentBright),
                          const SizedBox(width: 4),
                          Text('Friends',
                              style: HrText.micro.copyWith(
                                  color: HrColors.accentBright,
                                  fontWeight: FontWeight.w900)),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              HrCard(
                child: Row(children: [
                  Expanded(
                    flex: 5,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Level', style: HrText.micro.copyWith(color: HrColors.text2)),
                      Text('${ld.level}', style: HrText.title1),
                      const SizedBox(height: 6),
                      HrXpBar(value: ld.progress, height: 8),
                      const SizedBox(height: 4),
                      Text('${hrNum(ld.currentXp)} / ${hrNum(ld.requiredXp)} XP',
                          style: HrText.micro.copyWith(color: HrColors.text2)),
                    ]),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 3,
                    child: Column(children: [
                      Image.asset('assets/streaks/enamel_flame.png', width: 32, height: 32),
                      Text('${f.streak}', style: HrText.title2),
                      Text('day streak', style: HrText.micro.copyWith(color: HrColors.text2)),
                    ]),
                  ),
                  Expanded(
                    flex: 3,
                    child: Column(children: [
                      const Icon(Icons.leaderboard_rounded, size: 30, color: HrColors.gold),
                      Text('#$rank', style: HrText.title2),
                      Text('rank', style: HrText.micro.copyWith(color: HrColors.text2)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
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
                kind: HrButtonKind.accent,
                // No in-app messaging between friends yet, so the nudge goes
                // out through the system share sheet (any messenger).
                onPressed: () => SharePlus.instance.share(ShareParams(
                  text: f.streak > 0
                      ? 'Hey ${f.name}! Your ${f.streak}-day streak on Habitrail '
                          "is waiting — let's both check in today 🔥"
                      : "Hey ${f.name}! Let's both check in on Habitrail today 🔥",
                )),
              ),
              const SizedBox(height: 10),
              HrButton(
                label: 'Remove friend',
                kind: HrButtonKind.danger,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Remove ${f.name}?'),
                    content: Text('You can add @${f.username} again any time.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          friends.remove(f.id);
                          Navigator.pop(ctx);
                          Navigator.pop(context);
                        },
                        child: const Text('Remove',
                            style: TextStyle(color: HrColors.dangerText)),
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
class AwardsScreen extends StatefulWidget {
  const AwardsScreen({this.embedded = false, super.key});
  final bool embedded;

  @override
  State<AwardsScreen> createState() => _AwardsScreenState();
}

// Filter groups for the award grid.
String _awardGroup(Achievement a) => switch (a.id) {
  'streak7' || 'streak30' => 'Streaks',
  'first' || 'perfect' || 'collector' => 'Habits',
  _ => 'Special',
};

class _AwardsScreenState extends State<AwardsScreen> {
  static const _filters = ['All', 'Streaks', 'Habits', 'Special'];
  int _filter = 0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final earnedList = kAchievements.where(appState.isAchievementEarned).toList();
    final total = kAchievements.length;
    // The hardest earned award stands in for "latest" (no timestamps stored).
    final latest = earnedList.isEmpty ? null : earnedList.last;
    final next = kAchievements.firstWhere(
      (a) => !appState.isAchievementEarned(a),
      orElse: () => kAchievements.last,
    );
    final shown = _filter == 0
        ? kAchievements
        : kAchievements.where((a) => _awardGroup(a) == _filters[_filter]).toList();
    return _hrPage(
      title: 'Awards',
      embedded: widget.embedded,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Center(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                text: '${earnedList.length}',
                style: HrText.bodyS.copyWith(
                    color: HrColors.gold, fontWeight: FontWeight.w900),
              ),
              TextSpan(
                text: ' / $total earned',
                style: HrText.bodyS.copyWith(color: HrColors.text2),
              ),
            ])),
          ),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 4, HrSpace.gutter, 32),
        children: [
          HrCard(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(
              children: [
                HrHeroArt(
                  width: 112,
                  height: 104,
                  child: Opacity(
                    opacity: latest == null ? 0.45 : 1,
                    child: Image.asset((latest ?? next).imageAsset,
                        width: 82, height: 82),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(latest == null ? 'Next achievement' : 'Latest achievement',
                          style: HrText.micro.copyWith(color: HrColors.text2)),
                      const SizedBox(height: 2),
                      Text((latest ?? next).title, style: HrText.title2),
                      const SizedBox(height: 4),
                      Text(
                        latest == null
                            ? next.description
                            : 'Keep the momentum going!',
                        style: HrText.bodyS,
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
          HrFilterChips(
            items: _filters,
            index: _filter,
            onChanged: (i) => setState(() => _filter = i),
          ),
          const SizedBox(height: 14),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 0.8,
            children: [
              for (final a in shown)
                _AchievementCard(a, highlight: a.id == latest?.id),
            ],
          ),
        ],
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard(this.a, {this.highlight = false});
  final Achievement a;
  final bool highlight;

  void _details(BuildContext context, bool on) {
    final color = HrColors.rarity[a.rarity] ?? HrColors.text3;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(
                opacity: on ? 1 : 0.45,
                child: Image.asset(a.imageAsset, width: 110, height: 110),
              ),
              const SizedBox(height: 12),
              Text(a.title, style: HrText.title1),
              const SizedBox(height: 6),
              Text(a.description, textAlign: TextAlign.center, style: HrText.body),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(HrRadius.xs),
                ),
                child: Text(
                  '${a.rarity.toUpperCase()} · ${on ? 'EARNED' : 'LOCKED'}',
                  style: HrText.micro.copyWith(
                      color: color, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    final on = appState.isAchievementEarned(a);
    return Semantics(
      button: true,
      label: '${a.title}, ${on ? 'earned' : 'locked'}',
      excludeSemantics: true,
      child: HrCard(
        onTap: () => _details(context, on),
        highlight: highlight,
        radius: HrRadius.md,
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 62,
              height: 62,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: on ? 1 : 0.4,
                      child: Image.asset(a.imageAsset, fit: BoxFit.contain),
                    ),
                  ),
                  if (!on)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: HrColors.surface2,
                          shape: BoxShape.circle,
                          border: Border.all(color: HrColors.cardEdge),
                        ),
                        child: const Icon(Icons.lock_rounded,
                            size: 12, color: HrColors.text2),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              a.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HrText.caption.copyWith(
                color: on ? HrColors.text : HrColors.text2,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          ],
        ),
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
          const SizedBox.shrink(),
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
    final now = DateTime.now();
    return _hrPage(
      title: 'Journal',
      subtitle: '${_kMonthsFull[now.month - 1]} ${now.day}, ${now.year}',
      embedded: widget.embedded,
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _entries(context),
      ),
    );
  }

  Widget _entries(BuildContext context) {
    final items = appState.reflections;
    final today = dateKey(DateTime.now());
    final reflectedToday = items.any((r) => r.date == today);
    final visibleItems = _showAll ? items : items.take(2).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HrSpace.gutter,
        8,
        HrSpace.gutter,
        32,
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
      onLongPress: onMenu,
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
          const SizedBox.shrink(),
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

        void save() {
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
        }

        Future<void> pickReminder() async {
          final init = reminderMinutes != null
              ? TimeOfDay(
                  hour: reminderMinutes! ~/ 60,
                  minute: reminderMinutes! % 60,
                )
              : const TimeOfDay(hour: 20, minute: 0);
          final picked = await showTimePicker(context: ctx, initialTime: init);
          if (picked != null) {
            setLocal(() => reminderMinutes = picked.hour * 60 + picked.minute);
          }
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Live preview: the quest tile as it will appear on Today.
                Row(
                  children: [
                    icon == '💰'
                        ? const HrIconTile(
                            asset: 'assets/shop/coin_stack.png', size: 56)
                        : HrIconTile(emoji: icon, size: 56),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            existing == null ? 'New habit' : 'Edit habit',
                            style: HrText.title1,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'It joins your quests on Today.',
                            style: HrText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: existing == null,
                  style: HrText.body.copyWith(fontWeight: FontWeight.w700),
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Meditate 10 min',
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
                    return Semantics(
                      button: true,
                      selected: sel,
                      label: 'Icon $e',
                      child: HrPressable(
                        onTap: () => setLocal(() {
                          icon = sel ? '' : e;
                          iconManual = true;
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: sel ? HrColors.accentSurface : HrColors.surface2,
                            borderRadius: BorderRadius.circular(HrRadius.sm + 2),
                            border: Border.all(
                              color: sel ? HrColors.accentBright : HrColors.cardEdge,
                              width: sel ? 1.6 : 1,
                            ),
                            boxShadow: sel
                                ? [
                                    BoxShadow(
                                      color: HrColors.accent.withValues(alpha: 0.45),
                                      blurRadius: 10,
                                    ),
                                  ]
                                : null,
                          ),
                          child: e == '💰'
                              ? Image.asset(
                                  'assets/shop/coin_stack.png',
                                  width: 27,
                                  height: 27,
                                  fit: BoxFit.contain,
                                  semanticLabel: 'Coins',
                                )
                              : Text(e, style: const TextStyle(fontSize: 21)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                _difficultyCard(verdict, analyzing),
                const SizedBox(height: 10),
                HrCard(
                  padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                  radius: HrRadius.md,
                  onTap: pickReminder,
                  child: Row(
                    children: [
                      Icon(
                        Icons.notifications_active_rounded,
                        size: 20,
                        color: reminderMinutes != null
                            ? HrColors.gold
                            : HrColors.text3,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          reminderMinutes == null
                              ? 'No daily reminder'
                              : 'Remind me at ${_fmtReminder(reminderMinutes!)}',
                          style: HrText.bodyS.copyWith(
                              color: HrColors.text, fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: pickReminder,
                        child: Text(reminderMinutes == null ? 'Set' : 'Change'),
                      ),
                      if (reminderMinutes != null)
                        IconButton(
                          tooltip: 'Remove reminder',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setLocal(() => reminderMinutes = null),
                          icon: const Icon(Icons.close_rounded,
                              size: 18, color: HrColors.text3),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    if (existing != null) ...[
                      Expanded(
                        child: HrButton(
                          label: 'Delete',
                          icon: Icons.delete_outline_rounded,
                          kind: HrButtonKind.danger,
                          onPressed: () {
                            appState.deleteHabit(existing);
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: HrButton(
                        label: existing == null ? 'Add habit' : 'Save',
                        icon: existing == null
                            ? Icons.add_rounded
                            : Icons.check_rounded,
                        kind: HrButtonKind.accent,
                        onPressed: save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
    decoration: HrCard.decoration(radius: HrRadius.md),
    child: Row(
      children: [
        HrIconTile(icon: Icons.auto_awesome_rounded, color: color, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${v.label} · ×${v.multiplier}',
                      style: HrText.bodyS.copyWith(
                        color: color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  HrXpChip(estimatedXp(v.rarity), label: '~${estimatedXp(v.rarity)} XP'),
                  const SizedBox(width: 6),
                  _ratingChip(v, analyzing),
                ],
              ),
              const SizedBox(height: 4),
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
        border: Border.all(color: HrColors.cardEdge),
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
                            color: selected ? color : const Color(0xFF1C1F33),
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
              const SizedBox.shrink(),
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
                  border: Border.all(color: HrColors.cardEdge),
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
  _disposeAfterClose([controller]);
}

// ── NUTRITION ────────────────────────────────────────────────────────────────
class _NutritionCard extends StatelessWidget {
  const _NutritionCard();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
                  Text('Nutrition', style: HrText.caption.copyWith(color: HrColors.text2, fontWeight: FontWeight.w800)),
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

  Widget _ring(String label, String value, String sub, double v, Color color,
          IconData icon) =>
      Column(children: [
        SegmentedRing(
          size: 92,
          segments: 1,
          value: v.isNaN ? 0 : v.clamp(0.0, 1.0),
          stroke: 8,
          color: color,
          center: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: color),
            Text(value,
                style: HrText.bodyS.copyWith(
                    color: HrColors.text, fontWeight: FontWeight.w900)),
            Text(sub, style: HrText.micro.copyWith(fontSize: 9.5)),
          ]),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: HrText.caption.copyWith(
                color: HrColors.text, fontWeight: FontWeight.w800)),
      ]);

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
        double pct(double a, double b) => b <= 0 ? 0 : a / b;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Nutrition',
                subtitle: 'Fuel your body. Power your progress.'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: Text("Today's nutrition", style: HrText.title2)),
                    HrButton(
                      label: 'Log meal',
                      icon: Icons.add_rounded,
                      kind: HrButtonKind.accent,
                      small: true,
                      expand: false,
                      onPressed: () => showAddFood(context),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _ring('Meals', '${todays.length} / 3', 'meals',
                          todays.length / 3, HrColors.success, Icons.restaurant_rounded),
                      _ring('Calories', hrNum(n.calories), '/ ${hrNum(t.calories)}',
                          pct(n.calories, t.calories), const Color(0xFFFF9F43),
                          Icons.local_fire_department_rounded),
                      _ring('Protein', '${n.protein.round()} g', '/ ${t.protein.round()} g',
                          pct(n.protein, t.protein), const Color(0xFF62D5FF),
                          Icons.fitness_center_rounded),
                    ],
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              HrCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Text('Nutrition score', style: HrText.headline),
                    const Spacer(),
                    Text.rich(TextSpan(children: [
                      TextSpan(
                          text: '$score',
                          style: HrText.title2.copyWith(color: HrColors.victory(score))),
                      TextSpan(text: ' / 100', style: HrText.bodyS),
                    ])),
                  ]),
                  const SizedBox(height: 10),
                  for (final m in [
                    ('Carbs', n.carbs, t.carbs, HrColors.info),
                    ('Fat', n.fat, t.fat, HrColors.accentBright),
                  ]) ...[
                    Row(children: [
                      Text(m.$1, style: HrText.caption.copyWith(color: HrColors.text2)),
                      const Spacer(),
                      Text('${m.$2.round()} / ${m.$3.round()} g', style: HrText.caption),
                    ]),
                    const SizedBox(height: 5),
                    HrXpBar(value: pct(m.$2, m.$3), height: 8, color: m.$4),
                    const SizedBox(height: 10),
                  ],
                  Row(children: [
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
                        MaterialPageRoute(builder: (_) => const BodyProfileScreen()),
                      ),
                      icon: const Icon(Icons.person_rounded, size: 16),
                      label: Text(p == null ? 'Set body profile' : 'Edit profile'),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 18),
              const HrLabel("Today's meals"),
              if (todays.isEmpty)
                HrCard(
                  padding: const EdgeInsets.all(18),
                  child: Row(children: [
                    const HrIconTile(emoji: '🍎', size: 46),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('No food logged today', style: HrText.headline),
                        const SizedBox(height: 2),
                        Text('Tap "Log meal" to add one.', style: HrText.caption),
                      ]),
                    ),
                  ]),
                )
              else
                HrMenuGroup(children: [for (final e in todays) _FoodTile(e)]),
            ],
          ),
        );
      },
    );
  }
}

class _FoodTile extends StatelessWidget {
  const _FoodTile(this.e);
  final FoodEntry e;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          const HrIconTile(emoji: '🍽️', size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HrText.body.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  '${e.calories.round()} kcal · P${e.protein.round()} C${e.carbs.round()} F${e.fat.round()}',
                  style: HrText.caption,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close_rounded, color: HrColors.text3, size: 20),
            onPressed: () => appState.deleteFood(e),
          ),
        ],
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
          title: const Text('Log food'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: HrColors.surface2,
                    borderRadius: BorderRadius.circular(HrRadius.md),
                    border: Border.all(color: HrColors.cardEdge),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.auto_awesome_rounded,
                            size: 15,
                            color: HrColors.gold,
                          ),
                          const SizedBox(width: 6),
                          Text('Describe your meal', style: HrText.caption),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: meal,
                        style: HrText.body,
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
                            minimumSize: const Size.fromHeight(44),
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
                      style: TextStyle(color: HrColors.info, fontSize: 11),
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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

class CompanionsScreen extends StatefulWidget {
  const CompanionsScreen({super.key});
  @override
  State<CompanionsScreen> createState() => _CompanionsScreenState();
}

class _CompanionsScreenState extends State<CompanionsScreen> {
  // The companion being browsed (starts on the active one).
  late int _view = kCompanions
      .indexWhere((c) => c.type == appState.activeCompanion)
      .clamp(0, kCompanions.length - 1);

  void _step(int d) => setState(
      () => _view = (_view + d) % kCompanions.length);

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
                color: sel ? HrColors.accentBright : HrColors.cardEdge,
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
              color: sel ? HrColors.accentBright : HrColors.cardEdge,
              width: sel ? 2 : 1),
        ),
        child: a.emoji.isEmpty
            ? const Icon(Icons.block_rounded, size: 18, color: HrColors.text3)
            : Text(a.emoji, style: const TextStyle(fontSize: 22)),
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
                  color: sel ? cl.color : HrColors.cardEdge,
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
          const HrIconTile(
              icon: Icons.workspace_premium_rounded, color: HrColors.gold, size: 42),
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
    return HrCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const HrLabel('Skin'),
        Wrap(
            spacing: 12,
            runSpacing: 12,
            children: kCompanionSkins.map(_skinSwatch).toList()),
        const SizedBox(height: 18),
        const HrLabel('Accessory'),
        Wrap(
            spacing: 12,
            runSpacing: 12,
            children: kCompanionAccessories.map(_accessorySwatch).toList()),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final c = kCompanions[_view];
        final unlocked = appState.companionUnlocked(c.type);
        final active = appState.activeCompanion == c.type;
        final unlockedCount =
            kCompanions.where((x) => appState.companionUnlocked(x.type)).length;
        final ld = levelFromXp(appState.totalXp);
        final traits = c.tagline.split(' · ');
        final voice = companionLine(c.type, 'elite_day');
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Companions', art: false),
            actions: [
              Container(
                margin: const EdgeInsets.only(right: 16),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: HrColors.surface,
                  borderRadius: BorderRadius.circular(HrRadius.full),
                  border: Border.all(color: HrColors.cardEdge),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.pets_rounded, size: 18, color: HrColors.gold),
                  const SizedBox(width: 6),
                  Text('$unlockedCount / ${kCompanions.length}',
                      style: HrText.bodyS.copyWith(
                          color: HrColors.text, fontWeight: FontWeight.w900)),
                ]),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 0, HrSpace.gutter, 28),
            children: [
              Text('Collect, level up, and adventure together.',
                  style: HrText.bodyS),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Big preview with browse arrows.
                  Expanded(
                    flex: 11,
                    child: SizedBox(
                      height: 230,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          HrHeroArt(
                            width: 180,
                            height: 220,
                            child: Opacity(
                              opacity: unlocked ? 1 : 0.4,
                              child: _CompanionOrb(
                                color: c.color,
                                icon: c.icon,
                                size: 130,
                                imageAsset: c.imageAsset,
                                glowColor: active && appState.companionSkin != 'classic'
                                    ? companionGlowColor(appState.companionSkin, c.color)
                                    : null,
                                accessoryEmoji: active
                                    ? companionAccessoryById(appState.companionAccessory).emoji
                                    : '',
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            child: HrHeaderButton(
                              icon: Icons.chevron_left_rounded,
                              tooltip: 'Previous companion',
                              color: HrColors.text,
                              onPressed: () => _step(-1),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            child: HrHeaderButton(
                              icon: Icons.chevron_right_rounded,
                              tooltip: 'Next companion',
                              color: HrColors.text,
                              onPressed: () => _step(1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Info card: name, level, traits and voice line.
                  Expanded(
                    flex: 10,
                    child: HrCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.name, style: HrText.title2),
                          const SizedBox(height: 4),
                          if (unlocked) ...[
                            Text.rich(TextSpan(children: [
                              TextSpan(text: 'Level ', style: HrText.bodyS.copyWith(color: HrColors.lavender)),
                              TextSpan(
                                text: '${ld.level}',
                                style: HrText.bodyS.copyWith(
                                    color: HrColors.accentBright, fontWeight: FontWeight.w900),
                              ),
                            ])),
                            const SizedBox(height: 6),
                            HrXpBar(value: ld.progress, height: 8),
                            const SizedBox(height: 4),
                            Text.rich(TextSpan(children: [
                              TextSpan(
                                text: hrNum(ld.currentXp),
                                style: HrText.micro.copyWith(color: HrColors.gold, fontWeight: FontWeight.w900),
                              ),
                              TextSpan(
                                text: ' / ${hrNum(ld.requiredXp)} XP',
                                style: HrText.micro.copyWith(color: HrColors.text2),
                              ),
                            ])),
                          ] else
                            Text('Unlocks at Level ${c.unlockLevel}',
                                style: HrText.caption.copyWith(color: HrColors.gold)),
                          const SizedBox(height: 10),
                          for (final t in traits)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(children: [
                                Icon(Icons.auto_awesome, size: 14, color: c.color),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(t,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: HrText.caption.copyWith(color: HrColors.text)),
                                ),
                              ]),
                            ),
                          if (voice.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text('“$voice”',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: HrText.micro.copyWith(
                                    color: HrColors.text2, fontStyle: FontStyle.italic)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: kCompanions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final x = kCompanions[i];
                    final open = appState.companionUnlocked(x.type);
                    final sel = i == _view;
                    return Semantics(
                      button: true,
                      selected: sel,
                      label: '${x.name}${open ? '' : ', locked'}',
                      excludeSemantics: true,
                      child: HrPressable(
                        onTap: () => setState(() => _view = i),
                        child: AnimatedContainer(
                          duration: HrMotion.of(context, HrMotion.base),
                          width: 70,
                          decoration: BoxDecoration(
                            color: HrColors.surface,
                            borderRadius: BorderRadius.circular(HrRadius.md),
                            border: Border.all(
                              color: sel ? HrColors.accentBright : HrColors.cardEdge,
                              width: sel ? 2 : 1,
                            ),
                            boxShadow: sel
                                ? [BoxShadow(color: HrColors.accent.withValues(alpha: 0.5), blurRadius: 12)]
                                : null,
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Opacity(
                                opacity: open ? 1 : 0.3,
                                child: _CompanionOrb(
                                    color: x.color, icon: x.icon, size: 50, imageAsset: x.imageAsset),
                              ),
                              if (!open)
                                const Icon(Icons.lock_rounded, color: HrColors.text, size: 20),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              HrButton(
                label: active
                    ? 'Active companion'
                    : unlocked
                        ? 'Set as Active Companion'
                        : 'Unlocks at Level ${c.unlockLevel}',
                icon: active ? Icons.check_rounded : null,
                kind: HrButtonKind.accent,
                onPressed: unlocked && !active
                    ? () {
                        appState.setCompanion(c.type);
                        hrToast(context, '${c.name} is now your companion',
                            icon: Icons.pets_rounded);
                      }
                    : null,
              ),
              const SizedBox(height: 20),
              _customizeSection(context),
              const SizedBox(height: 20),
              HrLabel('Your class',
                  trailing: Text(classById(appState.playerClass).name,
                      style: HrText.bodyS.copyWith(
                          color: classById(appState.playerClass).color,
                          fontWeight: FontWeight.w900))),
              Text(classById(appState.playerClass).tagline, style: HrText.caption),
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

  // One settings-style row: icon, label, and an inline value on the right.
  Widget _row(IconData icon, String label, Widget value, {VoidCallback? onTap}) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: SizedBox(
            height: 46,
            child: Row(children: [
              Icon(icon, size: 22, color: const Color(0xFFC9C3F0)),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(label,
                      style: HrText.body.copyWith(fontWeight: FontWeight.w700))),
              value,
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    color: HrColors.text2, size: 24),
            ]),
          ),
        ),
      );

  Widget _inlineNumber(TextEditingController c, String hint, String unit) =>
      SizedBox(
        width: 120,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          onChanged: (_) => setState(() {}),
          style: HrText.body.copyWith(fontWeight: FontWeight.w800),
          decoration: InputDecoration(
            hintText: hint,
            suffixText: ' $unit',
            suffixStyle: HrText.caption,
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      );

  Future<void> _pick(String title, Map<String, String> options, String current,
      ValueChanged<String> onPick) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: HrText.title2),
          const SizedBox(height: 8),
          for (final e in options.entries)
            ListTile(
              title: Text(e.value),
              trailing: HrCheck(done: e.key == current, size: 22),
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (v != null) setState(() => onPick(v));
  }

  Widget _valueText(String s) => Text(s,
      style: HrText.bodyS.copyWith(color: HrColors.text2, fontWeight: FontWeight.w700));

  static const _genders = {'male': 'Male', 'female': 'Female', 'other': 'Other'};
  static const _activities = {
    'sedentary': 'Sedentary',
    'light': 'Light',
    'moderate': 'Moderate',
    'active': 'Active',
    'very_active': 'Very active',
  };
  static const _goals = {
    'cut': 'Cut (lose fat)',
    'maintain': 'Maintain',
    'bulk': 'Bulk (gain)',
  };

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
        title: const HrAppBarTitle('Body profile',
            subtitle: 'Optional details to personalize your targets.'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
        children: [
          HrMenuGroup(children: [
            _row(Icons.cake_rounded, 'Age', _inlineNumber(_age, 'Add', 'yrs')),
            _row(Icons.height_rounded, 'Height', _inlineNumber(_height, 'Add', 'cm')),
            _row(Icons.monitor_weight_rounded, 'Weight', _inlineNumber(_weight, 'Add', 'kg')),
            _row(Icons.wc_rounded, 'Gender', _valueText(_genders[_gender] ?? _gender),
                onTap: () => _pick('Gender', _genders, _gender, (v) => _gender = v)),
            _row(Icons.directions_run_rounded, 'Activity level',
                _valueText(_activities[_activity] ?? _activity),
                onTap: () => _pick('Activity level', _activities, _activity,
                    (v) => _activity = v)),
            _row(Icons.flag_rounded, 'Goal', _valueText(_goals[_goal] ?? _goal),
                onTap: () => _pick('Goal', _goals, _goal, (v) => _goal = v)),
          ]),
          const SizedBox(height: 12),
          if (preview != null) ...[
            HrCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Computed targets', style: HrText.headline),
                  const SizedBox(height: 6),
                  Text('${hrNum(preview.calories)} kcal',
                      style: HrText.title1.copyWith(color: HrColors.gold)),
                  const SizedBox(height: 4),
                  Text(
                    'Protein ${preview.protein.round()}g · Carbs ${preview.carbs.round()}g · Fat ${preview.fat.round()}g',
                    style: HrText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          HrCard(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.lock_rounded, color: HrColors.text2, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    'This information is private and used only to personalize your nutrition targets.',
                    style: HrText.caption.copyWith(color: HrColors.text2)),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          HrButton(label: 'Save', onPressed: _save),
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

class LegacyScreen extends StatelessWidget {
  const LegacyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final log = appState.milestoneLog;
        final level = appState.level;
        final cycle = (level / kPrestigeMinLevel).clamp(0.0, 1.0);
        final bests = <(String, String, Widget)>[
          ('Peak level', '${appState.highestLevel}',
              Icon(Icons.trending_up_rounded, size: 26, color: HrColors.accentBright)),
          ('Bosses', '${appState.totalBossDefeats}',
              const Icon(Icons.shield_rounded, size: 26, color: HrColors.gold)),
          ('Season', '${appState.currentSeason + 1}',
              const Icon(Icons.public_rounded, size: 26, color: HrColors.info)),
        ];
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Legacy', subtitle: 'Your long-term journey.'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrCard(
                child: Row(children: [
                  const Icon(Icons.star_rounded, size: 52, color: HrColors.gold,
                      shadows: [Shadow(color: Color(0xAAFFD43B), blurRadius: 18)]),
                  const SizedBox(width: 12),
                  Text('${appState.prestige}',
                      style: HrText.displayXl.copyWith(color: HrColors.gold)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Prestige stars', style: HrText.headline),
                      const SizedBox(height: 2),
                      Text('Earned through completed cycles. +5% XP each.',
                          style: HrText.caption),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              HrCard(
                child: Row(children: [
                  SegmentedRing(
                    size: 64,
                    segments: 1,
                    value: cycle,
                    stroke: 8,
                    color: HrColors.accent,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Current cycle', style: HrText.caption.copyWith(color: HrColors.text2)),
                      Text(
                          level >= kPrestigeMinLevel
                              ? 'Level $level · ready to rebirth'
                              : 'Level $level of $kPrestigeMinLevel',
                          style: HrText.title2),
                      const SizedBox(height: 8),
                      HrXpBar(value: cycle, height: 8, color: HrColors.accent),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              HrCard(
                onTap: () {
                  if (appState.canPrestige) {
                    _confirmPrestige(context);
                  } else {
                    hrToast(context, 'Prestige unlocks at Level $kPrestigeMinLevel',
                        icon: Icons.auto_awesome_rounded);
                  }
                },
                child: Row(children: [
                  const HrIconTile(
                      icon: Icons.autorenew_rounded, color: Color(0xFFFF9F43), size: 50),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Rebirth', style: HrText.headline),
                      const SizedBox(height: 2),
                      Text(
                          appState.canPrestige
                              ? 'Ready — reset your level to start a new cycle. Keep your stars.'
                              : 'Reach Level $kPrestigeMinLevel to start a new cycle and earn a star.',
                          style: HrText.caption),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: HrColors.text2, size: 28),
                ]),
              ),
              const SizedBox(height: 18),
              const HrLabel('Career bests'),
              Row(children: [
                for (var i = 0; i < bests.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: HrStatTile(
                        value: bests[i].$2, label: bests[i].$1, leading: bests[i].$3),
                  ),
                ],
              ]),
              const SizedBox(height: 18),
              const HrLabel('Milestones'),
              if (log.isEmpty)
                HrCard(
                  padding: const EdgeInsets.all(18),
                  child: Row(children: [
                    const HrIconTile(emoji: '📜', size: 46),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('No milestones yet', style: HrText.headline),
                        const SizedBox(height: 2),
                        Text('Level up, defeat the boss, or hit a streak.',
                            style: HrText.caption),
                      ]),
                    ),
                  ]),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: HrCard(
        padding: const EdgeInsets.all(12),
        radius: HrRadius.md,
        child: Row(
          children: [
            HrIconTile(icon: _milestoneIcon(m.type), color: color, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.description,
                      style: HrText.body.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(_fmtDate(m.date), style: HrText.caption),
                ],
              ),
            ),
            if (m.xp > 0) HrXpChip(m.xp),
          ],
        ),
      ),
    );
  }
}

// ── PROFILE (tab) + app settings ─────────────────────────────────────────────
void _go(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

Widget _menuValue(String strong, [String rest = '']) => Text.rich(
  TextSpan(children: [
    TextSpan(
      text: strong,
      style: HrText.bodyS.copyWith(
          color: HrColors.gold, fontWeight: FontWeight.w900),
    ),
    if (rest.isNotEmpty)
      TextSpan(
        text: rest,
        style: HrText.bodyS.copyWith(
            color: HrColors.text2, fontWeight: FontWeight.w700),
      ),
  ]),
);

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, auth]),
      builder: (context, _) {
        final ld = levelFromXp(appState.totalXp);
        final authed = auth.isAuthed;
        final u = auth.user;
        final comp = companionByType(appState.activeCompanion);
        final n = appState.todayNutrition();
        final t = appState.targets();
        final earned = kAchievements.where(appState.isAchievementEarned).length;
        final questsDone =
            appState.dailyDone.values.fold<int>(0, (a, b) => a + b);
        final subtitle = [
          if (u != null && u.username.isNotEmpty) '@${u.username}',
          levelTitle(ld.level),
        ].join(' · ');
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                HrPageHeader(
                  title: 'Profile',
                  trailing: HrHeaderButton(
                    icon: Icons.settings_rounded,
                    tooltip: 'Settings',
                    onPressed: () => _go(context, const AppSettingsScreen()),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HrSpace.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HrCard(
                        onTap: () => _go(
                          context,
                          authed ? const AccountScreen() : const LoginScreen(),
                        ),
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Semantics(
                                  button: true,
                                  label: 'Change profile photo',
                                  child: GestureDetector(
                                    onTap: () => _pickProfilePhoto(context),
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: HrColors.accentBright,
                                            width: 2),
                                        boxShadow: [
                                          BoxShadow(
                                            color: HrColors.accent
                                                .withValues(alpha: 0.55),
                                            blurRadius: 18,
                                          ),
                                        ],
                                      ),
                                      child: _Avatar(size: 78),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              appState.displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: HrText.title1,
                                            ),
                                          ),
                                          if (appState.isPremium) ...[
                                            const SizedBox(width: 8),
                                            _premiumTag(),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: HrText.body.copyWith(
                                            color: HrColors.lavender),
                                      ),
                                    ],
                                  ),
                                ),
                                Tooltip(
                                  message: 'Edit name',
                                  child: HrPressable(
                                    onTap: () => _editName(context),
                                    child: Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: HrColors.surface2,
                                        borderRadius:
                                            BorderRadius.circular(HrRadius.sm),
                                        border: Border.all(
                                            color: HrColors.cardEdge),
                                      ),
                                      child: const Icon(Icons.edit_rounded,
                                          size: 18, color: HrColors.text),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            const _LevelPanel(compact: true),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: HrStatTile(
                              value: hrNum(appState.coins),
                              label: 'Coins',
                              leading: Image.asset('assets/shop/coin_stack.png',
                                  width: 34, height: 34),
                              onTap: () => _go(context, const ShopScreen()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: HrStatTile(
                              value: '${appState.bestStreak}',
                              label: 'Day streak',
                              leading: Image.asset(
                                  'assets/streaks/enamel_flame.png',
                                  width: 32,
                                  height: 32),
                              onTap: () => _go(context, const RecoveryScreen()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: HrStatTile(
                              value: hrNum(questsDone),
                              label: 'Quests done',
                              leading: const HrIconTile(
                                icon: Icons.track_changes_rounded,
                                size: 34,
                                color: Color(0xFFB07CFF),
                              ),
                              onTap: () => shellTab.value = 2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const _PremiumYouCard(),
                      const SizedBox(height: 12),
                      HrMenuGroup(children: [
                        HrMenuRow(
                          icon: Icons.star_rounded,
                          label: 'Achievements',
                          value: _menuValue('$earned', ' / ${kAchievements.length}'),
                          onTap: () => _go(context, const AwardsScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.bar_chart_rounded,
                          label: 'Statistics',
                          onTap: () => _go(context, const StatsScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.group_rounded,
                          label: 'Friends',
                          onTap: () => shellTab.value = 3,
                        ),
                      ]),
                      const SizedBox(height: 12),
                      HrMenuGroup(children: [
                        HrMenuRow(
                          icon: Icons.pets_rounded,
                          label: 'Companions',
                          subtitle: comp.name,
                          onTap: () => _go(context, const CompanionsScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.storefront_rounded,
                          label: 'Shop',
                          value: _menuValue(hrNum(appState.coins), ' coins'),
                          onTap: () => _go(context, const ShopScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.checklist_rounded,
                          label: 'Tasks',
                          subtitle: appState.openTasksToday > 0
                              ? '${appState.openTasksToday} open today'
                              : 'Dailies & to-dos',
                          onTap: () => _go(context, const TasksScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.flag_rounded,
                          label: 'Challenges',
                          subtitle: appState.activeChallenge?.title ??
                              '7 & 30-day programs',
                          onTap: () => _go(context, const ChallengesScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.health_and_safety_rounded,
                          label: 'Recovery',
                          subtitle: appState.isPremium
                              ? '${appState.premiumStreakSavesLeft} saves left this month'
                              : 'Streak-saves & rest days',
                          onTap: () => _go(context, const RecoveryScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.restaurant_rounded,
                          label: 'Nutrition',
                          subtitle:
                              '${n.calories.round()} / ${t.calories.round()} kcal today',
                          onTap: () => _go(context, const NutritionScreen()),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      HrMenuGroup(children: [
                        HrMenuRow(
                          icon: Icons.palette_rounded,
                          label: 'Appearance',
                          onTap: () => _go(context, const AppearanceScreen()),
                        ),
                        HrMenuRow(
                          icon: Icons.settings_rounded,
                          label: 'Settings',
                          onTap: () => _go(context, const AppSettingsScreen()),
                        ),
                      ]),
                      const SizedBox(height: 22),
                      Center(
                        child:
                            Text('Habitrail · v1.0.0', style: HrText.caption),
                      ),
                    ],
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

/// Account, body profile, sharing and data controls (Profile → gear).
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appState, auth]),
      builder: (context, _) {
        final authed = auth.isAuthed;
        final u = auth.user;
        final p = appState.bodyProfile;
        final t = appState.targets();
        final bodySub = p == null
            ? 'Set weight, height & goal'
            : '${p.weight.round()} kg · ${p.goal[0].toUpperCase()}${p.goal.substring(1)} · ${t.calories.round()} kcal';
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const HrAppBarTitle('Settings')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
                HrSpace.gutter, 8, HrSpace.gutter, 28),
            children: [
              HrMenuGroup(title: 'Account', children: [
                HrMenuRow(
                  icon: authed ? Icons.person_rounded : Icons.login_rounded,
                  label: authed ? 'Account' : 'Sign in or create account',
                  subtitle: authed
                      ? (u?.email ?? 'Manage your account')
                      : 'Back up progress & sync devices',
                  onTap: () => _go(
                    context,
                    authed ? const AccountScreen() : const LoginScreen(),
                  ),
                ),
                HrMenuRow(
                  icon: Icons.ios_share_rounded,
                  label: 'Share progress',
                  subtitle: 'Level · streak · score',
                  onTap: () => _go(context, const ShareCardScreen()),
                ),
              ]),
              const SizedBox(height: 12),
              HrMenuGroup(title: 'You', children: [
                HrMenuRow(
                  icon: Icons.monitor_heart_rounded,
                  label: 'Body profile',
                  subtitle: bodySub,
                  onTap: () => _go(context, const BodyProfileScreen()),
                ),
                HrMenuRow(
                  icon: Icons.palette_rounded,
                  label: 'Appearance',
                  subtitle: 'Theme & accent colour',
                  onTap: () => _go(context, const AppearanceScreen()),
                ),
              ]),
              const SizedBox(height: 12),
              HrMenuGroup(title: 'Data', children: [
                HrMenuRow(
                  icon: Icons.refresh_rounded,
                  label: 'Reset all progress',
                  subtitle: 'Wipe habits, XP & history',
                  iconColor: HrColors.dangerText,
                  labelColor: HrColors.dangerText,
                  chevron: false,
                  onTap: () => _confirmReset(context),
                ),
                if (authed)
                  HrMenuRow(
                    icon: Icons.logout_rounded,
                    label: 'Log out',
                    iconColor: HrColors.dangerText,
                    labelColor: HrColors.dangerText,
                    chevron: false,
                    onTap: () async {
                      await auth.signOut();
                      if (context.mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                  ),
              ]),
              const SizedBox(height: 22),
              Center(child: Text('Habitrail · v1.0.0', style: HrText.caption)),
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

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: kElevated));

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

/// Gold coin balance pill for page headers (Shop).
Widget _balancePill() => Container(
  padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
  decoration: BoxDecoration(
    color: HrColors.surface,
    borderRadius: BorderRadius.circular(HrRadius.full),
    border: Border.all(color: HrColors.gold.withValues(alpha: 0.45)),
    boxShadow: [BoxShadow(color: HrColors.gold.withValues(alpha: 0.18), blurRadius: 12)],
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset('assets/shop/coin_stack.png', width: 24, height: 24),
      const SizedBox(width: 6),
      Text(
        hrNum(appState.coins),
        style: HrText.headline.copyWith(color: HrColors.gold, fontWeight: FontWeight.w900),
      ),
    ],
  ),
);

/// Full-width gold price button; muted when the balance can't cover it.
Widget _shopPrice(int cost, VoidCallback onTap) {
  final canAfford = appState.coins >= cost;
  return Semantics(
    button: true,
    label: 'Buy for $cost coins',
    excludeSemantics: true,
    child: HrPressable(
      onTap: onTap,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HrRadius.sm),
          gradient: canAfford
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [HrColors.goldBright, HrColors.goldDeep],
                )
              : null,
          color: canAfford ? null : HrColors.surface2,
          border: canAfford ? null : Border.all(color: HrColors.cardEdge),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/shop/coin_stack.png', width: 18, height: 18,
                excludeFromSemantics: true),
            const SizedBox(width: 4),
            Text(
              hrNum(cost),
              style: HrText.bodyS.copyWith(
                color: canAfford ? HrColors.onBtnPrimary : HrColors.text2,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Full-width state / secondary action for an owned item.
Widget _shopOwned(String label, {VoidCallback? onTap}) => HrPressable(
  onTap: onTap,
  child: Container(
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(HrRadius.sm),
      color: onTap == null ? HrColors.accentSurface : HrColors.surface2,
      border: Border.all(
        color: onTap == null ? HrColors.accent : HrColors.cardEdge,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onTap == null) ...[
          Icon(Icons.check_rounded, size: 15, color: HrColors.accentBright),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: HrText.bodyS.copyWith(
            color: onTap == null ? HrColors.accentBright : HrColors.text,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  ),
);

class _ShopCard extends StatelessWidget {
  const _ShopCard({
    required this.art,
    required this.name,
    required this.action,
    this.desc,
    this.selected = false,
  });
  final Widget art;
  final String name;
  final String? desc;
  final Widget action;
  final bool selected;
  @override
  Widget build(BuildContext context) => HrCard(
    highlight: selected,
    radius: HrRadius.md,
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
    child: Column(
      children: [
        Expanded(child: Center(child: art)),
        const SizedBox(height: 6),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: HrText.bodyS.copyWith(color: HrColors.text, fontWeight: FontWeight.w800),
        ),
        if (desc != null) ...[
          const SizedBox(height: 2),
          Text(
            desc!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: HrText.micro.copyWith(color: HrColors.text2),
          ),
        ],
        const SizedBox(height: 8),
        action,
      ],
    ),
  );
}

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});
  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  static const _tabs = ['All', 'Power-ups', 'Borders', 'Themes'];
  int _tab = 0;

  Widget _grid(int cols, double ratio, List<Widget> items) => GridView.count(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    crossAxisCount: cols,
    crossAxisSpacing: 10,
    mainAxisSpacing: 10,
    childAspectRatio: ratio,
    children: items,
  );

  Widget _count(String text) => Text(
    text,
    style: HrText.bodyS.copyWith(color: HrColors.text2, fontWeight: FontWeight.w700),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ownedBorders = kBorders.where((b) => appState.ownsBorder(b.id)).length;
        // The exclusive premium theme is unlocked by Premium, not bought here.
        final buyableThemes = kThemes.where((t) => t.id != kPremiumThemeId).toList();
        final ownedThemes = buyableThemes.where((t) => appState.ownsTheme(t.id)).length;
        bool show(int t) => _tab == 0 || _tab == t;
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Shop'),
            actions: [_balancePill(), const SizedBox(width: 14)],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrFilterChips(
                items: _tabs,
                index: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
              const SizedBox(height: 16),
              if (show(1)) ...[
                const HrLabel('Power-ups'),
                _grid(2, 0.9, [
                  _ShopCard(
                    art: Image.asset('assets/powerups/xp_booster.png', width: 70, height: 70),
                    name: '2× XP Booster',
                    desc: appState.xpBoostActive
                        ? 'Active for the rest of today'
                        : 'Double all XP you earn today',
                    selected: appState.xpBoostActive,
                    action: appState.xpBoostActive
                        ? _shopOwned('Active')
                        : _shopPrice(150, () => _toast(
                              context,
                              appState.buyXpBoost()
                                  ? '2× XP active for today!'
                                  : 'Not enough coins',
                            )),
                  ),
                  _ShopCard(
                    art: Image.asset('assets/powerups/streak_shield.png', width: 70, height: 70),
                    name: 'Streak Shield',
                    desc: 'Saves a streak from one missed day · owned: ${appState.streakShields}',
                    action: _shopPrice(100, () => _toast(
                          context,
                          appState.buyStreakShield()
                              ? 'Streak Shield added!'
                              : 'Not enough coins',
                        )),
                  ),
                ]),
                const SizedBox(height: 18),
              ],
              if (show(2)) ...[
                HrLabel('Profile borders',
                    trailing: _count('$ownedBorders / ${kBorders.length}')),
                _grid(3, 0.74, [for (final b in kBorders) _borderCard(context, b)]),
                const SizedBox(height: 18),
              ],
              if (show(3)) ...[
                HrLabel('Themes',
                    trailing: _count('$ownedThemes / ${buyableThemes.length}')),
                _grid(3, 0.74, [for (final t in buyableThemes) _themeCard(context, t)]),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _borderCard(BuildContext context, BorderDef b) {
    final owned = appState.ownsBorder(b.id);
    final selected = appState.selectedBorder == b.id;
    return _ShopCard(
      art: _borderPreview(b, size: 64),
      name: b.name,
      selected: selected,
      action: owned
          ? (selected
              ? _shopOwned('Equipped')
              : _shopOwned('Equip', onTap: () => appState.setBorder(b.id)))
          : _shopPrice(b.cost, () {
              if (appState.buyBorder(b.id)) {
                appState.setBorder(b.id);
                celebrate(context);
                _toast(context, '${b.name} unlocked & applied!');
              } else {
                _toast(context, 'Not enough coins');
              }
            }),
    );
  }

  Widget _themeCard(BuildContext context, AppThemeDef t) {
    final owned = appState.ownsTheme(t.id);
    final active = appState.themeId == t.id;
    return _ShopCard(
      art: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: [t.accent, t.bright, t.glow, t.accent]),
          boxShadow: [BoxShadow(color: t.accent.withValues(alpha: 0.55), blurRadius: 16)],
        ),
      ),
      name: t.name,
      selected: active,
      action: owned
          ? (active
              ? _shopOwned('Active')
              : _shopOwned('Apply', onTap: () => appState.setTheme(t.id)))
          : _shopPrice(themeCost(t.id), () {
              if (appState.buyTheme(t.id)) {
                appState.setTheme(t.id);
                celebrate(context);
                _toast(context, '${t.name} unlocked & applied!');
              } else {
                _toast(context, 'Not enough coins');
              }
            }),
    );
  }
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appState,
        builder: (context, _) => _liveBuild(context),
      );

  Widget _liveBuild(BuildContext context) {
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

  Future<void> _pickTheme(BuildContext context, AppThemeDef t) async {
    if (appState.canUseTheme(t.id)) {
      appState.setTheme(t.id);
      return;
    }
    if (t.id == kPremiumThemeId) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const PremiumScreen()));
      return;
    }
    final cost = themeCost(t.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unlock ${t.name}?'),
        content: Text('This accent costs $cost coins. You have ${hrNum(appState.coins)}.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Unlock · $cost',
                  style: const TextStyle(color: HrColors.gold))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (appState.buyTheme(t.id)) {
      appState.setTheme(t.id);
      celebrate(context);
      _toast(context, '${t.name} unlocked & applied!');
    } else {
      _toast(context, 'Not enough coins');
    }
  }

  Widget _accentDot(BuildContext context, AppThemeDef t) {
    final active = appState.themeId == t.id;
    final canUse = appState.canUseTheme(t.id);
    return Semantics(
      button: true,
      selected: active,
      label: '${t.name}${canUse ? '' : ', locked'}',
      excludeSemantics: true,
      child: HrPressable(
        onTap: () => _pickTheme(context, t),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: HrMotion.of(context, HrMotion.base),
            width: 46,
            height: 46,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: active ? HrColors.text : Colors.transparent, width: 2),
            ),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [t.bright, t.accent],
                ),
                boxShadow: [
                  BoxShadow(
                      color: t.accent.withValues(alpha: active ? 0.7 : 0.35),
                      blurRadius: active ? 14 : 8),
                ],
              ),
              child: active
                  ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                  : canUse
                      ? null
                      : const Icon(Icons.lock_rounded,
                          color: Color(0xCCFFFFFF), size: 15),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            canUse
                ? (active ? 'On' : 'Owned')
                : (t.id == kPremiumThemeId ? 'Premium' : '${themeCost(t.id)}'),
            style: HrText.micro.copyWith(
                color: canUse ? HrColors.text2 : HrColors.gold,
                fontWeight: FontWeight.w800),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final current = themeById(appState.themeId);
        final companions = kCompanions
            .where((c) => appState.companionUnlocked(c.type))
            .take(3)
            .toList();
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const HrAppBarTitle('Appearance',
                subtitle: 'Make Habitrail feel yours.'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(HrSpace.gutter, 6, HrSpace.gutter, 28),
            children: [
              HrCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('Accent color', style: HrText.headline)),
                    Text(current.name,
                        style: HrText.bodyS.copyWith(
                            color: HrColors.accentBright, fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 12,
                    children: [for (final t in kThemes) _accentDot(context, t)],
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              HrCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text('Companion style', style: HrText.headline)),
                    HrLink('See all',
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const CompanionsScreen()))),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    for (var i = 0; i < companions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(child: _companionStyle(companions[i])),
                    ],
                  ]),
                ]),
              ),
              const SizedBox(height: 12),
              HrMenuGroup(children: [
                HrMenuRow(
                  icon: Icons.blur_circular_rounded,
                  label: 'Profile border',
                  subtitle: borderById(appState.selectedBorder).name,
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const ShopScreen())),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  Widget _companionStyle(CompanionDef c) {
    final active = appState.activeCompanion == c.type;
    return HrPressable(
      onTap: () => appState.setCompanion(c.type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
        decoration: BoxDecoration(
          color: active ? HrColors.goldSurface : HrColors.surface2,
          borderRadius: BorderRadius.circular(HrRadius.md),
          border: Border.all(
              color: active ? HrColors.gold : HrColors.cardEdge,
              width: active ? 1.6 : 1),
        ),
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            _CompanionOrb(color: c.color, icon: c.icon, size: 60, imageAsset: c.imageAsset),
            if (active)
              const Positioned(right: -6, top: -6, child: HrCheck(done: true, size: 20)),
          ]),
          const SizedBox(height: 6),
          Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.bodyS.copyWith(
                  color: HrColors.text, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }
}

// ── DAILY BRIEFING ───────────────────────────────────────────────────────────
Widget _briefPanel(String tag, String title, Widget body) => Padding(
  padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
  child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        tag,
        style: HrText.labelCaps.copyWith(color: HrColors.gold, letterSpacing: 2.5),
      ),
      const SizedBox(height: 8),
      Text(
        title,
        textAlign: TextAlign.center,
        style: HrText.display.copyWith(fontSize: 30),
      ),
      const SizedBox(height: 22),
      HrCard(
        padding: const EdgeInsets.all(20),
        child: SizedBox(width: double.infinity, child: body),
      ),
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
    final v = appState.victory();
    final who = companionByType(appState.activeCompanion);
    final orb = _CompanionOrb(
      color: who.color,
      icon: who.icon,
      size: 84,
      imageAsset: who.imageAsset,
    );
    final quote = HrText.body.copyWith(
      color: HrColors.text2,
      fontStyle: FontStyle.italic,
      height: 1.5,
    );
    final panels = <Widget>[
      _briefPanel(
        'COACH',
        'Your coach',
        Column(
          children: [
            HrHeroArt(width: 150, height: 120, child: orb),
            const SizedBox(height: 12),
            if (_coachLoading)
              Column(
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(height: 10),
                  Text('Reading your day…', style: HrText.caption),
                ],
              )
            else
              Text(
                '"${_coach ?? _coachFallback()}"',
                textAlign: TextAlign.center,
                style: quote,
              ),
          ],
        ),
      ),
      _briefPanel(
        'BRIEFING',
        'Welcome back, ${appState.displayName}',
        Column(
          children: [
            const _LevelPanel(),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/streaks/enamel_flame.png',
                    width: 30, height: 30),
                const SizedBox(width: 8),
                Text('${appState.bestStreak}',
                    style: HrText.title1.copyWith(color: HrColors.gold)),
                const SizedBox(width: 6),
                Text('day streak', style: HrText.body),
              ],
            ),
          ],
        ),
      ),
      _briefPanel(
        'STATUS',
        'Today',
        Column(
          children: [
            SegmentedRing(
              size: 110,
              segments: 1,
              value: v.score / 100,
              stroke: 9,
              color: victoryColor(v.score),
              center: Text('${v.score}', style: HrText.display),
            ),
            const SizedBox(height: 12),
            Text(
              victoryLabel(v.score),
              style: HrText.title2.copyWith(color: victoryColor(v.score)),
            ),
            const SizedBox(height: 6),
            Text(
              '${appState.doneTodayCount}/${appState.habits.length} habits · ${hrNum(appState.coins)} coins',
              style: HrText.bodyS,
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
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  HrCheck(done: on, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      q.title,
                      style: HrText.bodyS.copyWith(
                          color: HrColors.text, fontWeight: FontWeight.w700),
                    ),
                  ),
                  HrXpChip(q.xp),
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
            HrHeroArt(width: 150, height: 120, child: orb),
            const SizedBox(height: 12),
            Text(
              '"${companionLine(appState.activeCompanion, v.score >= 90 ? 'elite_day' : 'level_up')}"',
              textAlign: TextAlign.center,
              style: quote,
            ),
          ],
        ),
      ),
    ];
    final last = panels.length - 1;
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          const Positioned.fill(child: HrAmbientBackdrop()),
          SafeArea(
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
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: i == _page ? HrColors.accent : HrColors.surface3,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: HrButton(
                    label: _page >= last ? 'Start the day' : 'Next',
                    icon: _page >= last
                        ? Icons.rocket_launch_rounded
                        : Icons.arrow_forward_rounded,
                    kind: _page >= last
                        ? HrButtonKind.primary
                        : HrButtonKind.accent,
                    onPressed: () => _next(last),
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
