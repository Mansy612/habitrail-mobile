import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/core.dart';
import 'package:habitrail/ai.dart';

void main() {
  // AppState mutations call _save() → SharedPreferences; give it a mock store.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('progression', () {
    test('xpForLevel grows ~15% per level', () {
      expect(xpForLevel(1), 100);
      expect(xpForLevel(2), (100 * 1.15).floor());
    });
    test('levelFromXp maps totalXp to level/progress', () {
      final a = levelFromXp(0);
      expect(a.level, 1);
      expect(a.currentXp, 0);
      expect(a.requiredXp, 100);
      expect(levelFromXp(100).level, 2);
      expect(levelFromXp(50).level, 1);
    });
    test('levelTitle picks the right milestone', () {
      expect(levelTitle(1), 'Initiate');
      expect(levelTitle(3), 'Initiate');
      expect(levelTitle(5), 'Acolyte');
      expect(levelTitle(15), 'Operator');
      expect(levelTitle(100), 'God-Tier');
    });
  });

  group('xp gain', () {
    test('rarity scales the award', () {
      expect(calculateXpGain(100, 'common', 0, 1.0), 20);
      expect(calculateXpGain(100, 'epic', 0, 1.0), 40);
      expect(calculateXpGain(100, 'legendary', 0, 1.0), 60);
    });
    test('streak bonus and combo increase it', () {
      expect(calculateXpGain(100, 'common', 30, 1.0),
          greaterThan(calculateXpGain(100, 'common', 0, 1.0)));
      expect(comboMultiplier(1), 1.0);
      expect(comboMultiplier(3), 1.5);
      expect(comboMultiplier(10), 3.0);
    });
    test('projectedXp previews exactly what toggling awards', () {
      final s = AppState()..addHabit('Read 10 pages', 'rare');
      final h = s.habits.last;
      final preview = s.projectedXp(h);
      expect(preview, greaterThan(0));
      s.toggle(h);
      expect(h.todayAwardXp, preview);
      expect(s.projectedXp(h), preview); // done → the awarded amount
    });
  });

  group('daily activity log', () {
    test('habit toggles add and undo today\'s XP and quest count', () {
      final s = AppState()..addHabit('Read 10 pages', 'rare');
      final h = s.habits.last;
      final today = dateKey(DateTime.now());
      s.toggle(h);
      expect(s.dailyXp[today], h.todayAwardXp);
      expect(s.dailyDone[today], 1);
      s.toggle(h); // undo
      expect(s.dailyXp[today], isNull);
      expect(s.dailyDone[today], isNull);
    });
    test('focus sessions log minutes and XP; sumDays totals a range', () {
      final s = AppState();
      final gain = s.completeFocus(25);
      final today = DateTime.now();
      final k = dateKey(today);
      expect(s.dailyFocus[k], 25);
      expect(s.dailyXp[k], greaterThanOrEqualTo(gain));
      final tomorrow = today.add(const Duration(days: 1));
      expect(s.sumDays(s.dailyFocus, today, tomorrow), 25);
      expect(s.sumDays(s.dailyFocus, tomorrow, tomorrow), 0);
    });
    test('activity survives a save/load round trip', () async {
      final s = AppState();
      await s.load();
      s.completeFocus(30);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final again = AppState();
      await again.load();
      expect(again.dailyFocus[dateKey(DateTime.now())], 30);
    });
  });

  group('auto difficulty', () {
    test('infers rarity from keywords', () {
      expect(inferRarity('Morning workout'), 'epic');
      expect(inferRarity('Read 10 pages'), 'rare');
      expect(inferRarity('Cold shower'), 'legendary');
      expect(inferRarity('Make bed'), 'common');
    });
    test('bigger effort numbers bump difficulty', () {
      expect(inferRarity('Sauna 50 min'), 'epic');
      expect(inferRarity('Stand 25 min'), 'rare');
    });
    test('estimatedXp tracks rarity', () {
      expect(estimatedXp('common'), lessThan(estimatedXp('epic')));
    });
  });

  group('ai difficulty rating', () {
    test('heuristic verdict mirrors inferRarity and is not AI', () {
      final v = heuristicVerdict('Morning workout');
      expect(v.rarity, 'epic');
      expect(v.fromAi, isFalse);
      expect(v.reason, isNotEmpty);
    });

    test('parses a valid Ollama tier as an AI verdict', () {
      final v = parseOllamaVerdict('{"tier":"legendary","reason":"hard run"}');
      expect(v, isNotNull);
      expect(v!.rarity, 'legendary');
      expect(v.fromAi, isTrue);
      expect(v.reason, 'hard run');
      expect(v.multiplier, rarityConfig['legendary']!.mult);
    });

    test('maps effort-word synonyms to tiers', () {
      expect(parseOllamaVerdict('{"tier":"easy"}')?.rarity, 'common');
      expect(parseOllamaVerdict('{"tier":"hard"}')?.rarity, 'legendary');
      expect(parseOllamaVerdict('{"tier":"extreme"}')?.rarity, 'mythic');
    });

    test('rejects malformed or unknown output', () {
      expect(parseOllamaVerdict('not json'), isNull);
      expect(parseOllamaVerdict('{"tier":"banana"}'), isNull);
      expect(parseOllamaVerdict('{"reason":"no tier"}'), isNull);
    });

    test('classify falls back to the heuristic when AI is off', () async {
      final v = await classifyDifficulty('Cold shower',
          enabled: false, baseUrl: kDefaultAiBaseUrl, model: kDefaultAiModel);
      expect(v.fromAi, isFalse);
      expect(v.rarity, 'legendary');
    });

    test('classify returns common for an empty name', () async {
      final v = await classifyDifficulty('   ',
          enabled: true, baseUrl: kDefaultAiBaseUrl, model: kDefaultAiModel);
      expect(v.rarity, 'common');
    });

    test('an AI rating freezes onto the habit and drives XP deterministically',
        () {
      final s = AppState();
      s.addHabit('Deep work', 'legendary',
          aiRated: true, reason: 'demanding focus');
      final h = s.habits.single;
      expect(h.aiRated, isTrue);
      expect(h.difficultyReason, 'demanding focus');
      // Survives a round-trip through storage.
      final restored = Habit.fromMap(h.toMap());
      expect(restored.rarity, 'legendary');
      expect(restored.aiRated, isTrue);
      expect(restored.difficultyReason, 'demanding focus');
      // Reward path uses the frozen tier — no model call involved.
      final before = s.totalXp;
      s.toggle(h);
      expect(s.totalXp - before,
          calculateXpGain(h.baseXp, 'legendary', h.streak, comboMultiplier(1)));
    });
  });

  group('ai nutrition', () {
    test('parses a meal into macros', () {
      final e = parseNutritionJson(
          '{"name":"Eggs & toast","calories":320,"protein":18,"carbs":26,"fat":15}');
      expect(e, isNotNull);
      expect(e!.name, 'Eggs & toast');
      expect(e.calories, 320);
      expect(e.protein, 18);
      expect(e.carbs, 26);
      expect(e.fat, 15);
      expect(e.fromAi, isTrue);
    });

    test('coerces string numbers, clamps negatives, uses fallback name', () {
      final e = parseNutritionJson(
          '{"calories":"450 kcal","protein":"30","carbs":"-5","fat":10}',
          fallbackName: 'Lunch');
      expect(e, isNotNull);
      expect(e!.calories, 450);
      expect(e.protein, 30);
      expect(e.carbs, 0); // negative clamped to 0
      expect(e.name, 'Lunch'); // no name field → fallback
    });

    test('returns null on garbage or all-zero macros', () {
      expect(parseNutritionJson('not json'), isNull);
      expect(parseNutritionJson('{"calories":0,"protein":0,"carbs":0,"fat":0}'),
          isNull);
    });

    test('estimate is null when AI is off', () async {
      final e = await estimateNutrition('2 eggs and toast',
          enabled: false, baseUrl: kDefaultAiBaseUrl, model: kDefaultAiModel);
      expect(e, isNull);
    });

    test('estimate is null for an empty description', () async {
      final e = await estimateNutrition('   ',
          enabled: true, baseUrl: kDefaultAiBaseUrl, model: kDefaultAiModel);
      expect(e, isNull);
    });
  });

  group('habits & insights', () {
    test('reorderHabits moves a habit to a new position', () {
      final s = AppState();
      s.habits.clear();
      s.addHabit('A', 'common');
      s.addHabit('B', 'common');
      s.addHabit('C', 'common');
      s.reorderHabits(2, 0); // move C to the front
      expect(s.habits.map((h) => h.name).toList(), ['C', 'A', 'B']);
    });

    test('a reminder persists through storage and can be cleared', () {
      final s = AppState();
      s.addHabit('Meditate', 'epic', reminderMinutes: 480); // 8:00 AM
      final h = s.habits.firstWhere((x) => x.name == 'Meditate');
      expect(h.reminderMinutes, 480);
      final restored = Habit.fromMap(h.toMap());
      expect(restored.reminderMinutes, 480);
      s.setHabitReminder(h, null);
      expect(h.reminderMinutes, isNull);
    });

    test('avgScoreLastDays averages the most recent daily scores', () {
      final s = AppState();
      s.dailyScore['2026-01-01'] = 40;
      s.dailyScore['2026-01-02'] = 60;
      s.dailyScore['2026-01-03'] = 80;
      expect(s.avgScoreLastDays(7), closeTo(60, 0.001)); // all three
      expect(s.avgScoreLastDays(2), closeTo(70, 0.001)); // last two: 60, 80
      expect(AppState().avgScoreLastDays(7), 0); // none recorded
    });

    test('a fresh account seeds 9 habits, 100 coins, level 1, unique ids', () {
      final s = AppState();
      s.startFreshForAccount('newuser');
      expect(s.habits.length, 9);
      expect(s.coins, 100);
      expect(s.totalXp, 0);
      expect(s.level, 1);
      expect(s.habits.map((h) => h.id).toSet().length, 9); // no duplicate ids
    });
  });

  group('tdee + macros', () {
    final p = BodyProfile(
        weight: 80,
        height: 180,
        age: 30,
        gender: 'male',
        activity: 'moderate',
        goal: 'maintain');
    test('Mifflin-St Jeor BMR and TDEE', () {
      expect(computeBMR(p), 1780);
      expect(computeTDEE(p), (1780 * 1.55).roundToDouble());
    });
    test('maintain targets = TDEE; protein per kg', () {
      final t = computeMacroTargets(p);
      expect(t.calories, computeTDEE(p));
      expect(t.protein, (80 * 1.9).roundToDouble());
    });
    test('cut lowers calories, raises protein', () {
      final cut = BodyProfile(
          weight: 80,
          height: 180,
          age: 30,
          gender: 'male',
          activity: 'moderate',
          goal: 'cut');
      final t = computeMacroTargets(cut);
      expect(t.calories, computeTDEE(cut) - 500);
      expect(t.protein, (80 * 2.2).roundToDouble());
    });
  });

  group('phone notifications', () {
    // Noon on a Tuesday; the plan is a pure function of the state and this.
    final now = DateTime(2026, 11, 3, 12);
    final today = dateKey(now);
    final yesterday = dateKey(DateTime(2026, 11, 2));
    Habit habit(AppState s, String name, {int? at}) {
      s.addHabit(name, 'common', reminderMinutes: at);
      return s.habits.last;
    }

    AppState fresh() => AppState()
      ..habits.clear()
      ..streakAlertOn = false;

    test('reminders skip past times and habits already done today', () {
      final s = fresh();
      final morning = habit(s, 'Stretch', at: 9 * 60); // already passed
      final evening = habit(s, 'Read', at: 18 * 60);
      final done = habit(s, 'Walk', at: 18 * 60 + 30)..lastCompletedDate = today;
      habit(s, 'Water'); // no reminder
      final plan = planNotifications(s, now);
      final todays = plan.where((p) => dateKey(p.at) == today).toList();
      expect(todays.map((p) => p.habitId), [evening.id]);
      expect(todays.single.at, DateTime(2026, 11, 3, 18));
      final tomorrow = plan.where((p) => dateKey(p.at) == '2026-11-04');
      expect(tomorrow.map((p) => p.habitId).toSet(),
          {morning.id, evening.id, done.id});
      // A week ahead, then they stop.
      expect(plan.last.at.isBefore(DateTime(2026, 11, 10)), isTrue);
      expect(plan.length, 1 + 6 * 3);
    });

    test('copy is in the companion\'s voice and names an open streak', () {
      final s = fresh()..activeCompanion = 'wolf';
      habit(s, 'Read', at: 18 * 60)
        ..streak = 4
        ..lastCompletedDate = yesterday;
      final plan = planNotifications(s, now);
      expect(plan.first.title, 'Read');
      expect(plan.first.body,
          'Fenrir: The hunt starts now. Keep your 4-day streak going.');
      // Two days unopened: a welcome back instead of the same nudge.
      expect(plan[2].body, 'Fenrir: The pack is waiting for you.');
    });

    test('streak alert fires only while a streak is still open', () {
      final s = fresh()..streakAlertOn = true;
      final h = habit(s, 'Read')
        ..streak = 5
        ..lastCompletedDate = yesterday;
      habit(s, 'Water');
      var alerts = planNotifications(s, now).where((p) => p.payload == 'streak');
      expect(alerts.single.at, DateTime(2026, 11, 3, 20));
      expect(alerts.single.title, '🔥 Your 5-day streak ends at midnight');
      expect(alerts.single.body, endsWith('2 habits left today.'));

      // Kept today: nothing at risk today, tomorrow's alert guards it.
      h
        ..streak = 6
        ..lastCompletedDate = today;
      alerts = planNotifications(s, now).where((p) => p.payload == 'streak');
      expect(alerts.single.at, DateTime(2026, 11, 4, 20));
      expect(alerts.single.title, contains('6-day'));

      // A planned rest day can't break a streak, so no alert that day.
      s.restDays.add('2026-11-04');
      expect(planNotifications(s, now).where((p) => p.payload == 'streak'),
          isEmpty);
    });

    test('a one-day streak and a past alert time send nothing', () {
      final s = fresh()..streakAlertOn = true;
      habit(s, 'Read')
        ..streak = 1
        ..lastCompletedDate = yesterday;
      expect(planNotifications(s, now), isEmpty);
      s.habits.first.streak = 3;
      s.streakAlertMinutes = 11 * 60; // before noon
      expect(planNotifications(s, now), isEmpty);
    });

    test('stays under the iOS limit of 64 pending notifications', () {
      final s = fresh();
      for (var i = 0; i < 100; i++) {
        habit(s, 'Habit $i', at: 13 * 60 + i % 60);
      }
      final plan = planNotifications(s, now);
      expect(plan.length, kMaxPlannedNotifications);
      expect(plan.every((p) => dateKey(p.at) == today), isTrue);
    });

    test('each switch turns its kind off', () {
      final s = fresh()..streakAlertOn = true;
      habit(s, 'Read', at: 18 * 60)
        ..streak = 3
        ..lastCompletedDate = yesterday;
      s.remindersOn = false;
      expect(planNotifications(s, now).map((p) => p.payload).toSet(), {'streak'});
      s
        ..remindersOn = true
        ..streakAlertOn = false;
      expect(planNotifications(s, now).any((p) => p.payload == 'streak'), isFalse);
    });

    test('notification settings survive a save/load round trip', () async {
      final s = AppState();
      await s.load();
      expect(s.remindersOn && s.streakAlertOn, isTrue); // on by default
      s.setNotificationPrefs(
          reminders: false, streakAlertAt: 21 * 60 + 30, asked: true, offered: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final again = AppState();
      await again.load();
      expect(again.remindersOn, isFalse);
      expect(again.streakAlertOn, isTrue);
      expect(again.streakAlertMinutes, 21 * 60 + 30);
      expect(again.notifAsked && again.notifOffered, isTrue);
    });
  });

  group('AppState economy', () {
    test('toggle awards XP then refunds exactly on undo', () {
      final s = AppState();
      s.addHabit('Test', 'common');
      final h = s.habits.first;
      expect(s.totalXp, 0);
      s.toggle(h);
      expect(s.doneToday(h), true);
      expect(s.totalXp, greaterThan(0));
      expect(h.streak, 1);
      s.toggle(h);
      expect(s.doneToday(h), false);
      expect(s.totalXp, 0);
      expect(h.streak, 0);
    });

    test('victory score is 40 for all habits done', () {
      final s = AppState();
      s.addHabit('A', 'common');
      s.addHabit('B', 'common');
      s.toggle(s.habits[0]);
      s.toggle(s.habits[1]);
      expect(s.victory().habits, 40);
      expect(s.victory().score, inInclusiveRange(40, 100));
    });

    test('prestige gates at level 10 and rebirths', () {
      final s = AppState();
      expect(s.canPrestige, false);
      var xp = 0;
      for (var i = 1; i < 10; i++) {
        xp += xpForLevel(i);
      }
      s.totalXp = xp;
      expect(s.level, 10);
      expect(s.canPrestige, true);
      s.doPrestige();
      expect(s.totalXp, 0);
      expect(s.level, 1);
      expect(s.prestige, 1);
    });

    test('prestige reverts a now-locked companion to the default', () {
      final s = AppState();
      var xp = 0;
      for (var i = 1; i < 10; i++) {
        xp += xpForLevel(i);
      }
      s.totalXp = xp; // level 10
      expect(s.companionUnlocked('lynx'), isTrue); // unlocks at level 10
      s.setCompanion('lynx');
      s.doPrestige(); // back to level 1 → lynx re-locks
      expect(s.activeCompanion, 'drone');
    });

    test('earned achievements persist through prestige', () {
      final s = AppState();
      var xp = 0;
      for (var i = 1; i < 10; i++) {
        xp += xpForLevel(i);
      }
      s.totalXp = xp; // level 10
      s.addHabit('Test', 'common'); // _afterAction records level-based awards
      final lvl5 = kAchievements.firstWhere((a) => a.id == 'lvl5');
      expect(s.isAchievementEarned(lvl5), isTrue);
      s.doPrestige(); // back to level 1
      expect(lvl5.unlocked(s), isFalse); // live condition no longer met
      expect(s.isAchievementEarned(lvl5), isTrue); // but it stays earned
    });

    test('consumeNewAchievements returns freshly-earned awards then clears', () {
      final s = AppState();
      s.addHabit('Run', 'common');
      s.toggle(s.habits.single); // first completion unlocks "First Step"
      final earned = s.consumeNewAchievements();
      expect(earned.any((a) => a.id == 'first'), isTrue);
      expect(s.consumeNewAchievements(), isEmpty); // queue cleared
    });

    test('nutrition score is 0 on a fresh day, even with a body profile', () {
      final s = AppState();
      expect(s.nutritionScore(), 0);
      // Onboarding sets a body profile (targets) — still 0 until food is logged.
      s.setBodyProfile(BodyProfile(
          weight: 70,
          height: 175,
          age: 25,
          gender: 'male',
          activity: 'moderate',
          goal: 'maintain'));
      expect(s.nutritionScore(), 0);
    });

    test('shop: xp booster + streak shield cost coins', () {
      final s = AppState();
      s.coins = 300;
      expect(s.buyXpBoost(), true);
      expect(s.coins, 150);
      expect(s.xpBoostActive, true);
      expect(s.buyXpBoost(), false); // already active
      expect(s.buyStreakShield(), true);
      expect(s.coins, 50);
      expect(s.streakShields, 1);
      expect(s.buyStreakShield(), false); // 50 < 100
    });

    test('streak shield bridges a missed day', () {
      final s = AppState();
      s.addHabit('Run', 'common');
      final h = s.habits.first;
      // Pretend it was completed 3 days ago (a gap), with a shield owned.
      h.streak = 4;
      h.lastCompletedDate =
          dateKey(DateTime.now().subtract(const Duration(days: 3)));
      s.streakShields = 1;
      s.toggle(h); // check in today across the gap
      expect(h.streak, 5); // continued, not reset to 1
      expect(s.streakShields, 0); // shield consumed
    });

    // Monday of this week, plus [days].
    DateTime thisWeek(int days) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day - (now.weekday - 1) + days);
    }

    test('perfectDaysThisWeek counts Monday to Sunday, not a rolling 7 days', () {
      final s = AppState();
      for (var i = 1; i <= 4; i++) {
        s.perfectDays.add(dateKey(thisWeek(-i))); // last week
      }
      expect(s.perfectDaysThisWeek(), 0);
      s.perfectDays.add(dateKey(thisWeek(0))); // this Monday
      expect(s.perfectDaysThisWeek(), 1);
    });

    test('last week\'s perfect days do not defeat this week\'s boss', () {
      final s = AppState();
      s.addHabit('Read', 'common');
      for (var i = 1; i <= 4; i++) {
        s.perfectDays.add(dateKey(thisWeek(-i)));
      }
      for (final h in s.habits) {
        if (!s.doneToday(h)) s.toggle(h);
      }
      expect(s.totalBossDefeats, 0);
      expect(s.pendingBossDefeat, isFalse);
    });

    test('the boss pays once a week, even if a perfect day is undone', () {
      final s = AppState();
      s.addHabit('Read', 'common');
      final today = dateKey(DateTime.now());
      // Four other perfect days this week (dates ahead count too, so the
      // test works on any weekday), then make today the fifth.
      for (var i = 0, n = 0; i < 7 && n < 4; i++) {
        final k = dateKey(thisWeek(i));
        if (k != today) {
          s.perfectDays.add(k);
          n++;
        }
      }
      for (final h in s.habits) {
        if (!s.doneToday(h)) s.toggle(h);
      }
      expect(s.totalBossDefeats, 1);
      expect(s.bossDefeatedThisWeek, isTrue);
      final coins = s.coins;
      s.toggle(s.habits.first); // undo: today isn't perfect any more
      s.toggle(s.habits.first); // redo
      expect(s.totalBossDefeats, 1);
      expect(s.coins, lessThan(coins + kBossCoins)); // no second payout
    });

    test('an older save\'s boss flag counts as paid this week', () async {
      SharedPreferences.setMockInitialValues({
        'habitrail.meta.v2': '{"bossRewarded": true}',
      });
      final s = AppState();
      await s.load();
      expect(s.bossDefeatedThisWeek, isTrue);
    });

    test('nutrition targets fall back to defaults without a profile', () {
      final s = AppState();
      expect(s.bodyProfile, isNull);
      expect(s.targets().calories, kTargetCalories);
      s.setBodyProfile(BodyProfile(
          weight: 70,
          height: 175,
          age: 28,
          gender: 'female',
          activity: 'light',
          goal: 'maintain'));
      expect(s.targets().calories, computeTDEE(s.bodyProfile!));
    });
  });
}
