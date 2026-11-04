// End-to-end feature checks: each test drives the real UI (taps, text entry,
// sheets, dialogs) and asserts the resulting app state and what's on screen.
import 'package:flutter/cupertino.dart' show CupertinoTimerPicker;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/buddies.dart';
import 'package:habitrail/core.dart';
import 'package:habitrail/friends.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';
import 'package:habitrail/ui/hr_widgets.dart';

import '../support/app_fonts.dart';

final _nav = GlobalKey<NavigatorState>();

Future<void> _settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

/// A fresh app on a tall phone viewport (most pages fit without scrolling).
Future<void> _app(WidgetTester t, {Widget home = const HomeShell()}) async {
  t.view.physicalSize = const Size(390 * 2, 2400 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.runAsync(loadAppFonts);
  SharedPreferences.setMockInitialValues({});
  await t.runAsync(appState.load);
  appState.startFreshForAccount('Tester');
  appState.cancelPremium();
  appState.aiEnabled = false; // no network in tests
  shellTab.value = 0;
  await t.runAsync(friends.load);
  await t.runAsync(buddies.load);
  await t.pumpWidget(MaterialApp(navigatorKey: _nav, theme: hrTheme(), home: home));
  await _settle(t);
}

Future<void> _open(WidgetTester t, Widget page) async {
  _nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
  await _settle(t);
}

Future<void> _tap(WidgetTester t, Finder f) async {
  expect(f, findsWidgets, reason: 'nothing to tap for $f');
  await t.tap(f.first, warnIfMissed: false);
  await _settle(t);
}

/// The celebration popup's single action button, if one is showing.
Finder _momentButton() =>
    find.descendant(of: find.byType(Dialog), matching: find.byType(HrButton));

Future<void> _dismissMoment(WidgetTester t) async {
  if (_momentButton().evaluate().isNotEmpty) await _tap(t, _momentButton());
}

Future<void> _tab(WidgetTester t, int i) async {
  shellTab.value = i;
  await _settle(t);
}

void main() {
  group('Welcome', () {
    testWidgets('signed out, the only ways in are Create account and Log in',
        (t) async {
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.runAsync(loadAppFonts);
      // A device that used guest mode before it was removed still can't skip in.
      SharedPreferences.setMockInitialValues({'auth.guest.v1': true});
      await t.runAsync(appState.load);
      await t.pumpWidget(
          MaterialApp(navigatorKey: _nav, theme: hrTheme(), home: const AuthGate()));
      await _settle(t);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(HomeShell), findsNothing);
      expect(find.text('Continue without an account'), findsNothing);
      expect(find.byType(HrButton), findsNWidgets(2));
      await _tap(t, find.text('Create account'));
      expect(find.byType(SignUpScreen), findsOneWidget);
      _nav.currentState!.pop();
      await _settle(t);
      await _tap(t, find.text('Log in'));
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('Today', () {
    testWidgets('tapping a quest completes it, awards XP, and undoes', (t) async {
      await _app(t);
      final h = appState.habits.first;
      await _tap(t, find.text(h.name));
      expect(appState.doneToday(h), isTrue);
      expect(appState.totalXp, greaterThan(0));
      // First completion earns "First Step" → its celebration popup shows.
      expect(find.text('First Step'), findsOneWidget);
      expect(_momentButton(), findsOneWidget);
      await _dismissMoment(t);
      final xp = appState.totalXp;
      await _tap(t, find.text(h.name));
      expect(appState.doneToday(h), isFalse);
      expect(appState.totalXp, lessThan(xp));
    });

    testWidgets('+ adds a habit through the editor sheet', (t) async {
      await _app(t);
      final n = appState.habits.length;
      await _tap(t, find.byTooltip('Add habit'));
      await t.enterText(find.byType(TextField).last, 'Walk the dog');
      await _settle(t);
      await _tap(t, find.text('Add habit'));
      expect(appState.habits.length, n + 1);
      expect(appState.habits.last.name, 'Walk the dog');
      expect(find.text('Walk the dog'), findsOneWidget);
    });

    testWidgets('long-press → Delete removes a habit', (t) async {
      await _app(t);
      final h = appState.habits.first;
      await t.longPress(find.text(h.name));
      await _settle(t);
      await _tap(t, find.text('Delete habit'));
      await _tap(t, find.text('Delete'));
      expect(appState.habits.any((x) => x.id == h.id), isFalse);
    });

    testWidgets('long-press → Edit renames a habit', (t) async {
      await _app(t);
      final h = appState.habits.first;
      await t.longPress(find.text(h.name));
      await _settle(t);
      await _tap(t, find.text('Edit habit'));
      await t.enterText(find.byType(TextField).last, 'Renamed habit');
      await _settle(t);
      await _tap(t, find.text('Save'));
      expect(h.name, 'Renamed habit');
    });

    testWidgets('reorder mode toggles on and off', (t) async {
      await _app(t);
      await _tap(t, find.byTooltip('Reorder quests'));
      expect(find.byIcon(Icons.drag_handle_rounded), findsWidgets);
      await _tap(t, find.byTooltip('Done reordering'));
      expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    });

    testWidgets('streak card opens Recovery; banner opens Dashboard', (t) async {
      await _app(t);
      await _tap(t, find.text('day streak'));
      expect(find.text('Recovery'), findsOneWidget);
      _nav.currentState!.pop();
      await _settle(t);
      await _tap(t, find.text('Dashboard'));
      expect(find.text('Your progress'), findsOneWidget);
    });
  });

  group('Focus', () {
    testWidgets('a Short session runs, completes and awards XP', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Short'));
      expect(find.text('05:00'), findsOneWidget);
      await _tap(t, find.text('Start Focus'));
      expect(find.text('Stay with it'), findsOneWidget);
      await t.pump(const Duration(seconds: 301));
      await _settle(t);
      expect(find.text('Session complete'), findsOneWidget);
      expect(appState.focusMinutesToday, 5);
      expect(appState.dailyFocus[dateKey(DateTime.now())], 5);
      await _tap(t, find.text('Back to Today'));
      expect(shellTab.value, 0);
    });

    testWidgets('pause, resume and reset work', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Start Focus'));
      await t.pump(const Duration(seconds: 3));
      await _tap(t, find.text('Pause'));
      expect(find.text('Paused'), findsOneWidget);
      await _tap(t, find.text('Resume'));
      await _tap(t, find.text('Reset'));
      expect(find.text('25:00'), findsOneWidget);
    });

    testWidgets('Custom length and focus mode pickers', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Custom'));
      await _tap(t, find.text('10 min'));
      await _tap(t, find.text('Set 10 min'));
      expect(find.text('10:00'), findsOneWidget);
      await _tap(t, find.byTooltip('Focus mode'));
      await _tap(t, find.text('Study'));
      expect(find.text('Study'), findsWidgets);
    });
  });

  group('Focus custom length', () {
    testWidgets('any length from the wheel, shown as h:mm:ss', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Custom'));
      t
          .widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker))
          .onTimerDurationChanged(const Duration(hours: 1, minutes: 15));
      await _settle(t);
      await _tap(t, find.text('Set 1 h 15 min'));
      expect(find.text('1:15:00'), findsOneWidget);
      expect(find.text('1 h 15 min'), findsOneWidget); // Custom tile
      expect(find.textContaining('+150 XP'), findsOneWidget);
    });

    testWidgets('an odd custom length runs to completion', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Custom'));
      t
          .widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker))
          .onTimerDurationChanged(const Duration(minutes: 37));
      await _settle(t);
      await _tap(t, find.text('Set 37 min'));
      expect(find.text('37:00'), findsOneWidget);
      await _tap(t, find.text('Start Focus'));
      await t.pump(const Duration(minutes: 37, seconds: 1));
      await _settle(t);
      expect(find.text('Session complete'), findsOneWidget);
      expect(appState.focusMinutesToday, 37);
    });

    testWidgets('a zero length cannot be set', (t) async {
      await _app(t);
      await _tab(t, 1);
      await _tap(t, find.text('Custom'));
      t
          .widget<CupertinoTimerPicker>(find.byType(CupertinoTimerPicker))
          .onTimerDurationChanged(Duration.zero);
      await _settle(t);
      expect(find.text('Pick at least 1 minute'), findsOneWidget);
      await _tap(t, find.text('Pick at least 1 minute'));
      expect(find.text('Pick at least 1 minute'), findsOneWidget); // still open
    });
  });

  group('Progress', () {
    testWidgets('period switch, journey links and leaderboard jump', (t) async {
      await _app(t);
      await _tab(t, 2);
      await _tap(t, find.text('Year'));
      expect(find.text('XP this year'), findsOneWidget);
      await _tap(t, find.text('All time'));
      expect(find.text('XP all time'), findsOneWidget);
      for (final (tile, title) in [
        ('Calendar', 'Calendar'),
        ('Stats', 'Stats'),
        ('Awards', 'Awards'),
        ('Journal', 'Journal'),
      ]) {
        await _tap(t, find.text(tile));
        expect(find.text(title), findsWidgets);
        _nav.currentState!.pop();
        await _settle(t);
      }
      await _tap(t, find.text('Legacy'));
      expect(find.text('Prestige stars'), findsOneWidget);
      _nav.currentState!.pop();
      await _settle(t);
      await _tap(t, find.text('Leaderboard'));
      expect(shellTab.value, 3);
    });

    testWidgets('XP chart: every day shown, today marked, summary line', (t) async {
      await _app(t);
      final now = DateTime.now();
      appState.dailyXp
        ..clear()
        ..[dateKey(now)] = 85;
      await _tab(t, 2);
      expect(find.text('85 XP'), findsWidgets); // header total + best-day label
      expect(find.text('1 active day · avg 85 XP'), findsOneWidget);
      expect(
          find.descendant(of: find.byType(HrCard), matching: find.text('Today')),
          findsOneWidget);
      expect(find.text('${now.day}'), findsWidgets); // today's date under its bar
      await _tap(t, find.text('Year'));
      expect(find.text('1 active month · avg 85 XP'), findsOneWidget);
      expect(find.text('This month'), findsOneWidget);
    });

    testWidgets('All time runs January to December across every year', (t) async {
      await _app(t);
      appState.dailyXp
        ..clear()
        ..['2024-12-03'] = 40
        ..['2025-12-20'] = 60 // December again, a year later
        ..['2026-01-05'] = 50;
      await _tab(t, 2);
      await _tap(t, find.text('All time'));
      final card = find.ancestor(
          of: find.text('XP all time'), matching: find.byType(HrCard));
      final months = t
          .widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
          .map((w) => w.data)
          .where((d) => d != null && RegExp(r'^[JFMASOND]$').hasMatch(d))
          .toList();
      expect(months, ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D']);
      expect(find.text('150 XP'), findsOneWidget); // header total
      expect(find.text('100 XP'), findsOneWidget); // December's two years
      expect(find.text('2 active months · avg 75 XP'), findsOneWidget);
    });

    testWidgets('achievements: next ones first, then most recent first', (t) async {
      await _app(t);
      // A fresh account's 9 starter habits already earn Collector; start
      // from zero progress instead.
      for (final h in appState.habits.toList()) {
        appState.deleteHabit(h);
      }
      appState.earnedAchievements.clear(); // earned awards are kept for good
      await _tab(t, 2);
      // Nothing earned yet: say what's next and how to earn it.
      expect(appState.recentAchievements, isEmpty);
      expect(find.text('Next achievements'), findsOneWidget);
      expect(find.text('Complete your first habit'), findsOneWidget);
      expect(find.text('Locked'), findsNothing);
      // Earned in this order: Getting Started, then First Step.
      appState.earnedAchievements
        ..add('xp100')
        ..add('first');
      appState.notifyListeners();
      await _settle(t);
      expect(find.text('Recent achievements'), findsOneWidget);
      expect(appState.recentAchievements.map((a) => a.id).take(2),
          ['first', 'xp100']);
      // Tapping a tile opens that award's details.
      await _tap(t, find.text('First Step'));
      expect(find.text('COMMON · EARNED'), findsOneWidget);
    });

    test('XP chart scale keeps one day from filling the chart', () {
      final one = [0, 120, 0, 0];
      expect(120 / xpChartScale(one), closeTo(0.5, 0.01));
      final busy = [for (var d = 0; d < 25; d++) 100 + d * 10];
      expect(340 / xpChartScale(busy), greaterThan(0.8));
      expect(20 / xpChartScale([20]), lessThanOrEqualTo(0.2)); // small stays small
      expect(xpChartScale([0, 0]), 1);
    });
  });

  group('Friends', () {
    testWidgets('buddy streak: start one, check in, end it', (t) async {
      await _app(t);
      await _tab(t, 3);
      expect(find.text('Buddy streaks'), findsOneWidget);
      await _tap(t, find.text('Start')); // opens the friend picker
      final f = friends.friends.first;
      await _tap(t, find.descendant(
          of: find.byType(BottomSheet), matching: find.text('Start')));
      final b = buddies.forFriend(f.id)!;
      expect(b.active, isTrue); // demo friends accept straight away
      expect(find.text('day buddy streak'), findsOneWidget);
      expect(find.text('Your turn to check in').evaluate().isNotEmpty ||
          find.text('${f.name} checked in · your turn').evaluate().isNotEmpty,
          isTrue);

      // Finishing a habit is a check-in, and the card says so at once.
      appState.toggle(appState.habits.first);
      await _settle(t);
      await _dismissMoment(t);
      expect(buddies.meToday(b), isTrue);
      expect(
          find.text(buddies.themToday(b)
              ? 'Both checked in today'
              : 'Waiting on ${f.name}'),
          findsOneWidget);

      // End it from their profile.
      await _tap(t, find.text('day buddy streak'));
      expect(find.text('End buddy streak'), findsOneWidget);
      await _tap(t, find.text('End buddy streak'));
      await _tap(t, find.text('End streak'));
      expect(buddies.forFriend(f.id), isNull);
      expect(find.text('Start a buddy streak'), findsOneWidget);
    });

    testWidgets('no friends: empty board with an invite action', (t) async {
      await _app(t);
      for (final f in friends.friends.toList()) {
        friends.remove(f.id);
      }
      await _tab(t, 3);
      expect(find.text('Your friends will appear here'), findsOneWidget);
      expect(find.textContaining('IN THE RACE'), findsNothing);
      expect(find.text('—'), findsNothing); // no empty podium places
      expect(find.text('Share an invite'), findsOneWidget);
      expect(find.text('Invite friends'), findsNothing);
      await _tap(t, find.text('Add friends'));
      expect(find.text('Your friends will appear here'), findsNothing);
      expect(find.text('No friends yet'), findsOneWidget); // Add Friends tab
    });

    testWidgets('add a friend and see them on the leaderboard', (t) async {
      await _app(t);
      await _tab(t, 3);
      await _tap(t, find.text('Add Friends'));
      final who = friends.suggestions().first;
      await t.enterText(find.byType(TextField).first, who.username);
      await _settle(t);
      await _tap(t, find.text('Add'));
      expect(friends.friends.any((f) => f.username == who.username), isTrue);
      await _tap(t, find.text('Leaderboard'));
      expect(find.text(who.name), findsWidgets);
    });
  });

  group('Profile', () {
    testWidgets('menu rows open their pages; name edit; settings', (t) async {
      await _app(t);
      await _tab(t, 4);
      for (final (row, title) in [
        ('Achievements', 'Awards'),
        ('Statistics', 'Stats'),
        ('Companions', 'Companions'),
        ('Shop', 'Shop'),
        ('Tasks', 'Tasks'),
        ('Challenges', 'Challenges'),
        ('Recovery', 'Recovery'),
        ('Nutrition', 'Nutrition'),
        ('Appearance', 'Appearance'),
        ('Settings', 'Settings'),
      ]) {
        await _tap(t, find.text(row));
        expect(find.text(title), findsWidgets, reason: '$row → $title');
        _nav.currentState!.pop();
        await _settle(t);
      }
      await _tap(t, find.byTooltip('Edit name'));
      await t.enterText(find.byType(TextField).last, 'Renamed');
      await _settle(t);
      await _tap(t, find.text('Save'));
      expect(appState.displayName, 'Renamed');
      expect(find.text('Renamed'), findsWidgets);
      await _tap(t, find.text('Social'));
      expect(shellTab.value, 3);
    });

    testWidgets('settings: reset all progress', (t) async {
      await _app(t);
      appState.toggle(appState.habits.first);
      await _open(t, const AppSettingsScreen());
      await _tap(t, find.text('Reset all progress'));
      await _tap(t, find.text('Reset everything'));
      expect(appState.totalXp, 0);
    });

    testWidgets('settings: notification switches', (t) async {
      await _app(t);
      appState.setNotificationPrefs(
          reminders: true, streakAlert: true, streakAlertAt: 20 * 60);
      appState.setHabitReminder(appState.habits.first, 9 * 60);
      await _open(t, const AppSettingsScreen());
      await _tap(t, find.text('Notifications'));
      // Widget tests can't reach the OS, so the page says so (and the in-app
      // nudge keeps covering reminders).
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(find.text('1 habit has a reminder'), findsOneWidget);
      expect(find.text('8:00 PM'), findsOneWidget);
      final who = companionByType(appState.activeCompanion);
      expect(find.text('${who.name}: ${companionLine(who.type, 'reminder')}'),
          findsOneWidget);
      await _tap(t, find.byType(Switch).first);
      expect(appState.remindersOn, isFalse);
      await _tap(t, find.byType(Switch).last);
      expect(appState.streakAlertOn, isFalse);
      expect(find.text('Alert time'), findsNothing);
    });
  });

  group('Economy', () {
    testWidgets('shop: buy a booster and a border', (t) async {
      await _app(t);
      appState.coins = 1000;
      await _open(t, const ShopScreen());
      await _tap(t, find.text('150'));
      expect(appState.xpBoostActive, isTrue);
      await _tap(t, find.text('120')); // Cyan Pulse
      expect(appState.selectedBorder, 'cyan');
      expect(appState.coins, 1000 - 150 - 120);
    });

    testWidgets('appearance: unlock and apply a theme', (t) async {
      await _app(t);
      appState.coins = 1000;
      await _open(t, const AppearanceScreen());
      await _tap(t, find.text('200'));
      await _tap(t, find.text('Unlock · 200'));
      expect(appState.themeId, isNot('violet'));
      expect(appState.coins, 800);
    });

    testWidgets('premium: start (no store) activates it', (t) async {
      await _app(t);
      await _open(t, const PremiumScreen());
      await _tap(t, find.text('Monthly'));
      await _tap(t, find.textContaining('Start Premium'));
      expect(appState.isPremium, isTrue);
      expect(appState.premiumPlan, 'monthly');
    });
  });

  group('Pages', () {
    testWidgets('tasks: add, check off and edit', (t) async {
      await _app(t);
      await _open(t, const TasksScreen());
      await _tap(t, find.text('Add a task'));
      await t.enterText(find.byType(TextField).first, 'Buy milk');
      await _settle(t);
      await _tap(t, find.text('Add task'));
      final task = appState.tasks.firstWhere((x) => x.title == 'Buy milk');
      expect(find.text('Buy milk'), findsOneWidget);
      await _tap(t, find.text('Buy milk'));
      expect(appState.taskDoneToday(task), isTrue);
      await _tap(t, find.text('To-Dos'));
      expect(find.text('Buy milk'), findsOneWidget);
      await t.longPress(find.text('Buy milk'));
      await _settle(t);
      await _tap(t, find.text('Delete task'));
      expect(appState.tasks.any((x) => x.title == 'Buy milk'), isFalse);
    });

    testWidgets('journal: write a rated reflection', (t) async {
      await _app(t);
      await _open(t, const JournalScreen());
      await _tap(t, find.text('Write reflection'));
      await _tap(t, find.text('7'));
      await t.enterText(find.byType(TextField).last, 'Good day');
      await _settle(t);
      await _tap(t, find.text('Save reflection'));
      expect(appState.reflections.length, 1);
      expect(appState.reflections.first.day, 7);
      // +20 for the reflection, +40 for the "Write a reflection" daily quest.
      expect(appState.totalXp, 60);
      expect(find.text('Good day'), findsOneWidget);
    });

    testWidgets('journal: long-press an entry to edit or delete it', (t) async {
      await _app(t);
      appState.addReflection('Old note', day: 5);
      await _open(t, const JournalScreen());
      await t.longPress(find.text('Old note'));
      await _settle(t);
      await _tap(t, find.text('Edit reflection'));
      await t.enterText(find.byType(TextField).last, 'New note');
      await _settle(t);
      await _tap(t, find.text('Save changes'));
      expect(appState.reflections.first.text, 'New note');
      await t.longPress(find.text('New note'));
      await _settle(t);
      await _tap(t, find.text('Delete reflection'));
      await _tap(t, find.text('Delete'));
      expect(appState.reflections, isEmpty);
    });

    testWidgets('nutrition: log and remove a meal', (t) async {
      await _app(t);
      await _open(t, const NutritionScreen());
      await _tap(t, find.text('Log meal'));
      final fields = find.byType(TextField);
      await t.enterText(fields.at(1), 'Oats');
      await t.enterText(fields.at(2), '350');
      await _settle(t);
      await _tap(t, find.text('Add'));
      expect(appState.foodLog.length, 1);
      expect(find.text('Oats'), findsOneWidget);
      await _tap(t, find.byTooltip('Remove'));
      expect(appState.foodLog, isEmpty);
    });

    testWidgets('companions: browse and set active', (t) async {
      await _app(t);
      await _open(t, const CompanionsScreen());
      await _tap(t, find.byTooltip('Next companion'));
      expect(find.text('Fenrir'), findsWidgets);
      await _tap(t, find.text('Set as Active Companion'));
      expect(appState.activeCompanion, 'wolf');
    });

    testWidgets('challenges: premium start and check in', (t) async {
      await _app(t);
      appState.activatePremium('annual');
      await _open(t, const ChallengesScreen());
      await _tap(t, find.text('Start'));
      expect(appState.activeChallenge, isNotNull);
      await _tap(t, find.text('Check in for today'));
      expect(appState.challengeCheckedInToday, isTrue);
    });

    testWidgets('challenges: free users are sent to Premium', (t) async {
      await _app(t);
      await _open(t, const ChallengesScreen());
      await _tap(t, find.text('Start'));
      expect(find.text('Premium'), findsWidgets);
      expect(appState.activeChallenge, isNull);
    });

    testWidgets('recovery: rest day (premium) and shortcuts', (t) async {
      await _app(t);
      appState.activatePremium('annual');
      await _open(t, const RecoveryScreen());
      await _tap(t, find.text('Take Rest Day'));
      expect(appState.restDayActiveToday, isTrue);
      await _tap(t, find.text('Get Streak Shields'));
      expect(find.text('Shop'), findsWidgets);
      _nav.currentState!.pop();
      await _settle(t);
      await _tap(t, find.text('Open Focus'));
      expect(shellTab.value, 1);
    });

    testWidgets('calendar: select a past day', (t) async {
      await _app(t);
      await _open(t, const CalendarScreen());
      final now = DateTime.now();
      if (now.day > 1) {
        await _tap(t, find.text('1'));
        expect(find.textContaining('${_months[now.month - 1]} 1,'), findsOneWidget);
      }
    });

    testWidgets('stats: week switch', (t) async {
      await _app(t);
      await _open(t, const StatsScreen());
      await _tap(t, find.text('This week'));
      await _tap(t, find.text('Last week'));
      expect(find.text('Last week'), findsWidgets);
    });

    testWidgets('awards: filter and details', (t) async {
      await _app(t);
      await _open(t, const AwardsScreen());
      await _tap(t, find.text('Streaks'));
      expect(find.text('First Step'), findsNothing);
      await _tap(t, find.text('All'));
      await _tap(t, find.text('First Step'));
      expect(find.text('Complete your first habit'), findsWidgets);
    });

    testWidgets('body profile saves targets', (t) async {
      await _app(t);
      await _open(t, const BodyProfileScreen());
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '30');
      await t.enterText(fields.at(1), '180');
      await t.enterText(fields.at(2), '80');
      await _settle(t);
      await _tap(t, find.text('Save'));
      expect(appState.bodyProfile, isNotNull);
      expect(appState.bodyProfile!.age, 30);
    });

    testWidgets('legacy: rebirth explains the level gate', (t) async {
      await _app(t);
      await _open(t, const LegacyScreen());
      await _tap(t, find.text('Rebirth'));
      expect(find.textContaining('Prestige unlocks'), findsOneWidget);
    });

    testWidgets('daily briefing pages through and closes', (t) async {
      SharedPreferences.setMockInitialValues({});
      await _app(t, home: const SizedBox());
      appState.lastBriefingDate = '';
      _nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const HomeShell()));
      await _settle(t);
      for (var i = 0; i < 4; i++) {
        await _tap(t, find.text('Next'));
      }
      await _tap(t, find.text('Start the day'));
      expect(appState.needsBriefing, isFalse);
      expect(find.text('Start the day'), findsNothing);
    });

    testWidgets('onboarding quiz seeds habits for chosen areas', (t) async {
      await _app(t, home: const SizedBox());
      await _open(t, const OnboardingQuizScreen());
      await _tap(t, find.text('Fitness'));
      await _tap(t, find.text('Next')); // → gender
      await _tap(t, find.text('Next')); // → age
      await t.enterText(find.byType(TextField).first, '28');
      await _settle(t);
      await _tap(t, find.text('Next')); // → height & weight
      final f = find.byType(TextField);
      await t.enterText(f.at(0), '175');
      await t.enterText(f.at(1), '70');
      await _settle(t);
      await _tap(t, find.text('Next')); // → activity
      await _tap(t, find.text('Next')); // → goal
      await _tap(t, find.text('Next')); // → summary
      await _tap(t, find.text("Let's go"));
      expect(appState.bodyProfile?.age, 28);
    });
  });
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];
