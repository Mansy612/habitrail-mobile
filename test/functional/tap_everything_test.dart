// Smoke sweep: on every screen, tap (and long-press) every interactive
// control one at a time on a freshly built screen, and fail with a list of
// every control that threw.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';
import 'package:habitrail/friends.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';
import 'package:habitrail/ui/hr_widgets.dart';

import '../support/app_fonts.dart';

final _nav = GlobalKey<NavigatorState>();

bool _tappable(Widget w) =>
    (w is GestureDetector && w.onTap != null) ||
    (w is InkWell && w.onTap != null) ||
    (w is IconButton && w.onPressed != null) ||
    (w is ButtonStyleButton && w.onPressed != null) ||
    (w is HrButton && w.onPressed != null) ||
    (w is HrPressable && w.onTap != null) ||
    (w is HrCard && w.onTap != null) ||
    w is PopupMenuButton ||
    (w is Switch && w.onChanged != null);

bool _longPressable(Widget w) =>
    (w is GestureDetector && w.onLongPress != null) ||
    (w is InkWell && w.onLongPress != null) ||
    (w is HrCard && w.onLongPress != null);

String _label(Element e) {
  final parts = <String>[];
  void visit(Element c) {
    final w = c.widget;
    if (w is Text) parts.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    if (w is Tooltip && w.message != null) parts.add('tip:${w.message}');
    if (w is Icon && parts.isEmpty) parts.add('icon:${w.icon?.codePoint}');
    if (parts.length < 3) c.visitChildren(visit);
  }

  visit(e);
  return '${e.widget.runtimeType}(${parts.take(3).join(' | ')})';
}

Future<void> _settle(WidgetTester t, [int frames = 7]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _seed() async {
  SharedPreferences.setMockInitialValues({});
  await appState.load();
  appState.startFreshForAccount('Tester');
  appState.cancelPremium();
  appState.aiEnabled = false;
  appState.coins = 3000;
  appState.addTask('Plan tomorrow', TaskKind.todo, icon: '📅');
  appState.addTask('Stretch', TaskKind.daily, icon: '🧘');
  appState.addReflection('Good day', day: 7, energy: 6, mood: 8, focus: 5);
  appState.addFood('Oats', 350, 12, 60, 6);
  await friends.load();
  for (final f in friends.suggestions().take(4).toList()) {
    await friends.addByUsername(f.username);
  }
  shellTab.value = 0;
}

typedef _Screen = ({String name, Widget Function() build, int tab});

Future<void> _show(WidgetTester t, _Screen s) async {
  await t.runAsync(_seed);
  shellTab.value = 0;
  await t.pumpWidget(MaterialApp(
    key: UniqueKey(),
    navigatorKey: _nav,
    theme: hrTheme(),
    home: s.build(),
  ));
  await _settle(t);
  // The shell always opens on Today; switch the bottom nav like a user would.
  if (s.tab != 0) {
    shellTab.value = s.tab;
    await _settle(t);
  }
}

Offset? _center(Element e) {
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
  final c = ro.localToGlobal(ro.size.center(Offset.zero));
  final view = _viewSize;
  if (c.dx < 0 || c.dy < 0 || c.dx > view.width || c.dy > view.height) return null;
  return c;
}

Size _viewSize = Size.zero;

// Plugin / platform calls that only exist on a device: answer them quietly.
void _mockPlatform() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final ch in [
    'dev.fluttercommunity.plus/share',
    'plugins.flutter.io/image_picker',
    'plugins.flutter.io/url_launcher',
  ]) {
    m.setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
  }
}

bool _ignorable(Object e) {
  final s = e.toString();
  return s.contains('MissingPluginException') ||
      s.contains('No implementation found for method') ||
      s.contains('channel-error'); // pigeon plugins with no host side
}

Future<List<String>> _sweep(WidgetTester t, _Screen s) async {
  final failures = <String>[];
  final hit = <String, int>{'tap': 0, 'long': 0};
  for (final mode in ['tap', 'long']) {
    for (var i = 0; i < 120; i++) {
      await _show(t, s);
      final els = find
          .byWidgetPredicate(mode == 'tap' ? _tappable : _longPressable)
          .evaluate()
          .toList();
      if (i >= els.length) break;
      final el = els[i];
      final at = _center(el);
      if (at == null) continue;
      final label = _label(el);
      hit[mode] = hit[mode]! + 1;
      Object? err;
      try {
        if (mode == 'tap') {
          await t.tapAt(at);
        } else {
          await t.longPressAt(at);
        }
        await _settle(t);
        // Let snackbars, timers and closing animations finish.
        await t.pump(const Duration(seconds: 5));
        await _settle(t, 3);
      } catch (e) {
        err = e;
      }
      final ex = t.takeException();
      for (final e in [err, ex]) {
        if (e != null && !_ignorable(e)) {
          failures.add('${s.name} · $mode #$i $label → '
              '${e.toString().split('\n').first}');
        }
      }
      // Tear down any route/sheet/dialog the control opened.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
    }
  }
  debugPrint('SWEEP ${s.name}: ${hit['tap']} taps, ${hit['long']} long-presses');
  return failures;
}

void main() {
  final screens = <_Screen>[
    for (final (i, n) in ['today', 'focus', 'progress', 'friends', 'profile'].indexed)
      (name: n, build: () => const HomeShell(), tab: i),
    (name: 'calendar', build: () => const CalendarScreen(), tab: 0),
    (name: 'stats', build: () => const StatsScreen(), tab: 0),
    (name: 'awards', build: () => const AwardsScreen(), tab: 0),
    (name: 'journal', build: () => const JournalScreen(), tab: 0),
    (name: 'share', build: () => const ShareCardScreen(), tab: 0),
    (name: 'shop', build: () => const ShopScreen(), tab: 0),
    (name: 'challenges', build: () => const ChallengesScreen(), tab: 0),
    (name: 'tasks', build: () => const TasksScreen(), tab: 0),
    (name: 'recovery', build: () => const RecoveryScreen(), tab: 0),
    (name: 'nutrition', build: () => const NutritionScreen(), tab: 0),
    (name: 'companions', build: () => const CompanionsScreen(), tab: 0),
    (name: 'premium', build: () => const PremiumScreen(), tab: 0),
    (name: 'party', build: () => const PartyScreen(), tab: 0),
    (name: 'guilds', build: () => const GuildsScreen(), tab: 0),
    (name: 'global_chat', build: () => const GlobalChatScreen(), tab: 0),
    (name: 'body_profile', build: () => const BodyProfileScreen(), tab: 0),
    (name: 'appearance', build: () => const AppearanceScreen(), tab: 0),
    (name: 'legacy', build: () => const LegacyScreen(), tab: 0),
    (name: 'settings', build: () => const AppSettingsScreen(), tab: 0),
    (name: 'dashboard', build: () => const DashboardScreen(), tab: 0),
    (name: 'welcome', build: () => const WelcomeScreen(), tab: 0),
    (name: 'onboarding', build: () => const OnboardingScreen(), tab: 0),
    (name: 'personalize', build: () => const OnboardingQuizScreen(), tab: 0),
    (name: 'signup', build: () => const SignUpScreen(), tab: 0),
    (name: 'login', build: () => const LoginScreen(), tab: 0),
    (name: 'friend_profile',
        build: () => FriendProfileScreen(friendId: friends.friends.first.id), tab: 0),
  ];

  for (final s in screens) {
    testWidgets('every control on ${s.name} works', (t) async {
      t.view.physicalSize = const Size(390 * 2, 2600 * 2);
      t.view.devicePixelRatio = 2;
      _viewSize = const Size(390, 2600);
      addTearDown(t.view.reset);
      _mockPlatform();
      await t.runAsync(loadAppFonts);
      final failures = await _sweep(t, s);
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
