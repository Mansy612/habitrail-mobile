// Offscreen screenshot harness for design reviews. Renders each screen to a PNG
// with the real fonts (no window, no device). Skipped in normal test runs.
//
//   flutter test test/visual/screens_shots_test.dart --dart-define=SHOTS=1
//
// Output goes to build/shots/ (override with --dart-define=SHOTS_DIR=...).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';
import 'package:habitrail/friends.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';
import 'package:habitrail/ui/hr_widgets.dart';

const _on = bool.fromEnvironment('SHOTS');
const _out = String.fromEnvironment('SHOTS_DIR', defaultValue: 'build/shots');
const _only = String.fromEnvironment('SHOTS_ONLY'); // comma list of names
const _tall = bool.fromEnvironment('SHOTS_TALL'); // full-length route pages

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
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
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
    tester.view.physicalSize = const Size(390 * 2, 1700 * 2);
    for (var i = 0; i < tabs.length; i++) {
      if (!_wanted(tabs[i])) continue;
      shellTab.value = i;
      await _shot(tester, 'tall_0${i + 1}_${tabs[i]}');
    }
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
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
      'app_settings': () => const AppSettingsScreen(),
    };
    if (_tall) tester.view.physicalSize = const Size(390 * 2, 1700 * 2);
    for (final e in routes.entries) {
      if (!_wanted(e.key)) continue;
      _navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => e.value()));
      await _shot(tester, e.key);
      _navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 600));
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
