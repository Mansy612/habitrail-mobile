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

    test('perfectDaysThisWeek counts the last 7 days', () {
      final s = AppState();
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        s.perfectDays.add(dateKey(now.subtract(Duration(days: i))));
      }
      expect(s.perfectDaysThisWeek(), 5);
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
