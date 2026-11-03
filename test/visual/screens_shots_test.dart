// Offscreen screenshot harness for design reviews. Renders each screen to a PNG
// with the real fonts (no window, no device). Skipped in normal test runs.
//
//   flutter test test/visual/screens_shots_test.dart --dart-define=SHOTS=1
//   (+ SHOTS_ONLY=a,b to pick screens, SHOTS_TALL=true, SHOTS_W=360 for width)
//
// Output goes to build/shots/ (override with --dart-define=SHOTS_DIR=...).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoTimerPicker;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/admin.dart';
import 'package:habitrail/core.dart';
import 'package:habitrail/friends.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';
import 'package:habitrail/ui/hr_widgets.dart';

import '../support/fake_admin.dart';

const _on = bool.fromEnvironment('SHOTS');
const _out = String.fromEnvironment('SHOTS_DIR', defaultValue: 'build/shots');
const _only = String.fromEnvironment('SHOTS_ONLY'); // comma list of names
const _tall = bool.fromEnvironment('SHOTS_TALL'); // full-length route pages
const _w = int.fromEnvironment('SHOTS_W', defaultValue: 390) * 1.0; // phone width

final _shotKey = GlobalKey();
final _navKey = GlobalKey<NavigatorState>();

// Bundled fonts (Nunito, Material icons) from the asset manifest. Emoji have no
// fallback font in the test engine, so they render as boxes in captures.
Future<void> _loadFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final f in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> _seed() async {
  SharedPreferences.setMockInitialValues({});
  await appState.load();
  final s = appState;
  if (s.habits.isEmpty) {
    s.addHabit('💧 Drink water', 'common');
    s.addHabit('📚 Read 10 pages', 'rare');
    s.addHabit('🎯 Start focus', 'epic');
    s.addHabit('🧘 Meditate', 'common');
  }
  s.toggle(s.habits.first);
  if (s.tasks.isEmpty) {
    s.addTask('Drink 8 glasses', TaskKind.daily, icon: '💧');
    s.addTask('Plan tomorrow', TaskKind.todo, icon: '📅');
    s.addTask('Do a workout', TaskKind.daily, icon: '💪');
    s.toggleTask(s.tasks.first);
  }
  // A month of sample activity for the Progress charts (deterministic).
  final now = DateTime.now();
  for (var d = 1; d < now.day; d++) {
    final k = dateKey(DateTime(now.year, now.month, d));
    s.dailyXp[k] = 60 + (d * 37) % 240;
    s.dailyFocus[k] = 15 + (d * 13) % 50;
    s.dailyDone[k] = 1 + d % 4;
  }
  for (var d = 1; d <= 28; d++) {
    final k = dateKey(DateTime(now.year, now.month - 1, d));
    s.dailyFocus[k] = 10 + (d * 7) % 40;
    s.dailyDone[k] = 1 + d % 3;
  }
  s.totalXp += 8420;
  s.coins += 2480;
  s.setDisplayName('Alex');
  s.markBriefingSeen();
  // Admin console against an in-memory server.
  adminApi = FakeAdminApi();
  // Local demo directory → a filled leaderboard.
  await friends.load();
  for (final f in friends.suggestions().take(7).toList()) {
    await friends.addByUsername(f.username);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  // Decode every on-screen image so it appears in the capture.
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  final ctx = tester.element(find.byKey(_shotKey));
  await tester.runAsync(() async {
    for (final img in images) {
      try {
        await precacheImage(img.image, ctx);
      } catch (_) {}
    }
  });
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _shot(WidgetTester tester, String name) async {
  await _settle(tester);
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

bool _wanted(String name) =>
    _only.isEmpty || _only.split(',').map((s) => s.trim()).contains(name);

void main() {
  testWidgets('render screens', (tester) async {
    tester.view.physicalSize = Size(_w * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(_loadFonts);
    await tester.runAsync(_seed);

    await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        navigatorKey: _navKey,
        debugShowCheckedModeBanner: false,
        theme: hrTheme(),
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [const HrAmbientBackdrop(), ?child],
        ),
        home: const HomeShell(),
      ),
    ));

    const tabs = ['today', 'focus', 'progress', 'friends', 'profile'];
    for (var i = 0; i < tabs.length; i++) {
      if (!_wanted(tabs[i])) continue;
      shellTab.value = i;
      await _shot(tester, '0${i + 1}_${tabs[i]}');
    }
    // Tall captures show whole scrolling pages.
    tester.view.physicalSize = Size(_w * 2, 1700 * 2);
    for (var i = 0; i < tabs.length; i++) {
      if (!_wanted(tabs[i])) continue;
      shellTab.value = i;
      await _shot(tester, 'tall_0${i + 1}_${tabs[i]}');
    }
    tester.view.physicalSize = Size(_w * 2, 844 * 2);
    shellTab.value = 0;

    final routes = <String, Widget Function()>{
      'calendar': () => const CalendarScreen(),
      'stats': () => const StatsScreen(),
      'awards': () => const AwardsScreen(),
      'journal': () => const JournalScreen(),
      'share': () => const ShareCardScreen(),
      'shop': () => const ShopScreen(),
      'challenges': () => const ChallengesScreen(),
      'tasks': () => const TasksScreen(),
      'recovery': () => const RecoveryScreen(),
      'nutrition': () => const NutritionScreen(),
      'companions': () => const CompanionsScreen(),
      'premium': () => const PremiumScreen(),
      'party': () => const PartyScreen(),
      'guilds': () => const GuildsScreen(),
      'global_chat': () => const GlobalChatScreen(),
      'account': () => const AccountScreen(),
      'body_profile': () => const BodyProfileScreen(),
      'appearance': () => const AppearanceScreen(),
      'legacy': () => const LegacyScreen(),
      'settings': () => const SettingsScreen(),
      'dashboard': () => const DashboardScreen(),
      'welcome': () => const WelcomeScreen(),
      'personalize': () => const OnboardingQuizScreen(),
      'onboarding': () => const OnboardingScreen(),
      'signup': () => const SignUpScreen(),
      'login': () => const LoginScreen(),
      'forgot_password': () => const ForgotPasswordScreen(),
      'app_settings': () => const AppSettingsScreen(),
      'notifications': () => const NotificationsScreen(),
      'friend_profile': () => FriendProfileScreen(friendId: friends.friends.first.id),
      'admin': () => const AdminScreen(),
      'admin_user': () => AdminUserScreen(user: sampleAdminUsers()[2]),
      'admin_user_banned': () => AdminUserScreen(user: sampleAdminUsers()[1]),
    };
    if (_tall) tester.view.physicalSize = Size(_w * 2, 1700 * 2);
    for (final e in routes.entries) {
      if (!_wanted(e.key)) continue;
      _navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => e.value()));
      await _shot(tester, e.key);
      _navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // Forgot password, step 2 (after a code was sent).
    if (_wanted('forgot_password_code')) {
      _navKey.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const ForgotPasswordScreen(initialEmail: 'alex@example.com')));
      await _settle(tester);
      await tester.tap(find.text('Send code'));
      await _shot(tester, 'forgot_password_code');
      _navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // Settings as an admin sees it (with the Admin console row).
    if (_wanted('app_settings_admin')) {
      adminAccess.value = true;
      _navKey.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const AppSettingsScreen()));
      await _shot(tester, 'app_settings_admin');
      _navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
      adminAccess.value = false;
    }

    // Sheets and dialogs, opened over Today.
    final sheets = <String, void Function(BuildContext)>{
      'sheet_habit': (c) => showHabitEditor(c),
      'sheet_reflection': (c) => showAddReflection(c),
    };
    for (final e in sheets.entries) {
      if (!_wanted(e.key)) continue;
      e.value(_navKey.currentContext!);
      await _shot(tester, e.key);
      _navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // Focus → Custom length picker, then the timer with a long custom length.
    if (_wanted('sheet_focus_custom')) {
      shellTab.value = 1;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Custom'));
      await tester.pump(const Duration(milliseconds: 600));
      tester
          .widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker))
          .onTimerDurationChanged(const Duration(hours: 1, minutes: 15));
      await _shot(tester, 'sheet_focus_custom');
      await tester.tap(find.text('Set 1 h 15 min'));
      await _shot(tester, 'focus_custom_set');
      shellTab.value = 0;
      await tester.pump(const Duration(milliseconds: 400));
    }

    // An award's detail sheet, opened from the Awards grid.
    if (_wanted('sheet_award')) {
      _navKey.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const AwardsScreen()));
      await _settle(tester);
      await tester.tap(find.text('Week Warrior'));
      await _shot(tester, 'sheet_award');
      _navKey.currentState!.pop(); // sheet
      await tester.pump(const Duration(milliseconds: 600));
      _navKey.currentState!.pop(); // page
      await tester.pump(const Duration(milliseconds: 600));
    }

    // Progress XP chart with a single active day (today).
    if (_wanted('progress_one_day')) {
      final saved = Map.of(appState.dailyXp);
      appState.dailyXp
        ..clear()
        ..[dateKey(DateTime.now())] = 85;
      shellTab.value = 2;
      await _shot(tester, 'progress_one_day');
      appState.dailyXp
        ..clear()
        ..addAll(saved);
      shellTab.value = 0;
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Progress XP chart on All time (January to December).
    if (_wanted('progress_all_time')) {
      shellTab.value = 2;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('All time'));
      await _shot(tester, 'progress_all_time');
      await tester.tap(find.text('Month'));
      shellTab.value = 0;
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Social with no friends yet.
    if (_wanted('friends_empty')) {
      final added = friends.friends.map((f) => f.username).toList();
      for (final f in friends.friends.toList()) {
        friends.remove(f.id);
      }
      shellTab.value = 3;
      await _shot(tester, 'friends_empty');
      for (final u in added) {
        await tester.runAsync(() => friends.addByUsername(u));
      }
      shellTab.value = 0;
      await tester.pump(const Duration(milliseconds: 400));
    }

    // The daily briefing pops up on a fresh shell when today's is unseen.
    if (_wanted('briefing')) {
      appState.lastBriefingDate = '';
      _navKey.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const HomeShell()));
      await _shot(tester, 'briefing');
      appState.markBriefingSeen();
    }
  }, skip: !_on);
}
