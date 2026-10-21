import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/core.dart';

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
