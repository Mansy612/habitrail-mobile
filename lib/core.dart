import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ui/hr_tokens.dart';

// ── Habitrail night-sky palette shared by core and the mobile theme ──────────
const kBase = Color(0xFF0A0B12);
const kElevated = Color(0xEE181C2E); // raised navy surface
const kCard = Color(0xEE121624); // navy glass card surface
const kSurfacePrimary = Color(0xFF0D1018);
const kBorder = Color(0xFF22263F); // quiet navy-lavender edge
// Accent trio — mutable so appearance themes can swap them at runtime.
Color kPlasma = const Color(0xFF8D4BFF);
Color kPlasmaBright = const Color(0xFFB07CFF);
Color kPlasmaGlow = const Color(0xFFD2B3FF);
const kCyan = Color(0xFF62D5FF);
const kGold = Color(0xFFFFD43B);
const kBlue = Color(0xFF4F7CFF);
const kGreen = Color(0xFF34D399);
const kRed = Color(0xFFFB7185);
const kTextPrimary = Color(0xFFF4F1FB);
const kTextSecondary = Color(0x9EF4F1FB);
const kTextTertiary = Color(0x73F4F1FB);

// ── Appearance themes — swap the accent trio ────────────────────────────────
class AppThemeDef {
  const AppThemeDef(this.id, this.name, this.accent, this.bright, this.glow);
  final String id;
  final String name;
  final Color accent;
  final Color bright;
  final Color glow;
}

const List<AppThemeDef> kThemes = [
  AppThemeDef('violet', 'Habitrail Violet', Color(0xFF8D4BFF), Color(0xFFB07CFF),
      Color(0xFFD2B3FF)),
  AppThemeDef('tokyo', 'Neon Tokyo', Color(0xFFF472B6), Color(0xFFF9A8D4),
      Color(0xFFFBCFE8)),
  AppThemeDef('matrix', 'Matrix', Color(0xFF34D399), Color(0xFF6EE7B7),
      Color(0xFFA7F3D0)),
  AppThemeDef('solar', 'Solar Gold', Color(0xFFFBBF24), Color(0xFFFCD34D),
      Color(0xFFFDE68A)),
  AppThemeDef('crimson', 'Crimson', Color(0xFFFB7185), Color(0xFFFDA4AF),
      Color(0xFFFECDD3)),
  AppThemeDef('arctic', 'Arctic', Color(0xFF22D3EE), Color(0xFF67E8F9),
      Color(0xFFA5F0FC)),
  // Exclusive premium accent — only selectable while Habitrail Premium is active.
  AppThemeDef('nebula', 'Nebula', Color(0xFFE056FD), Color(0xFFEA80FC),
      Color(0xFFF3B0FF)),
];

AppThemeDef themeById(String id) =>
    kThemes.firstWhere((t) => t.id == id, orElse: () => kThemes.first);

void applyThemeColors(String id) {
  final t = themeById(id);
  kPlasma = t.accent;
  kPlasmaBright = t.bright;
  kPlasmaGlow = t.glow;
  hrApplyAccent(id); // keep the new HrColors.accent in sync during migration
}

// ── Cosmetics: profile-picture borders (bought in the Shop) ─────────────────
class BorderDef {
  const BorderDef(this.id, this.name, this.cost, this.colors,
      {this.glow = false, this.frameAsset});
  final String id;
  final String name;
  final int cost;
  final List<Color> colors; // 1 color = solid ring, 2+ = gradient
  final bool glow;
  final String? frameAsset;
}

const List<BorderDef> kBorders = [
  BorderDef('none', 'Simple', 0, [Color(0x4DFFFFFF)],
      frameAsset: 'assets/profile_borders/graphite.png'),
  BorderDef('cyan', 'Cyan Pulse', 120, [Color(0xFF3DE7FF)],
      glow: true, frameAsset: 'assets/profile_borders/cyan.png'),
  BorderDef('gold', 'Gold', 180, [Color(0xFFFFD23F)],
      glow: true, frameAsset: 'assets/profile_borders/gold.png'),
  BorderDef('violet', 'Violet', 180, [Color(0xFFC08BFF)],
      glow: true, frameAsset: 'assets/profile_borders/violet.png'),
  BorderDef('crimson', 'Crimson', 220, [Color(0xFFFF6B8A)],
      glow: true, frameAsset: 'assets/profile_borders/crimson.png'),
  BorderDef('aurora', 'Aurora', 400,
      [Color(0xFF3DE7FF), Color(0xFFB06BFF), Color(0xFFFF7AD1)],
      glow: true, frameAsset: 'assets/profile_borders/aurora.png'),
  BorderDef('prism', 'Prismatic', 700, [
    Color(0xFFFF6B8A),
    Color(0xFFFFD23F),
    Color(0xFF4ADE80),
    Color(0xFF3DE7FF),
    Color(0xFFB06BFF)
  ], glow: true, frameAsset: 'assets/profile_borders/prism.png'),
];

BorderDef borderById(String id) =>
    kBorders.firstWhere((b) => b.id == id, orElse: () => kBorders.first);

// Theme prices (violet is free). Bought in the Shop, applied in Appearance.
const Map<String, int> kThemeCost = {
  'violet': 0, 'tokyo': 200, 'matrix': 200,
  'solar': 250, 'crimson': 250, 'arctic': 300,
};
int themeCost(String id) => kThemeCost[id] ?? 200;

// ── Progression — ported 1:1 from lib/progression.ts ────────────────────────
const Map<int, String> kLevelTitles = {
  1: 'Initiate', 5: 'Acolyte', 10: 'Seeker', 15: 'Operator', 20: 'Specialist',
  25: 'Elite', 30: 'Hunter', 40: 'Phantom', 50: 'Sovereign', 60: 'Warlord',
  75: 'Transcendent', 90: 'Ascendant', 100: 'God-Tier',
};

String levelTitle(int level) {
  final ms = kLevelTitles.keys.toList()..sort((a, b) => b - a);
  for (final m in ms) {
    if (level >= m) return kLevelTitles[m]!;
  }
  return 'Initiate';
}

int xpForLevel(int level) => (100 * pow(1.15, level - 1)).floor();

({int level, int currentXp, int requiredXp, double progress}) levelFromXp(
    int totalXp) {
  int level = 1;
  int remaining = totalXp;
  while (remaining >= xpForLevel(level) && level < 1000) {
    remaining -= xpForLevel(level);
    level++;
  }
  final req = xpForLevel(level);
  return (
    level: level,
    currentXp: remaining,
    requiredXp: req,
    progress: remaining / req
  );
}

const Map<String, ({String label, Color color, double mult})> rarityConfig = {
  'common': (label: 'Common', color: Color(0xFF9CA3AF), mult: 1.0),
  'rare': (label: 'Rare', color: Color(0xFF3B82F6), mult: 1.5),
  'epic': (label: 'Epic', color: Color(0xFFA855F7), mult: 2.0),
  'legendary': (label: 'Legendary', color: Color(0xFFFFD700), mult: 3.0),
  'mythic': (label: 'Mythic', color: Color(0xFFFF00AA), mult: 5.0),
};

int calculateXpGain(int baseXp, String rarity, int streakDays, double combo) {
  final rarityMult = rarityConfig[rarity]?.mult ?? 1.0;
  final streakBonus = streakDays >= 30
      ? 2.0
      : streakDays >= 15
          ? 1.5
          : streakDays >= 8
              ? 1.25
              : streakDays >= 4
                  ? 1.1
                  : 1.0;
  return (baseXp * rarityMult * streakBonus * combo * 0.2).floor();
}

double comboMultiplier(int consecutive) {
  if (consecutive >= 10) return 3.0;
  if (consecutive >= 7) return 2.5;
  if (consecutive >= 5) return 2.0;
  if (consecutive >= 3) return 1.5;
  if (consecutive >= 2) return 1.25;
  return 1.0;
}

/// Deterministically infers a habit's difficulty (→ rarity → XP) from its name.
/// Harder/effortful habits earn more; easy ones earn the base amount.
String inferRarity(String name) {
  final n = name.toLowerCase();
  const legendary = [
    'marathon', 'fasting', 'cold shower', 'cold plunge', '5am', 'no sugar',
    'no alcohol', 'quit ', 'deep work', 'wake up early', 'sober'
  ];
  const epic = [
    'workout', 'exercise', 'gym', 'run', 'lift', 'train', 'study', 'code',
    'coding', 'practice', 'meditat', 'write', 'swim', 'yoga', 'hiit',
    'push-up', 'pushup', 'cardio'
  ];
  const rare = [
    'read', 'walk', 'journal', 'stretch', 'plan', 'review', 'language',
    'steps', 'meal prep', 'cook', 'clean', 'tidy'
  ];
  for (final k in legendary) {
    if (n.contains(k)) return 'legendary';
  }
  for (final k in epic) {
    if (n.contains(k)) return 'epic';
  }
  for (final k in rare) {
    if (n.contains(k)) return 'rare';
  }
  // A larger number in the name implies more effort (e.g. "Run 10km", "Read 50 pages").
  final mt = RegExp(r'(\d+)').firstMatch(n);
  if (mt != null) {
    final v = int.tryParse(mt.group(1) ?? '') ?? 0;
    if (v >= 45) return 'epic';
    if (v >= 20) return 'rare';
  }
  return 'common';
}

/// Rough XP for one completion at this difficulty (no streak/combo yet).
int estimatedXp(String rarity) =>
    (100 * (rarityConfig[rarity]?.mult ?? 1.0) * 0.2).floor();

// ── AI difficulty rating (Ollama) defaults — see lib/ai.dart ────────────────
const String kDefaultAiBaseUrl = 'http://localhost:11434';
const String kDefaultAiModel = 'llama3.2';

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The dateKey of the Monday that starts [d]'s calendar week.
String weekKey(DateTime d) =>
    dateKey(DateTime(d.year, d.month, d.day - (d.weekday - 1)));

// ── Victory Score labels/colors (lib/engine/victoryScore.ts) ────────────────
String victoryLabel(int score) {
  if (score >= 90) return 'Elite Day';
  if (score >= 75) return 'Strong Day';
  if (score >= 60) return 'Good Day';
  if (score >= 50) return 'Average Day';
  return 'Recovery Day';
}

Color victoryColor(int score) {
  if (score >= 90) return const Color(0xFFA855F7);
  if (score >= 75) return const Color(0xFF00FF88);
  if (score >= 60) return const Color(0xFFFFD700);
  if (score >= 50) return const Color(0xFFF97316);
  return const Color(0xFFEF4444);
}

// ── Nutrition targets (web derives these from TDEE/body profile; mobile uses
//    sensible defaults until the body-profile/TDEE layer is ported). ─────────
const double kTargetCalories = 2200;
const double kTargetProtein = 150;
const double kTargetCarbs = 220;
const double kTargetFat = 70;

// ── Models ──────────────────────────────────────────────────────────────────
// ── Tasks: Dailies & To-Dos ─────────────────────────────────────────────────
// A lighter companion to Habits (which stay the tuned streak/XP engine).
// Dailies are scheduled recurring tasks; To-Dos are one-off. Small flat rewards
// keep the progression economy stable and deterministic.
enum TaskKind { daily, todo }

const int kDailyXp = 8;
const int kDailyCoins = 2;
const int kTodoXp = 12;
const int kTodoCoins = 3;

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    this.kind = TaskKind.todo,
    this.icon = '',
    List<int>? weekdays,
    this.dueDate,
    this.lastDoneDate,
    this.done = false,
  }) : weekdays = weekdays ?? const [];

  final String id;
  String title;
  TaskKind kind;
  String icon;
  List<int> weekdays; // dailies: 1=Mon..7=Sun; empty = every day
  String? dueDate; // todos: optional 'YYYY-MM-DD'
  String? lastDoneDate; // dailies: dateKey last completed
  bool done; // todos: completed

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'kind': kind.name,
        'icon': icon,
        'weekdays': weekdays,
        'dueDate': dueDate,
        'lastDoneDate': lastDoneDate,
        'done': done,
      };

  factory TaskItem.fromMap(Map<String, dynamic> m) => TaskItem(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        kind:
            (m['kind'] as String?) == 'daily' ? TaskKind.daily : TaskKind.todo,
        icon: (m['icon'] as String?) ?? '',
        weekdays: ((m['weekdays'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        dueDate: m['dueDate'] as String?,
        lastDoneDate: m['lastDoneDate'] as String?,
        done: (m['done'] as bool?) ?? false,
      );
}

class Habit {
  Habit({
    required this.id,
    required this.name,
    this.rarity = 'common',
    this.baseXp = 100,
    this.streak = 0,
    this.lastCompletedDate,
    this.todayAwardXp = 0,
    this.icon = '',
    this.aiRated = false,
    this.difficultyReason = '',
    this.reminderMinutes,
  });

  final String id;
  String name;
  String rarity;
  int baseXp;
  int streak;
  String? lastCompletedDate;
  int todayAwardXp;
  String icon;
  bool aiRated; // true = an AI model picked this difficulty
  String difficultyReason; // short "why this difficulty" shown in the UI
  int? reminderMinutes; // daily reminder, minutes since midnight; null = off

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'rarity': rarity,
        'baseXp': baseXp,
        'streak': streak,
        'lastCompletedDate': lastCompletedDate,
        'todayAwardXp': todayAwardXp,
        'icon': icon,
        'aiRated': aiRated,
        'difficultyReason': difficultyReason,
        'reminderMinutes': reminderMinutes,
      };

  factory Habit.fromMap(Map<String, dynamic> m) => Habit(
        id: m['id'] as String,
        name: m['name'] as String,
        rarity: (m['rarity'] as String?) ?? 'common',
        baseXp: (m['baseXp'] as int?) ?? 100,
        streak: (m['streak'] as int?) ?? 0,
        lastCompletedDate: m['lastCompletedDate'] as String?,
        todayAwardXp: (m['todayAwardXp'] as int?) ?? 0,
        icon: (m['icon'] as String?) ?? '',
        aiRated: (m['aiRated'] as bool?) ?? false,
        difficultyReason: (m['difficultyReason'] as String?) ?? '',
        reminderMinutes: m['reminderMinutes'] as int?,
      );
}

class Reflection {
  Reflection({
    required this.date,
    required this.text,
    this.day = 0,
    this.energy = 0,
    this.mood = 0,
    this.focus = 0,
  });
  final String date;
  final String text;
  final int day; // 1–10 "how was your day" (0 = not rated)
  final int energy; // 1–10
  final int mood; // 1–10
  final int focus; // 1–10
  Map<String, dynamic> toMap() => {
        'date': date,
        'text': text,
        'day': day,
        'energy': energy,
        'mood': mood,
        'focus': focus,
      };
  factory Reflection.fromMap(Map<String, dynamic> m) => Reflection(
        date: m['date'] as String,
        text: m['text'] as String,
        day: (m['day'] as int?) ?? 0,
        energy: (m['energy'] as int?) ?? 0,
        mood: (m['mood'] as int?) ?? 0,
        focus: (m['focus'] as int?) ?? 0,
      );
}

class MilestoneEvent {
  MilestoneEvent({
    required this.type,
    required this.date,
    required this.level,
    required this.description,
    this.xp = 0,
  });
  final String type; // level_up | boss_defeat | prestige | season | streak
  final String date; // ISO timestamp
  final int level;
  final String description;
  final int xp;

  Map<String, dynamic> toMap() => {
        'type': type,
        'date': date,
        'level': level,
        'description': description,
        'xp': xp,
      };

  factory MilestoneEvent.fromMap(Map<String, dynamic> m) => MilestoneEvent(
        type: m['type'] as String,
        date: m['date'] as String,
        level: (m['level'] as int?) ?? 1,
        description: m['description'] as String,
        xp: (m['xp'] as int?) ?? 0,
      );
}

class FoodEntry {
  FoodEntry({
    required this.id,
    required this.name,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.date,
  });
  final String id;
  final String name;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final String date;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'calories': calories,
        'protein': protein,
        'carbs': carbs,
        'fat': fat,
        'date': date,
      };

  factory FoodEntry.fromMap(Map<String, dynamic> m) => FoodEntry(
        id: m['id'] as String,
        name: m['name'] as String,
        calories: (m['calories'] as num).toDouble(),
        protein: (m['protein'] as num).toDouble(),
        carbs: (m['carbs'] as num).toDouble(),
        fat: (m['fat'] as num).toDouble(),
        date: m['date'] as String,
      );
}

class BodyProfile {
  BodyProfile({
    required this.weight,
    required this.height,
    required this.age,
    required this.gender,
    required this.activity,
    required this.goal,
  });
  final double weight; // kg
  final double height; // cm
  final int age;
  final String gender; // 'male' | 'female'
  final String activity; // sedentary|light|moderate|active|very_active
  final String goal; // cut|maintain|bulk

  Map<String, dynamic> toMap() => {
        'weight': weight,
        'height': height,
        'age': age,
        'gender': gender,
        'activity': activity,
        'goal': goal,
      };

  factory BodyProfile.fromMap(Map<String, dynamic> m) => BodyProfile(
        weight: (m['weight'] as num).toDouble(),
        height: (m['height'] as num).toDouble(),
        age: m['age'] as int,
        gender: m['gender'] as String,
        activity: m['activity'] as String,
        goal: m['goal'] as String,
      );
}

const Map<String, double> kActivityMultipliers = {
  'sedentary': 1.2,
  'light': 1.375,
  'moderate': 1.55,
  'active': 1.725,
  'very_active': 1.9,
};

/// Mifflin-St Jeor BMR (ported from lib/nutrition/tdee.ts).
double computeBMR(BodyProfile p) => (10 * p.weight +
        6.25 * p.height -
        5 * p.age +
        (p.gender == 'male'
            ? 5
            : p.gender == 'female'
                ? -161
                : -78)) // 'other' → midpoint of the male/female constants
    .roundToDouble();

double computeTDEE(BodyProfile p) =>
    (computeBMR(p) * (kActivityMultipliers[p.activity] ?? 1.2)).roundToDouble();

({double calories, double protein, double carbs, double fat})
    computeMacroTargets(BodyProfile p) {
  final tdee = computeTDEE(p);
  final adjust = p.goal == 'cut'
      ? -500.0
      : p.goal == 'bulk'
          ? 500.0
          : 0.0;
  final calories = tdee + adjust;
  final pm = p.goal == 'cut'
      ? 2.2
      : p.goal == 'bulk'
          ? 1.7
          : 1.9;
  final protein = (p.weight * pm).roundToDouble();
  final fat = (calories * 0.25 / 9).roundToDouble();
  final carbs =
      (max(0.0, calories - protein * 4 - fat * 9) / 4).roundToDouble();
  return (calories: calories, protein: protein, carbs: carbs, fat: fat);
}

// ── Weekly boss (from lib/progression.ts WEEKLY_BOSS) ───────────────────────
const kBossTitle = 'Weekly Sovereignty Challenge';
const kBossDesc = 'Have 5 perfect days (all habits done) this week.';
const kBossGoal = 5;
const kBossXp = 1000;
const kBossCoins = 200;
const kBossImageAsset = 'assets/bosses/veil_regent.png';
const kPrestigeMinLevel = 10; // mobile threshold (web gates prestige higher)

// Freemium AI-coach allowance — a weekly number of coaching prompts that resets
// Monday. Free users get a taste; Premium raises the cap. (Tune against cost +
// engagement + upgrades.)
const int kFreeCoachLimit = 3;
const int kPremiumCoachLimit = 30;

// ── Habitrail Premium ───────────────────────────────────────────────────────
// Entitlement + a pluggable purchase scaffold. The upgrade activates instantly
// in-app today; real App Store / Play IAP can replace PurchaseController later
// without touching the feature gates. Prices are display-only until billing is
// wired, and match the approved plan ($7.99/mo, $59.99/yr — annual ~$5/mo).
const String kPremiumMonthlyPrice = r'$7.99';
const String kPremiumAnnualPrice = r'$59.99';
const String kPremiumAnnualPerMonth = r'$5';
const int kPremiumAnnualSavingsPct = 37;
const String kPremiumThemeId = 'nebula'; // exclusive premium accent theme
const int kPremiumStreakSavesPerMonth = 4; // premium streak-saves / rest days

// ── Guided challenges (premium) ─────────────────────────────────────────────
// Themed 7- or 30-day programs with a daily check-in. One active at a time.
class ChallengeDef {
  const ChallengeDef(
      this.id, this.title, this.blurb, this.days, this.icon, this.focus);
  final String id;
  final String title;
  final String blurb; // one-line pitch
  final int days; // 7 or 30
  final IconData icon;
  final String focus; // the daily check-in action
}

const List<ChallengeDef> kChallenges = [
  ChallengeDef('hydrate7', '7-Day Hydration Reset',
      'Build a water habit that sticks.', 7, Icons.water_drop_rounded,
      'Drink 8 glasses of water'),
  ChallengeDef('focus7', '7-Day Focus Sprint', 'One deep-work block a day.', 7,
      Icons.bolt_rounded, 'Do one 25-minute focus block'),
  ChallengeDef('move7', '7-Day Move Every Day', 'Get your body moving daily.', 7,
      Icons.directions_run_rounded, 'Move for 20+ minutes'),
  ChallengeDef('morning30', '30-Day Morning Routine',
      'Own your mornings for a month.', 30, Icons.wb_sunny_rounded,
      'Finish your morning routine'),
  ChallengeDef('mindful30', '30-Day Mindfulness',
      'A calmer mind, one day at a time.', 30, Icons.self_improvement_rounded,
      'Meditate for 10 minutes'),
  ChallengeDef('sleep30', '30-Day Sleep Better',
      'Earlier, screen-free nights for a month.', 30, Icons.bedtime_rounded,
      'No screens 30 min before bed'),
];

ChallengeDef challengeById(String id) =>
    kChallenges.firstWhere((c) => c.id == id, orElse: () => kChallenges.first);

/// Monday (as a dateKey) of the week containing [d] — the coach-allowance week.
String _mondayKey(DateTime d) {
  final monday =
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));
  return dateKey(monday);
}

String _monthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';

// ── Shared app state ─────────────────────────────────────────────────────────
/// Sentinel owner for an on-device save that exists but can't be attributed to
/// a signed-in account (e.g. a pre-stamping save found while signed out). It
/// equals no real uid, so the next sign-in treats it as "not mine" and starts
/// clean rather than adopting another account's data.
const kUnknownOwner = '\u0000unclaimed';

/// The single app-wide state instance, shared across main.dart and
/// purchases.dart. Lazily initialized on first access.
final appState = AppState();

class AppState extends ChangeNotifier {
  static const _habitsKey = 'habitrail.habits.v1';
  static const _metaKey = 'habitrail.meta.v2';
  static const _journalKey = 'habitrail.journal.v1';
  static const _foodKey = 'habitrail.food.v1';
  static const _milestoneKey = 'habitrail.milestones.v1';
  static const _tasksKey = 'habitrail.tasks.v1';
  // The account (Supabase uid) the on-device save belongs to. Kept in its OWN
  // key, deliberately NOT part of exportSave()/importSave(), so a cloud backup
  // never carries an owner id that would re-stamp whoever restores it.
  static const _ownerKey = 'habitrail.owner.v1';

  final List<Habit> habits = [];
  final List<Reflection> reflections = [];
  final List<FoodEntry> foodLog = [];
  final List<TaskItem> tasks = []; // Dailies & To-Dos (separate from habits)
  int totalXp = 0;
  int coins = 100;
  bool loading = true;

  // Economy layer
  int focusMinutesToday = 0;
  String focusDateKey = '';
  // Focus session (deadline-based). Remaining time is derived from a wall-clock
  // deadline, so it stays accurate across backgrounding, lock and restart — it
  // is never counted down a second per tick. Persisted, so a kill mid-session
  // can resume or complete it. Mode is cosmetic.
  bool focusSessionActive = false;
  int focusSessionMinutes = 0; // target length of the running/paused session
  String focusSessionDeadline = ''; // ISO8601 end while RUNNING; '' while PAUSED
  int focusSessionPausedRemaining = 0; // seconds left while PAUSED
  int focusSessionMode = 0; // selected focus-mode index (cosmetic)
  // Injectable clock so tests can simulate time passing / backgrounding.
  @visibleForTesting
  DateTime Function() focusNow = DateTime.now;
  final Set<String> perfectDays = {};
  String bossRewardedWeek = ''; // Monday dateKey of the week the boss paid out
  bool pendingBossDefeat = false;
  final Set<String> questClaimedIds = {};
  String questDateKey = '';

  // Companion
  String activeCompanion = 'drone';
  String lastCompanionLine = '';

  // Prestige & seasons
  int prestige = 0;
  int currentSeason = 0;
  int seasonBossDefeats = 0;
  bool pendingPrestige = false;
  bool pendingSeasonIntro = false;

  BodyProfile? bodyProfile;

  final List<MilestoneEvent> milestoneLog = [];
  final Set<String> earnedAchievements = {}; // persist once earned (survives prestige)
  final Set<String> claimedQuests = {}; // co-op quest rewards already claimed
  final Set<String> blockedUsers = {}; // chat user ids this device has blocked
  int totalBossDefeats = 0;
  int highestLevel = 1;
  int evolvedStage = 0; // highest companion stage celebrated (prestige resets)
  int _prevLevel = 1;
  String displayName = 'Player';
  String lastBackupAt = ''; // ISO8601 of the last successful cloud backup
  // Which account this device's save belongs to: '' = unclaimed/pristine,
  // [kUnknownOwner] = present but unattributed, otherwise a signed-in uid.
  // Enforced on sign-in (adoptOwner) and on every cloud upload so one account's
  // habits/journal/nutrition/purchases/progress can never show up as — or
  // overwrite — another account's.
  String saveOwnerId = '';
  String lastBriefingDate = '';
  String themeId = 'violet';
  final Map<String, int> dailyScore = {}; // dateKey -> victory score
  // Per-day activity behind the Progress charts (dateKey -> amount).
  final Map<String, int> dailyXp = {};
  final Map<String, int> dailyFocus = {}; // focus minutes
  final Map<String, int> dailyDone = {}; // habits + tasks completed
  int streakShields = 0;
  String? xpBoostDate; // 2x XP active while this == today
  // AI difficulty rating (local Ollama) — see lib/ai.dart.
  bool aiEnabled = true;
  String aiBaseUrl = kDefaultAiBaseUrl;
  String aiModel = kDefaultAiModel;
  // Phone notifications, planned by planNotifications() and scheduled by
  // lib/notifications.dart. Settings, not progress, so a reset keeps them.
  bool remindersOn = true; // each habit's reminder time as a notification
  bool streakAlertOn = true; // heads-up before an open streak breaks
  int streakAlertMinutes = 20 * 60; // minutes since midnight
  bool notifAsked = false; // the OS permission prompt has been shown
  bool notifOffered = false; // the in-app "turn on reminders" offer was shown
  // Premium + AI-coach quota (freemium). The device's own entitlement is a
  // VERIFIED store subscription, represented by an expiry — never a permanent
  // flag — so access lapses on its own at period end and can be cleared on
  // refund/revocation. Coach usage counts against a weekly allowance.
  String premiumExpiresAt = ''; // ISO8601 end of the paid period; '' = none
  String premiumVerifiedAt = ''; // ISO8601 of the last store-verified update
  // Admin Premium override from the server (lib/admin.dart): 'grant' / 'revoke'
  // win over the device entitlement; '' = no override. Belongs to the account.
  String premiumOverride = '';
  /// The device's own entitlement: a store subscription period that has not
  /// lapsed. A saved flag is never trusted on its own — the expiry decides, so
  /// expiration and (server-cleared) refund/revocation take effect here.
  bool get storeEntitlementActive {
    final d = DateTime.tryParse(premiumExpiresAt);
    return d != null && DateTime.now().isBefore(d);
  }
  bool get isPremium =>
      premiumOverride == 'grant' ||
      (premiumOverride != 'revoke' && storeEntitlementActive);
  // Server coin-adjustment ids applied here but not yet acknowledged, so a
  // failed acknowledgement can never apply the same adjustment twice.
  final Set<String> appliedCoinGrants = {};
  int coachUsesThisWeek = 0;
  String coachWeekKey = ''; // Monday dateKey the current count belongs to
  // Premium entitlement. isPremium is the gate; plan/since drive the manage
  // screen. Survives a progress reset (an entitlement, not progress).
  String premiumPlan = 'none'; // 'none' | 'monthly' | 'annual'
  String premiumSince = ''; // dateKey Premium was first activated
  // Weekly AI Coach Report (premium): cached text + the Monday it covers, so it
  // is generated at most once per week.
  String weeklyReportText = '';
  String weeklyReportWeekKey = '';
  // Weekly AI Plan (premium): forward-looking plan, cached per week.
  String weeklyPlanText = '';
  String weeklyPlanWeekKey = '';
  // Guided challenges (premium): one active program at a time.
  String activeChallengeId = '';
  String challengeStartDate = ''; // dateKey of the start day
  final Set<String> challengeCheckIns = {}; // dateKeys the user checked in
  final Set<String> completedChallenges = {}; // finished challenge ids
  // Premium companion cosmetics (purely visual, no gameplay effect).
  String companionSkin = 'classic';
  String companionAccessory = 'none';
  // Cosmetic class/identity — flavor only, free for all, no XP/coin/difficulty effect.
  String playerClass = 'wanderer';
  // Premium streak recovery: a monthly allowance covering both auto streak-saves
  // (when a missed day would break a streak) and planned rest days.
  int premiumSavesUsed = 0;
  String premiumSaveMonth = ''; // 'YYYY-MM' the count belongs to
  final Set<String> restDays = {}; // dateKeys marked as planned rest days
  // Profile / cosmetics
  String pfpBase64 = ''; // downscaled JPEG as base64; '' = show the initial
  Uint8List? pfpBytes; // decoded cache for display
  String selectedBorder = 'none';
  final Set<String> ownedBorders = {'none'};
  final Set<String> ownedThemes = {'violet'};

  int get level => levelFromXp(totalXp).level;
  bool get xpBoostActive => xpBoostDate == dateKey(DateTime.now());
  bool doneToday(Habit h) => h.lastCompletedDate == dateKey(DateTime.now());
  int get doneTodayCount => habits.where(doneToday).length;

  /// XP a habit awards if checked off now (shown on its quest chip); the
  /// awarded amount once it's done. Mirrors toggle()'s formula, minus the
  /// rare rest-day/shield streak bridge.
  int projectedXp(Habit h) {
    if (doneToday(h)) return h.todayAwardXp;
    final yesterday = dateKey(DateTime.now().subtract(const Duration(days: 1)));
    final nextStreak = h.lastCompletedDate == yesterday ? h.streak + 1 : 1;
    var gain = calculateXpGain(
        h.baseXp, h.rarity, nextStreak, comboMultiplier(doneTodayCount));
    gain = (gain * (1 + 0.05 * prestige)).round();
    if (xpBoostActive) gain *= 2;
    return gain;
  }

  int get bestStreak =>
      habits.isEmpty ? 0 : habits.map((h) => h.streak).reduce(max);
  int get totalPerfectDays => perfectDays.length;

  /// Days this user checked in (finished at least one habit or task), which
  /// is what keeps a buddy streak going.
  Set<String> get activeDays =>
      {for (final e in dailyDone.entries) if (e.value > 0) e.key};

  /// Average Victory Score over the last [n] recorded days (0 when none yet).
  double avgScoreLastDays(int n) {
    if (dailyScore.isEmpty) return 0;
    final keys = dailyScore.keys.toList()..sort();
    final recent = keys.length <= n ? keys : keys.sublist(keys.length - n);
    if (recent.isEmpty) return 0;
    final sum = recent.fold<int>(0, (a, k) => a + (dailyScore[k] ?? 0));
    return sum / recent.length;
  }

  int _idSeq = 0;
  // Counter-suffixed so ids stay unique even when several are created in the
  // same microsecond (e.g. seeding habits) — needed for stable widget keys.
  String newId() => '${DateTime.now().microsecondsSinceEpoch}-${_idSeq++}';

  /// The default habits every new account / fresh install starts with.
  List<Habit> _seedHabits() => [
        Habit(id: newId(), name: 'Drink water', icon: '💧'),
        Habit(id: newId(), name: 'Read 10 pages', rarity: 'rare', icon: '📖'),
        Habit(id: newId(), name: 'Exercise', rarity: 'epic', icon: '🏋️'),
        Habit(id: newId(), name: 'Sleep 7h+', icon: '😴'),
        Habit(id: newId(), name: 'Meditate 10 min', rarity: 'epic', icon: '🧘'),
        Habit(id: newId(), name: 'Walk 30 min', rarity: 'rare', icon: '🚶'),
        Habit(id: newId(), name: 'Stretch', icon: '🤸'),
        Habit(id: newId(), name: 'Journal', rarity: 'rare', icon: '✍️'),
        Habit(id: newId(), name: 'Healthy meal', rarity: 'rare', icon: '🥗'),
      ];

  // Starter habits grouped by onboarding focus area.
  static const Map<String, List<(String, String, String)>> _areaHabits = {
    'fitness': [
      ('Exercise', '🏋️', 'epic'),
      ('Walk 30 min', '🚶', 'rare'),
      ('Stretch', '🤸', 'common'),
    ],
    'nutrition': [
      ('Drink water', '💧', 'common'),
      ('Healthy meal', '🥗', 'rare'),
      ('Log nutrition', '🍎', 'common'),
    ],
    'mind': [
      ('Meditate 10 min', '🧘', 'epic'),
      ('Journal', '✍️', 'rare'),
      ('Gratitude note', '🙏', 'common'),
    ],
    'sleep': [
      ('Sleep 7h+', '😴', 'common'),
      ('No screens before bed', '📵', 'rare'),
    ],
    'learning': [
      ('Read 10 pages', '📖', 'rare'),
      ('Learn something new', '🧠', 'rare'),
    ],
    'productivity': [
      ('Plan my day', '🗂️', 'common'),
      ('Deep work 1h', '💻', 'epic'),
    ],
  };

  /// Replaces the starter habits with ones matching the chosen focus areas
  /// (onboarding). Keeps the default seed when no area is chosen.
  void seedHabitsForAreas(Set<String> areas) {
    final defs = <(String, String, String)>[];
    for (final a in areas) {
      defs.addAll(_areaHabits[a] ?? const []);
    }
    if (defs.isEmpty) return;
    final seen = <String>{};
    final out = <Habit>[];
    for (final d in defs) {
      if (seen.add(d.$1) && out.length < 9) {
        out.add(Habit(id: newId(), name: d.$1, icon: d.$2, rarity: d.$3));
      }
    }
    habits
      ..clear()
      ..addAll(out);
    notifyListeners();
    _save();
  }

  bool _sleepDoneToday() =>
      habits.any((h) => h.name.toLowerCase().contains('sleep') && doneToday(h));

  /// Daily macro targets — from the body profile (TDEE) or defaults.
  ({double calories, double protein, double carbs, double fat}) targets() {
    final p = bodyProfile;
    if (p == null) {
      return (
        calories: kTargetCalories,
        protein: kTargetProtein,
        carbs: kTargetCarbs,
        fat: kTargetFat
      );
    }
    return computeMacroTargets(p);
  }

  void setBodyProfile(BodyProfile p) {
    bodyProfile = p;
    notifyListeners();
    _save();
  }

  void setDisplayName(String name) {
    displayName = name;
    notifyListeners();
    _save();
  }

  bool get needsBriefing => lastBriefingDate != dateKey(DateTime.now());

  void markBriefingSeen() {
    lastBriefingDate = dateKey(DateTime.now());
    notifyListeners();
    _save();
  }

  void setTheme(String id) {
    if (!canUseTheme(id)) return; // must own it (Shop) or be Premium (exclusive)
    themeId = id;
    applyThemeColors(id);
    notifyListeners();
    _save();
  }

  void setPfp(String base64) {
    pfpBase64 = base64;
    try {
      pfpBytes = base64.isEmpty ? null : base64Decode(base64);
    } catch (_) {
      pfpBytes = null;
      pfpBase64 = '';
    }
    notifyListeners();
    _save();
  }

  bool ownsTheme(String id) => ownedThemes.contains(id);
  bool ownsBorder(String id) => ownedBorders.contains(id);

  bool buyTheme(String id) {
    if (ownedThemes.contains(id)) return true;
    final c = themeCost(id);
    if (coins < c) return false;
    coins -= c;
    ownedThemes.add(id);
    notifyListeners();
    _save();
    return true;
  }

  bool buyBorder(String id) {
    if (ownedBorders.contains(id)) return true;
    final c = borderById(id).cost;
    if (coins < c) return false;
    coins -= c;
    ownedBorders.add(id);
    notifyListeners();
    _save();
    return true;
  }

  void setBorder(String id) {
    if (!ownedBorders.contains(id)) return;
    selectedBorder = id;
    notifyListeners();
    _save();
  }

  void setAiConfig({bool? enabled, String? baseUrl, String? model}) {
    if (enabled != null) aiEnabled = enabled;
    if (baseUrl != null) aiBaseUrl = baseUrl.trim();
    if (model != null) aiModel = model.trim();
    notifyListeners();
    _save();
  }

  void setNotificationPrefs({
    bool? reminders,
    bool? streakAlert,
    int? streakAlertAt,
    bool? asked,
    bool? offered,
  }) {
    if (reminders != null) remindersOn = reminders;
    if (streakAlert != null) streakAlertOn = streakAlert;
    if (streakAlertAt != null) streakAlertMinutes = streakAlertAt;
    if (asked != null) notifAsked = asked;
    if (offered != null) notifOffered = offered;
    notifyListeners();
    _save();
  }

  bool buyXpBoost() {
    if (xpBoostActive || coins < 150) return false;
    coins -= 150;
    xpBoostDate = dateKey(DateTime.now());
    notifyListeners();
    _save();
    return true;
  }

  bool buyStreakShield() {
    if (coins < 100) return false;
    coins -= 100;
    streakShields += 1;
    notifyListeners();
    _save();
    return true;
  }

  // ── AI coach quota (freemium) ─────────────────────────────────────────────
  int get coachLimit => isPremium ? kPremiumCoachLimit : kFreeCoachLimit;
  int get _coachUsedThisWeek =>
      coachWeekKey == _mondayKey(DateTime.now()) ? coachUsesThisWeek : 0;
  int get coachUsesLeft => (coachLimit - _coachUsedThisWeek).clamp(0, coachLimit);
  bool get canUseCoach => coachUsesLeft > 0;

  /// Next Monday 00:00 — when the weekly allowance refills.
  DateTime get coachResetDate {
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    while (d.weekday != DateTime.monday) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  /// Spend one coaching prompt. Returns false (nothing spent) when the weekly
  /// allowance is used up, so the caller can show the upgrade prompt instead.
  bool consumeCoachUse() {
    final k = _mondayKey(DateTime.now());
    if (coachWeekKey != k) {
      coachWeekKey = k;
      coachUsesThisWeek = 0;
    }
    if (coachUsesThisWeek >= coachLimit) return false;
    coachUsesThisWeek++;
    notifyListeners();
    _save();
    return true;
  }

  // ── Premium entitlement ───────────────────────────────────────────────────
  /// Whether [id] can be applied: owned via the Shop, or the exclusive premium
  /// theme while Premium is active.
  bool canUseTheme(String id) =>
      ownedThemes.contains(id) || (isPremium && id == kPremiumThemeId);

  /// Activate Premium with the given plan ('monthly' | 'annual'). The purchase
  /// itself is handled by the caller's PurchaseController; this records the
  /// entitlement. Real IAP will call this on a verified purchase/restore.
  void activatePremium(String plan, {DateTime? expiresAt, bool verified = false}) {
    premiumPlan = plan == 'annual' ? 'annual' : 'monthly';
    premiumExpiresAt =
        (expiresAt ?? DateTime.now().add(_planPeriod(plan))).toIso8601String();
    if (verified) premiumVerifiedAt = DateTime.now().toIso8601String();
    if (premiumSince.isEmpty) premiumSince = dateKey(DateTime.now());
    notifyListeners();
    _save();
  }

  Duration _planPeriod(String plan) =>
      plan == 'annual' ? const Duration(days: 365) : const Duration(days: 30);

  /// A store-confirmed purchase / restore / renewal (from PurchaseController).
  /// [expiresAt] comes from a server receipt check when available; without it
  /// the plan's length from now is used and each renewal event extends it.
  void applyStoreEntitlement(String plan, {DateTime? expiresAt}) =>
      activatePremium(plan, expiresAt: expiresAt, verified: true);

  /// Server-authoritative entitlement, e.g. relayed from App Store Server
  /// Notifications by the backend: renewals extend it, and refund / revocation
  /// / expiry clear it. This is how a refund or revocation reaches the device.
  void applyServerEntitlement(
      {required bool active, String? plan, DateTime? expiresAt}) {
    if (!active) {
      cancelPremium();
      return;
    }
    activatePremium(plan ?? (premiumPlan == 'none' ? 'monthly' : premiumPlan),
        expiresAt: expiresAt, verified: true);
  }

  /// Drop the Premium entitlement (cancel / lapse). Falls back off the exclusive
  /// premium theme if it was active so the UI never shows a locked accent.
  void cancelPremium() {
    premiumPlan = 'none';
    premiumExpiresAt = '';
    premiumVerifiedAt = '';
    premiumSince = '';
    _dropLockedTheme();
    notifyListeners();
    _save();
  }

  void _dropLockedTheme() {
    if (!isPremium && themeId == kPremiumThemeId) {
      themeId = ownedThemes.contains('violet') ? 'violet' : ownedThemes.first;
      applyThemeColors(themeId);
    }
  }

  /// Re-evaluate the entitlement at launch. [isPremium] already reflects the
  /// expiry, so this only drops the exclusive premium theme if the entitlement
  /// has lapsed since the last run (e.g. the subscription expired while away).
  void reconcilePremium() {
    final before = themeId;
    _dropLockedTheme();
    if (themeId != before) {
      notifyListeners();
      _save();
    }
  }

  /// Apply the server's Premium override: 'grant', 'revoke', or anything else
  /// for none (the device's own entitlement decides).
  void setPremiumOverride(String state) {
    final s = (state == 'grant' || state == 'revoke') ? state : '';
    if (s == premiumOverride) return;
    premiumOverride = s;
    _dropLockedTheme();
    notifyListeners();
    _save();
  }

  /// Apply admin coin adjustments, each id once (the balance never goes below
  /// zero). Saved before returning, so the server can then be told they're
  /// done. Returns the net change applied.
  Future<int> applyCoinGrants(
      Iterable<({String id, int amount})> grants) async {
    var net = 0;
    var fresh = false;
    for (final g in grants) {
      if (!appliedCoinGrants.add(g.id)) continue; // already applied here
      fresh = true;
      net += g.amount;
    }
    if (!fresh) return 0;
    final before = coins;
    coins = max(0, coins + net);
    notifyListeners();
    await _save();
    return coins - before;
  }

  /// The server acknowledged these adjustments; stop remembering them.
  void forgetCoinGrants(Iterable<String> ids) {
    appliedCoinGrants.removeAll(ids);
    _save();
  }

  /// Debug / test helper (and the kDebugMode toggle): flip Premium on or off.
  void setPremium(bool v) => v ? activatePremium('annual') : cancelPremium();

  /// Cache the week's AI Coach Report so it is generated at most once per week.
  void saveWeeklyReport(String text) {
    weeklyReportText = text;
    weeklyReportWeekKey = _mondayKey(DateTime.now());
    notifyListeners();
    _save();
  }

  /// True when a report for the current week is already cached.
  bool get weeklyReportIsCurrent =>
      weeklyReportText.isNotEmpty &&
      weeklyReportWeekKey == _mondayKey(DateTime.now());

  /// Cache the week's AI plan so it is generated at most once per week.
  void saveWeeklyPlan(String text) {
    weeklyPlanText = text;
    weeklyPlanWeekKey = _mondayKey(DateTime.now());
    notifyListeners();
    _save();
  }

  bool get weeklyPlanIsCurrent =>
      weeklyPlanText.isNotEmpty &&
      weeklyPlanWeekKey == _mondayKey(DateTime.now());

  // ── Guided challenges ──────────────────────────────────────────────────────
  ChallengeDef? get activeChallenge =>
      activeChallengeId.isEmpty ? null : challengeById(activeChallengeId);
  int get challengeCheckInCount => challengeCheckIns.length;
  bool get challengeCheckedInToday =>
      challengeCheckIns.contains(dateKey(DateTime.now()));

  /// Check-ins completed / total days, 0..1.
  double get challengeProgress {
    final c = activeChallenge;
    if (c == null || c.days == 0) return 0;
    return (challengeCheckIns.length / c.days).clamp(0.0, 1.0);
  }

  void startChallenge(String id) {
    activeChallengeId = id;
    challengeStartDate = dateKey(DateTime.now());
    challengeCheckIns.clear();
    notifyListeners();
    _save();
  }

  void abandonChallenge() {
    activeChallengeId = '';
    challengeStartDate = '';
    challengeCheckIns.clear();
    notifyListeners();
    _save();
  }

  /// Record today's check-in (once per day). Returns true when this check-in
  /// completes the challenge — all days done — which awards a one-time coin
  /// bonus and clears the active slot.
  bool checkInChallenge() {
    final c = activeChallenge;
    if (c == null) return false;
    final today = dateKey(DateTime.now());
    if (challengeCheckIns.contains(today)) return false;
    challengeCheckIns.add(today);
    var completed = false;
    if (challengeCheckIns.length >= c.days) {
      completedChallenges.add(c.id);
      coins += 150;
      activeChallengeId = '';
      challengeStartDate = '';
      challengeCheckIns.clear();
      completed = true;
    }
    notifyListeners();
    _save();
    return completed;
  }

  // ── Companion cosmetics (premium) ──────────────────────────────────────────
  void setCompanionSkin(String id) {
    if (!isPremium && id != 'classic') return;
    companionSkin = id;
    notifyListeners();
    _save();
  }

  // Cosmetic class — free for everyone, no gameplay effect.
  void setPlayerClass(String id) {
    playerClass = id;
    notifyListeners();
    _save();
  }

  void setCompanionAccessory(String id) {
    if (!isPremium && id != 'none') return;
    companionAccessory = id;
    notifyListeners();
    _save();
  }

  // ── Streak recovery (premium) ──────────────────────────────────────────────
  int get _premiumSavesUsedThisMonth =>
      premiumSaveMonth == _monthKey(DateTime.now()) ? premiumSavesUsed : 0;
  int get premiumStreakSavesLeft => isPremium
      ? (kPremiumStreakSavesPerMonth - _premiumSavesUsedThisMonth)
          .clamp(0, kPremiumStreakSavesPerMonth)
      : 0;
  bool get restDayActiveToday => restDays.contains(dateKey(DateTime.now()));

  /// Spend one premium streak-save from this month's allowance. Returns false
  /// (nothing spent) when not premium or the allowance is used up.
  bool _consumePremiumSave() {
    if (!isPremium) return false;
    final m = _monthKey(DateTime.now());
    if (premiumSaveMonth != m) {
      premiumSaveMonth = m;
      premiumSavesUsed = 0;
    }
    if (premiumSavesUsed >= kPremiumStreakSavesPerMonth) return false;
    premiumSavesUsed += 1;
    return true;
  }

  /// True when every missed day strictly between [last] and [today] was a
  /// planned rest day (so the streak bridges for free — the rest day already
  /// spent its save when it was taken).
  bool _gapAllRestDays(String last, String today) {
    final a = DateTime.tryParse(last);
    final b = DateTime.tryParse(today);
    if (a == null || b == null) return false;
    var d = DateTime(a.year, a.month, a.day).add(const Duration(days: 1));
    final end = DateTime(b.year, b.month, b.day);
    var gap = 0;
    while (d.isBefore(end)) {
      if (!restDays.contains(dateKey(d))) return false;
      if (++gap > 60) return false; // safety bound
      d = d.add(const Duration(days: 1));
    }
    return gap > 0;
  }

  /// Decide whether a streak survives a gap, consuming a coin shield or a
  /// premium save if needed. Rest-day gaps bridge for free.
  bool _tryBridgeStreak(String last, String today) {
    if (_gapAllRestDays(last, today)) return true;
    if (streakShields > 0) {
      streakShields -= 1;
      return true;
    }
    return _consumePremiumSave();
  }

  /// Mark today as a planned rest day (premium). Draws one from the monthly
  /// allowance so a streak stays protected without a completion today.
  bool takeRestDay() {
    if (!isPremium) return false;
    final today = dateKey(DateTime.now());
    if (restDays.contains(today)) return true;
    if (!_consumePremiumSave()) return false;
    restDays.add(today);
    notifyListeners();
    _save();
    return true;
  }

  // ── Tasks: Dailies & To-Dos ────────────────────────────────────────────────
  bool _dailyDueOn(TaskItem t, DateTime day) =>
      t.weekdays.isEmpty || t.weekdays.contains(day.weekday);
  bool dailyDueToday(TaskItem t) => _dailyDueOn(t, DateTime.now());
  bool taskDoneToday(TaskItem t) => t.kind == TaskKind.daily
      ? t.lastDoneDate == dateKey(DateTime.now())
      : t.done;

  /// Dailies scheduled for today, incomplete first.
  List<TaskItem> get dailiesToday {
    final list = tasks
        .where((t) => t.kind == TaskKind.daily && dailyDueToday(t))
        .toList();
    list.sort((a, b) =>
        (taskDoneToday(a) ? 1 : 0) - (taskDoneToday(b) ? 1 : 0));
    return list;
  }

  /// Open (not-done) to-dos, soonest due first.
  List<TaskItem> get openTodos {
    final list = tasks.where((t) => t.kind == TaskKind.todo && !t.done).toList();
    list.sort((a, b) => (a.dueDate ?? '9999').compareTo(b.dueDate ?? '9999'));
    return list;
  }

  List<TaskItem> get allTodos =>
      tasks.where((t) => t.kind == TaskKind.todo).toList();
  List<TaskItem> get allDailies =>
      tasks.where((t) => t.kind == TaskKind.daily).toList();

  /// Today's still-open tasks (due dailies + open to-dos) — for the Today badge.
  int get openTasksToday =>
      dailiesToday.where((t) => !taskDoneToday(t)).length + openTodos.length;

  void addTask(String title, TaskKind kind,
      {String icon = '', List<int> weekdays = const [], String? dueDate}) {
    if (title.trim().isEmpty) return;
    tasks.add(TaskItem(
      id: newId(),
      title: title.trim(),
      kind: kind,
      icon: icon.trim(),
      weekdays: List<int>.from(weekdays),
      dueDate: dueDate,
    ));
    notifyListeners();
    _save();
  }

  void updateTask(TaskItem t,
      {String? title, String? icon, List<int>? weekdays, String? dueDate}) {
    if (title != null && title.trim().isNotEmpty) t.title = title.trim();
    if (icon != null) t.icon = icon.trim();
    if (weekdays != null) t.weekdays = List<int>.from(weekdays);
    if (dueDate != null) t.dueDate = dueDate.isEmpty ? null : dueDate;
    notifyListeners();
    _save();
  }

  void deleteTask(TaskItem t) {
    tasks.remove(t);
    notifyListeners();
    _save();
  }

  /// Toggle a task's completion, awarding or reverting a small flat XP + coin
  /// reward. Deliberately separate from the habit engine (no streaks/combo).
  void toggleTask(TaskItem t) {
    final today = dateKey(DateTime.now());
    final xp = t.kind == TaskKind.daily ? kDailyXp : kTodoXp;
    final c = t.kind == TaskKind.daily ? kDailyCoins : kTodoCoins;
    final wasDone = taskDoneToday(t);
    if (t.kind == TaskKind.daily) {
      t.lastDoneDate = wasDone ? null : today;
    } else {
      t.done = !wasDone;
    }
    if (wasDone) {
      totalXp = (totalXp - xp).clamp(0, 1 << 30).toInt();
      coins = (coins - c).clamp(0, 1 << 30).toInt();
      _logDay(xp: -xp, done: -1);
    } else {
      totalXp += xp;
      coins += c;
      _logDay(xp: xp, done: 1);
    }
    if (level > highestLevel) highestLevel = level;
    notifyListeners();
    _save();
  }

  // ── Cloud backup (export / import the whole on-device save) ────────────────
  /// True when this device has no meaningful progress yet — safe to restore a
  /// cloud backup over it without losing anything.
  bool get localIsEmpty =>
      totalXp == 0 &&
      perfectDays.isEmpty &&
      reflections.isEmpty &&
      foodLog.isEmpty &&
      tasks.isEmpty &&
      habits.every((h) => h.streak == 0 && h.lastCompletedDate == null);

  /// The whole on-device save as {prefs-key: raw JSON string}.
  Future<Map<String, String>> exportSave() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, String>{};
    for (final k in [
      _habitsKey,
      _metaKey,
      _journalKey,
      _foodKey,
      _milestoneKey,
      _tasksKey,
    ]) {
      final v = prefs.getString(k);
      if (v != null) out[k] = v;
    }
    return out;
  }

  /// Overwrite the local save with [data] ({prefs-key: JSON string}), then
  /// reload everything from it.
  Future<void> importSave(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _habitsKey,
      _metaKey,
      _journalKey,
      _foodKey,
      _milestoneKey,
      _tasksKey,
    ]) {
      final v = data[k];
      if (v is String) await prefs.setString(k, v);
    }
    await load();
  }

  /// Record a successful backup. No notify, so it can't re-trigger the
  /// auto-backup debounce.
  Future<void> markBackedUp() async {
    lastBackupAt = DateTime.now().toIso8601String();
    await _save();
  }

  // ── Account isolation ───────────────────────────────────────────────────────
  // The on-device save is stamped with [saveOwnerId], the account it belongs to.
  // These keep it bound to its owner so logging out of A and into B on the same
  // device can never let A's habits/journal/nutrition/purchases/progress show up
  // as — or be backed up as — B's. The cloud upload paths (backend.dart) also
  // refuse to run unless the save's owner is the signed-in user.

  /// Stamp the save's owner and persist it. Used when a restore makes the local
  /// save belong to the signed-in account.
  Future<void> setSaveOwner(String uid) async {
    saveOwnerId = uid;
    await _save();
  }

  /// Make the on-device save belong to [uid] before any backup or stat upload.
  /// Called on every sign-in:
  ///   • same owner        → keep the save untouched (same account, same device);
  ///   • pristine & empty  → just claim it (fresh install / first account);
  ///   • anyone else's save→ wipe to a clean start for [uid]. Their own progress
  ///     is safe in their cloud backup, which syncAfterSignIn restores next.
  Future<void> adoptOwner(String uid, {String name = ''}) async {
    if (uid.isEmpty) return;
    if (saveOwnerId == uid) return; // same account returning on the same device
    final claimEmpty = saveOwnerId.isEmpty && localIsEmpty;
    saveOwnerId = uid; // stamp FIRST so every _save() below writes the new owner
    if (claimEmpty) {
      await _save(); // nothing to wipe — take ownership of the empty seed state
    } else {
      startFreshForAccount(name); // foreign/unattributed save → clean slate
      await _save();
    }
  }

  /// One-time migration for saves written before owner-stamping existed (owner
  /// is ''). Run once at launch with the signed-in user's id (or null). The
  /// already-signed-in user legitimately owns the on-device save, so claim it —
  /// their existing progress is preserved by the update. If nobody is signed in
  /// but data is present, mark it unattributed so a later sign-in won't adopt
  /// another account's data.
  Future<void> migrateOwnerAtLaunch(String? activeUid) async {
    if (saveOwnerId.isNotEmpty) return; // already stamped — nothing to migrate
    if (activeUid != null && activeUid.isNotEmpty) {
      saveOwnerId = activeUid;
      await _save();
    } else if (!localIsEmpty) {
      saveOwnerId = kUnknownOwner;
      await _save();
    }
    // else: pristine, signed-out device — leave '' for the first sign-in to claim.
  }

  /// Wipe the device save on sign-out so the next account starts clean and never
  /// inherits this one's data. The signed-out account's progress is safe in its
  /// own cloud backup (flushed just before sign-out).
  Future<void> clearForSignOut() async {
    saveOwnerId = '';
    displayName = 'Player';
    startFreshForAccount('');
    await _save();
  }

  void resetAll() {
    habits
      ..clear()
      ..addAll(_seedHabits());
    reflections.clear();
    tasks.clear();
    foodLog.clear();
    milestoneLog.clear();
    perfectDays.clear();
    questClaimedIds.clear();
    earnedAchievements.clear();
    claimedQuests.clear();
    blockedUsers.clear();
    totalXp = 0;
    coins = 100;
    focusMinutesToday = 0;
    focusDateKey = '';
    _clearFocusSession();
    bossRewardedWeek = '';
    pendingBossDefeat = false;
    questDateKey = '';
    prestige = 0;
    currentSeason = 0;
    seasonBossDefeats = 0;
    pendingPrestige = false;
    pendingSeasonIntro = false;
    bodyProfile = null;
    totalBossDefeats = 0;
    highestLevel = 1;
    evolvedStage = 0;
    _prevLevel = 1;
    activeCompanion = 'drone';
    lastCompanionLine = '';
    pfpBase64 = '';
    pfpBytes = null;
    coachUsesThisWeek = 0;
    coachWeekKey = '';
    weeklyReportText = '';
    weeklyReportWeekKey = '';
    weeklyPlanText = '';
    weeklyPlanWeekKey = '';
    activeChallengeId = '';
    challengeStartDate = '';
    challengeCheckIns.clear();
    completedChallenges.clear();
    companionSkin = 'classic';
    companionAccessory = 'none';
    playerClass = 'wanderer';
    premiumSavesUsed = 0;
    premiumSaveMonth = '';
    restDays.clear();
    selectedBorder = 'none';
    ownedBorders
      ..clear()
      ..add('none');
    ownedThemes
      ..clear()
      ..add('violet');
    themeId = 'violet';
    applyThemeColors('violet');
    notifyListeners();
    _save();
  }

  /// A brand-new account starts completely from zero: the fresh-install state
  /// (Level 1, 0 XP, starter habits) PLUS the few carry-over fields resetAll
  /// leaves alone, so nothing from a previous user remains.
  void startFreshForAccount(String name) {
    resetAll();
    dailyScore.clear();
    dailyXp.clear();
    dailyFocus.clear();
    dailyDone.clear();
    streakShields = 0;
    xpBoostDate = null;
    premiumOverride = ''; // the previous account's; the new one syncs its own
    // Mark today's briefing as seen so a new account doesn't get the morning
    // briefing immediately after the onboarding flow (double welcome). The first
    // real briefing then appears the next day.
    lastBriefingDate = dateKey(DateTime.now());
    if (name.trim().isNotEmpty) displayName = name.trim();
    notifyListeners();
    _save();
  }

  // Today's logged macros.
  ({double calories, double protein, double carbs, double fat})
      todayNutrition() {
    final today = dateKey(DateTime.now());
    double cal = 0, p = 0, c = 0, f = 0;
    for (final e in foodLog.where((e) => e.date == today)) {
      cal += e.calories;
      p += e.protein;
      c += e.carbs;
      f += e.fat;
    }
    return (calories: cal, protein: p, carbs: c, fat: f);
  }

  /// Nutrition score 0–100 — ported from lib/nutrition/scoring.ts:
  /// energy(40%) + recovery(30%) + (100 − fatigue)(30%).
  int nutritionScore() {
    final n = todayNutrition();
    // Nothing logged today → score 0. (Otherwise the fatigue model credits
    // "100 − fatigue" on an empty day and a fresh account shows a phantom ~5.)
    if (n.calories <= 0 && n.protein <= 0 && n.carbs <= 0 && n.fat <= 0) {
      return 0;
    }
    final t = targets();
    // Energy availability
    final maxPossible = t.protein * 0.4 + t.carbs * 0.4 + t.fat * 0.2;
    final actual = n.protein * 0.4 + n.carbs * 0.4 + n.fat * 0.2;
    final energy =
        maxPossible == 0 ? 0 : min(100.0, actual / maxPossible * 100).round();
    // Recovery
    final proteinPct = t.protein <= 0 ? 0.0 : min(1.0, n.protein / t.protein);
    final caloriePct = t.calories <= 0 ? 0.0 : min(1.0, n.calories / t.calories);
    final recovery =
        (proteinPct * 50 + caloriePct * 30 + (_sleepDoneToday() ? 20 : 0))
            .round();
    // Fatigue (gym/recovery history approximated from streaks on mobile)
    final calorieDrop =
        t.calories <= 0 ? 0.0 : max(0.0, 1 - n.calories / t.calories) * 100;
    final proteinDrop =
        t.protein <= 0 ? 0.0 : max(0.0, 1 - n.protein / t.protein) * 100;
    final gymStreak = habits
        .where((h) =>
            h.name.toLowerCase().contains('exercise') ||
            h.name.toLowerCase().contains('gym'))
        .fold<int>(0, (mx, h) => max(mx, h.streak));
    final gymStress = min(100.0, min(3, gymStreak) * 34.0);
    final sleepStreak = habits
        .where((h) => h.name.toLowerCase().contains('sleep'))
        .fold<int>(0, (mx, h) => max(mx, h.streak));
    final poorRecovery = max(0.0, 1 - min(1.0, sleepStreak / 7)) * 100;
    final fatigue = (calorieDrop * 0.4 +
            proteinDrop * 0.35 +
            gymStress * 0.15 +
            poorRecovery * 0.1)
        .round();
    final score =
        (energy * 0.4 + recovery * 0.3 + (100 - fatigue) * 0.3).round();
    return score.clamp(0, 100);
  }

  /// Victory Score — exact 4-pillar formula (lib/engine/victoryScore.ts):
  /// habits 40 + nutrition 25 + focus 20 + sleep 15.
  ({int score, int habits, int nutrition, int focus, int sleep}) victory() {
    final total = habits.length;
    final done = doneTodayCount;
    final habitsC = total > 0 ? (done / total * 40).round() : 0;
    final nutritionC = (nutritionScore().clamp(0, 100) * 0.25).round();
    final focusC = (min(1.0, focusMinutesToday / 90) * 20).round();
    final sleepC = _sleepDoneToday() ? 15 : 0;
    final score = min(100, habitsC + nutritionC + focusC + sleepC);
    return (
      score: score,
      habits: habitsC,
      nutrition: nutritionC,
      focus: focusC,
      sleep: sleepC
    );
  }

  /// Perfect days in this calendar week (Monday to Sunday) — the boss's
  /// "this week", not a rolling 7 days that reaches into last week.
  int perfectDaysThisWeek() {
    final week = weekKey(DateTime.now());
    return perfectDays.where((k) {
      final d = DateTime.tryParse(k);
      return d != null && weekKey(d) == week;
    }).length;
  }

  bool get bossDefeatedThisWeek => bossRewardedWeek == weekKey(DateTime.now());

  List<({String label, int score, bool today})> weekTrend() {
    const wd = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final now = DateTime.now();
    final todayK = dateKey(now);
    final out = <({String label, int score, bool today})>[];
    for (int i = 6; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final k = dateKey(d);
      out.add((
        label: wd[(d.weekday - 1) % 7],
        score: dailyScore[k] ?? 0,
        today: k == todayK
      ));
    }
    return out;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    saveOwnerId = prefs.getString(_ownerKey) ?? '';
    final raw = prefs.getString(_habitsKey);
    if (raw != null && raw.isNotEmpty) {
      habits
        ..clear()
        ..addAll((jsonDecode(raw) as List)
            .map((e) => Habit.fromMap(e as Map<String, dynamic>)));
    } else {
      habits.addAll(_seedHabits());
    }
    final meta = prefs.getString(_metaKey);
    if (meta != null && meta.isNotEmpty) {
      final m = jsonDecode(meta) as Map<String, dynamic>;
      totalXp = (m['totalXp'] as int?) ?? 0;
      coins = (m['coins'] as int?) ?? 100;
      focusMinutesToday = (m['focusMinutesToday'] as int?) ?? 0;
      focusDateKey = (m['focusDateKey'] as String?) ?? '';
      focusSessionActive = (m['focusSessionActive'] as bool?) ?? false;
      focusSessionMinutes = (m['focusSessionMinutes'] as int?) ?? 0;
      focusSessionDeadline = (m['focusSessionDeadline'] as String?) ?? '';
      focusSessionPausedRemaining =
          (m['focusSessionPausedRemaining'] as int?) ?? 0;
      focusSessionMode = (m['focusSessionMode'] as int?) ?? 0;
      // Older saves kept a plain flag; read it as "already paid this week" so
      // the switch to calendar weeks never pays the boss twice.
      bossRewardedWeek = (m['bossRewardedWeek'] as String?) ??
          (((m['bossRewarded'] as bool?) ?? false) ? weekKey(DateTime.now()) : '');
      questDateKey = (m['questDateKey'] as String?) ?? '';
      perfectDays.addAll(
          ((m['perfectDays'] as List?) ?? const []).map((e) => e as String));
      questClaimedIds.addAll(((m['questClaimedIds'] as List?) ?? const [])
          .map((e) => e as String));
      activeCompanion = (m['activeCompanion'] as String?) ?? 'drone';
      prestige = (m['prestige'] as int?) ?? 0;
      currentSeason = (m['currentSeason'] as int?) ?? 0;
      seasonBossDefeats = (m['seasonBossDefeats'] as int?) ?? 0;
      final bp = m['bodyProfile'];
      if (bp is Map<String, dynamic>) bodyProfile = BodyProfile.fromMap(bp);
      totalBossDefeats = (m['totalBossDefeats'] as int?) ?? 0;
      highestLevel = (m['highestLevel'] as int?) ?? 1;
      evolvedStage = (m['evolvedStage'] as int?) ?? -1; // -1: older save
      displayName = (m['displayName'] as String?) ?? 'Player';
      lastBackupAt = (m['lastBackupAt'] as String?) ?? '';
      lastBriefingDate = (m['lastBriefingDate'] as String?) ?? '';
      themeId = (m['themeId'] as String?) ?? 'violet';
      void readDays(Object? src, Map<String, int> into) {
        if (src is! Map) return;
        into.clear();
        src.forEach((k, v) => into[k as String] = (v as num).toInt());
      }
      readDays(m['dailyScore'], dailyScore);
      readDays(m['dailyXp'], dailyXp);
      readDays(m['dailyFocus'], dailyFocus);
      readDays(m['dailyDone'], dailyDone);
      streakShields = (m['streakShields'] as int?) ?? 0;
      xpBoostDate = m['xpBoostDate'] as String?;
      aiEnabled = (m['aiEnabled'] as bool?) ?? true;
      aiBaseUrl = (m['aiBaseUrl'] as String?) ?? kDefaultAiBaseUrl;
      aiModel = (m['aiModel'] as String?) ?? kDefaultAiModel;
      remindersOn = (m['remindersOn'] as bool?) ?? true;
      streakAlertOn = (m['streakAlertOn'] as bool?) ?? true;
      streakAlertMinutes = (m['streakAlertMinutes'] as int?) ?? 20 * 60;
      notifAsked = (m['notifAsked'] as bool?) ?? false;
      notifOffered = (m['notifOffered'] as bool?) ?? false;
      premiumExpiresAt = (m['premiumExpiresAt'] as String?) ?? '';
      premiumVerifiedAt = (m['premiumVerifiedAt'] as String?) ?? '';
      // Migration: older saves had only a permanent `isPremium` bool. Don't
      // honour it forever — grant a short grace window and require a store
      // purchase / restore to confirm a real subscription (most such flags
      // were developer / scaffold grants, not paid subscriptions).
      final legacyPremium = (m['isPremium'] as bool?) ?? false;
      if (premiumExpiresAt.isEmpty && legacyPremium) {
        premiumExpiresAt =
            DateTime.now().add(const Duration(days: 7)).toIso8601String();
      }
      premiumOverride = (m['premiumOverride'] as String?) ?? '';
      appliedCoinGrants
        ..clear()
        ..addAll(((m['appliedCoinGrants'] as List?) ?? const [])
            .map((e) => e as String));
      coachUsesThisWeek = (m['coachUsesThisWeek'] as int?) ?? 0;
      coachWeekKey = (m['coachWeekKey'] as String?) ?? '';
      premiumPlan = (m['premiumPlan'] as String?) ?? (legacyPremium ? 'annual' : 'none');
      premiumSince = (m['premiumSince'] as String?) ?? '';
      weeklyReportText = (m['weeklyReportText'] as String?) ?? '';
      weeklyReportWeekKey = (m['weeklyReportWeekKey'] as String?) ?? '';
      weeklyPlanText = (m['weeklyPlanText'] as String?) ?? '';
      weeklyPlanWeekKey = (m['weeklyPlanWeekKey'] as String?) ?? '';
      activeChallengeId = (m['activeChallengeId'] as String?) ?? '';
      challengeStartDate = (m['challengeStartDate'] as String?) ?? '';
      challengeCheckIns.addAll(((m['challengeCheckIns'] as List?) ?? const [])
          .map((e) => e as String));
      completedChallenges.addAll(
          ((m['completedChallenges'] as List?) ?? const [])
              .map((e) => e as String));
      companionSkin = (m['companionSkin'] as String?) ?? 'classic';
      companionAccessory = (m['companionAccessory'] as String?) ?? 'none';
      playerClass = (m['playerClass'] as String?) ?? 'wanderer';
      premiumSavesUsed = (m['premiumSavesUsed'] as int?) ?? 0;
      premiumSaveMonth = (m['premiumSaveMonth'] as String?) ?? '';
      restDays.addAll(
          ((m['restDays'] as List?) ?? const []).map((e) => e as String));
      earnedAchievements.addAll(
          ((m['earnedAchievements'] as List?) ?? const []).map((e) => e as String));
      claimedQuests.addAll(
          ((m['claimedQuests'] as List?) ?? const []).map((e) => e as String));
      blockedUsers.addAll(
          ((m['blockedUsers'] as List?) ?? const []).map((e) => e as String));
      pfpBase64 = (m['pfpBase64'] as String?) ?? '';
      try {
        pfpBytes = pfpBase64.isEmpty ? null : base64Decode(pfpBase64);
      } catch (_) {
        pfpBytes = null;
        pfpBase64 = '';
      }
      selectedBorder = (m['selectedBorder'] as String?) ?? 'none';
      ownedBorders.addAll(
          ((m['ownedBorders'] as List?) ?? const []).map((e) => e as String));
      ownedThemes.addAll(
          ((m['ownedThemes'] as List?) ?? const []).map((e) => e as String));
      ownedThemes.add(themeId); // keep the active theme owned (back-compat)
      if (!ownedBorders.contains(selectedBorder)) selectedBorder = 'none';
    }
    applyThemeColors(themeId);
    final today = dateKey(DateTime.now());
    if (focusDateKey != today) {
      focusDateKey = today;
      focusMinutesToday = 0;
    }
    if (questDateKey != today) {
      questDateKey = today;
      questClaimedIds.clear();
    }
    final journal = prefs.getString(_journalKey);
    if (journal != null && journal.isNotEmpty) {
      reflections
        ..clear()
        ..addAll((jsonDecode(journal) as List)
            .map((e) => Reflection.fromMap(e as Map<String, dynamic>)));
    }
    final food = prefs.getString(_foodKey);
    if (food != null && food.isNotEmpty) {
      foodLog
        ..clear()
        ..addAll((jsonDecode(food) as List)
            .map((e) => FoodEntry.fromMap(e as Map<String, dynamic>)));
    }
    final ml = prefs.getString(_milestoneKey);
    if (ml != null && ml.isNotEmpty) {
      milestoneLog
        ..clear()
        ..addAll((jsonDecode(ml) as List)
            .map((e) => MilestoneEvent.fromMap(e as Map<String, dynamic>)));
    }
    final tk = prefs.getString(_tasksKey);
    if (tk != null && tk.isNotEmpty) {
      tasks
        ..clear()
        ..addAll((jsonDecode(tk) as List)
            .map((e) => TaskItem.fromMap(e as Map<String, dynamic>)));
    }
    _prevLevel = level;
    if (level > highestLevel) highestLevel = level;
    // An older save already reached its stage; don't celebrate it again.
    if (evolvedStage < 0) evolvedStage = companionStage(level);
    _checkAchievements(silent: true); // backfill anything already satisfied
    loading = false;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ownerKey, saveOwnerId);
    await prefs.setString(
        _habitsKey, jsonEncode(habits.map((h) => h.toMap()).toList()));
    await prefs.setString(
        _journalKey, jsonEncode(reflections.map((r) => r.toMap()).toList()));
    await prefs.setString(
        _foodKey, jsonEncode(foodLog.map((e) => e.toMap()).toList()));
    await prefs.setString(
        _milestoneKey, jsonEncode(milestoneLog.map((e) => e.toMap()).toList()));
    await prefs.setString(
        _tasksKey, jsonEncode(tasks.map((t) => t.toMap()).toList()));
    await prefs.setString(
        _metaKey,
        jsonEncode({
          'totalXp': totalXp,
          'coins': coins,
          'focusMinutesToday': focusMinutesToday,
          'focusDateKey': focusDateKey,
          'focusSessionActive': focusSessionActive,
          'focusSessionMinutes': focusSessionMinutes,
          'focusSessionDeadline': focusSessionDeadline,
          'focusSessionPausedRemaining': focusSessionPausedRemaining,
          'focusSessionMode': focusSessionMode,
          'bossRewardedWeek': bossRewardedWeek,
          'questDateKey': questDateKey,
          'perfectDays': perfectDays.toList(),
          'questClaimedIds': questClaimedIds.toList(),
          'activeCompanion': activeCompanion,
          'prestige': prestige,
          'currentSeason': currentSeason,
          'seasonBossDefeats': seasonBossDefeats,
          'bodyProfile': bodyProfile?.toMap(),
          'totalBossDefeats': totalBossDefeats,
          'highestLevel': highestLevel,
          'evolvedStage': evolvedStage,
          'displayName': displayName,
          'lastBackupAt': lastBackupAt,
          'lastBriefingDate': lastBriefingDate,
          'themeId': themeId,
          'dailyScore': dailyScore,
          'dailyXp': dailyXp,
          'dailyFocus': dailyFocus,
          'dailyDone': dailyDone,
          'streakShields': streakShields,
          'xpBoostDate': xpBoostDate,
          'aiEnabled': aiEnabled,
          'aiBaseUrl': aiBaseUrl,
          'aiModel': aiModel,
          'remindersOn': remindersOn,
          'streakAlertOn': streakAlertOn,
          'streakAlertMinutes': streakAlertMinutes,
          'notifAsked': notifAsked,
          'notifOffered': notifOffered,
          'premiumExpiresAt': premiumExpiresAt,
          'premiumVerifiedAt': premiumVerifiedAt,
          'premiumOverride': premiumOverride,
          'appliedCoinGrants': appliedCoinGrants.toList(),
          'coachUsesThisWeek': coachUsesThisWeek,
          'coachWeekKey': coachWeekKey,
          'premiumPlan': premiumPlan,
          'premiumSince': premiumSince,
          'weeklyReportText': weeklyReportText,
          'weeklyReportWeekKey': weeklyReportWeekKey,
          'weeklyPlanText': weeklyPlanText,
          'weeklyPlanWeekKey': weeklyPlanWeekKey,
          'activeChallengeId': activeChallengeId,
          'challengeStartDate': challengeStartDate,
          'challengeCheckIns': challengeCheckIns.toList(),
          'completedChallenges': completedChallenges.toList(),
          'companionSkin': companionSkin,
          'companionAccessory': companionAccessory,
          'playerClass': playerClass,
          'premiumSavesUsed': premiumSavesUsed,
          'premiumSaveMonth': premiumSaveMonth,
          'restDays': restDays.toList(),
          'earnedAchievements': earnedAchievements.toList(),
          'claimedQuests': claimedQuests.toList(),
          'blockedUsers': blockedUsers.toList(),
          'pfpBase64': pfpBase64,
          'selectedBorder': selectedBorder,
          'ownedBorders': ownedBorders.toList(),
          'ownedThemes': ownedThemes.toList(),
        }));
  }

  void _afterAction() {
    _checkQuests();
    _updateBoss();
    _checkAchievements();
    final nl = level;
    if (nl > _prevLevel) {
      _logMilestone('level_up', 'Reached Level $nl · ${levelTitle(nl)}');
    }
    _prevLevel = nl;
    if (nl > highestLevel) highestLevel = nl;
    dailyScore[dateKey(DateTime.now())] = victory().score;
    if (dailyScore.length > 120) {
      final cutoff = dateKey(DateTime.now().subtract(const Duration(days: 90)));
      dailyScore.removeWhere((k, v) => k.compareTo(cutoff) < 0);
    }
    notifyListeners();
    _save();
  }

  /// Adds to today's activity totals (negative to undo); keeps ~2 years.
  void _logDay({int xp = 0, int focus = 0, int done = 0}) {
    final k = dateKey(DateTime.now());
    void bump(Map<String, int> m, int d) {
      if (d == 0) return;
      final v = max(0, (m[k] ?? 0) + d);
      if (v == 0) {
        m.remove(k);
      } else {
        m[k] = v;
      }
    }

    bump(dailyXp, xp);
    bump(dailyFocus, focus);
    bump(dailyDone, done);
    final cutoff = dateKey(DateTime.now().subtract(const Duration(days: 760)));
    for (final m in [dailyXp, dailyFocus, dailyDone]) {
      if (m.length > 780) m.removeWhere((key, _) => key.compareTo(cutoff) < 0);
    }
  }

  /// Sum of a per-day map over [from, to) (dates compared by day).
  int sumDays(Map<String, int> m, DateTime from, DateTime to) {
    final a = dateKey(from), b = dateKey(to);
    var s = 0;
    m.forEach((k, v) {
      if (k.compareTo(a) >= 0 && k.compareTo(b) < 0) s += v;
    });
    return s;
  }

  void _logMilestone(String type, String description, {int xp = 0}) {
    milestoneLog.insert(
        0,
        MilestoneEvent(
          type: type,
          date: DateTime.now().toIso8601String(),
          level: level,
          description: description,
          xp: xp,
        ));
  }

  void _checkQuests() {
    final today = dateKey(DateTime.now());
    if (questDateKey != today) {
      questDateKey = today;
      questClaimedIds.clear();
    }
    for (final q in kQuests) {
      if (!questClaimedIds.contains(q.id) && q.done(this)) {
        questClaimedIds.add(q.id);
        totalXp += q.xp;
        _logDay(xp: q.xp);
        coins += q.xp ~/ 5;
      }
    }
  }

  // Record any achievement whose condition is currently met. Once earned, an
  // achievement stays earned — so XP/level ones don't re-lock after prestige.
  // Newly-earned achievement ids awaiting a celebration popup (transient,
  // never persisted — a fresh launch starts with none pending).
  final List<String> _pendingAchievements = [];

  void _checkAchievements({bool silent = false}) {
    for (final a in kAchievements) {
      if (!earnedAchievements.contains(a.id) && a.unlocked(this)) {
        earnedAchievements.add(a.id);
        if (!silent) _pendingAchievements.add(a.id);
      }
    }
  }

  bool isAchievementEarned(Achievement a) =>
      earnedAchievements.contains(a.id) || a.unlocked(this);

  /// Earned achievements, most recent first. The earned set keeps unlock
  /// order; anything unlocked but not recorded yet counts as newest.
  List<Achievement> get recentAchievements {
    final byId = {for (final a in kAchievements) a.id: a};
    final recorded = [
      for (final id in earnedAchievements)
        if (byId[id] != null) byId[id]!,
    ];
    final pending = kAchievements
        .where((a) => !earnedAchievements.contains(a.id) && a.unlocked(this))
        .toList();
    return [...pending.reversed, ...recorded.reversed];
  }

  // Returns the achievements earned since the last call, then clears the queue
  // so each unlock is only celebrated once.
  List<Achievement> consumeNewAchievements() {
    if (_pendingAchievements.isEmpty) return const [];
    final ids = _pendingAchievements.toList();
    _pendingAchievements.clear();
    return kAchievements.where((a) => ids.contains(a.id)).toList();
  }

  // Pays out once per calendar week, even if a perfect day is later undone.
  void _updateBoss() {
    if (perfectDaysThisWeek() >= kBossGoal && !bossDefeatedThisWeek) {
      totalXp += kBossXp;
      _logDay(xp: kBossXp);
      coins += kBossCoins;
      bossRewardedWeek = weekKey(DateTime.now());
      pendingBossDefeat = true;
      totalBossDefeats += 1;
      _logMilestone('boss_defeat', 'Defeated the weekly boss', xp: kBossXp);
      // Seasons: 4 boss defeats complete a season (web parity).
      seasonBossDefeats += 1;
      if (seasonBossDefeats >= 4) {
        seasonBossDefeats = 0;
        currentSeason += 1;
        pendingSeasonIntro = true;
        _logMilestone('season', 'Season ${currentSeason + 1} begins');
      }
    }
  }

  bool get canPrestige => level >= kPrestigeMinLevel;

  /// The stage the companion just evolved to, once; null when there's nothing
  /// new to celebrate.
  int? consumeEvolution() {
    final st = companionStage(level);
    if (st <= evolvedStage) return null;
    evolvedStage = st;
    _save();
    return st;
  }

  void doPrestige() {
    if (!canPrestige) return;
    totalXp = 0;
    prestige += 1;
    pendingPrestige = true;
    for (final h in habits) {
      h.todayAwardXp = 0;
    }
    // Level is back to 1, so re-lock any companion above it — if the active one
    // is now locked, fall back to the default so it can't show locked + active.
    if (!companionUnlocked(activeCompanion)) activeCompanion = 'drone';
    _logMilestone('prestige', 'Prestiged — now ★$prestige');
    _prevLevel = 1;
    evolvedStage = 0; // a fresh path: each stage evolves (and is celebrated) again
    notifyListeners();
    _save();
  }

  bool consumePrestige() {
    if (pendingPrestige) {
      pendingPrestige = false;
      return true;
    }
    return false;
  }

  bool consumeSeasonIntro() {
    if (pendingSeasonIntro) {
      pendingSeasonIntro = false;
      return true;
    }
    return false;
  }

  bool consumeBossDefeat() {
    if (pendingBossDefeat) {
      pendingBossDefeat = false;
      return true;
    }
    return false;
  }

  bool companionUnlocked(String type) =>
      level >= companionByType(type).unlockLevel;

  void setCompanion(String type) {
    activeCompanion = type;
    notifyListeners();
    _save();
  }

  void setCompanionLine(String line) {
    lastCompanionLine = line;
    notifyListeners();
  }

  /// Toggles today's completion. Returns the new level.
  int toggle(Habit h) {
    final today = dateKey(DateTime.now());
    final yesterday = dateKey(DateTime.now().subtract(const Duration(days: 1)));
    final oldStreak = h.streak;
    if (h.lastCompletedDate == today) {
      totalXp = (totalXp - h.todayAwardXp).clamp(0, 1 << 30).toInt();
      coins = (coins - (h.todayAwardXp ~/ 5)).clamp(0, 1 << 30).toInt();
      _logDay(xp: -h.todayAwardXp, done: -1);
      h.todayAwardXp = 0;
      h.streak = h.streak > 0 ? h.streak - 1 : 0;
      h.lastCompletedDate = h.streak > 0 ? yesterday : null;
    } else {
      if (h.lastCompletedDate == yesterday) {
        h.streak += 1;
      } else if (h.lastCompletedDate != null &&
          _tryBridgeStreak(h.lastCompletedDate!, today)) {
        h.streak += 1; // bridged by a rest day, coin shield, or premium save
      } else {
        h.streak = 1;
      }
      h.lastCompletedDate = today;
      var gain = calculateXpGain(
          h.baseXp, h.rarity, h.streak, comboMultiplier(doneTodayCount));
      gain = (gain * (1 + 0.05 * prestige)).round(); // +5% XP per prestige star
      if (xpBoostActive) gain *= 2; // 2x XP booster
      h.todayAwardXp = gain;
      totalXp += gain;
      coins += gain ~/ 5;
      _logDay(xp: gain, done: 1);
    }
    if (habits.isNotEmpty && doneTodayCount == habits.length) {
      perfectDays.add(today);
    } else {
      perfectDays.remove(today);
    }
    if (h.streak == 7 && oldStreak != 7) {
      _logMilestone('streak', '${h.name} · 7-day streak');
    } else if (h.streak == 30 && oldStreak != 30) {
      _logMilestone('streak', '${h.name} · 30-day streak');
    }
    _afterAction();
    return level;
  }

  void addHabit(String name, String rarity,
      {String icon = '',
      bool aiRated = false,
      String reason = '',
      int? reminderMinutes}) {
    habits.add(Habit(
      id: newId(),
      name: name,
      rarity: rarity,
      icon: icon,
      aiRated: aiRated,
      difficultyReason: reason,
      reminderMinutes: reminderMinutes,
    ));
    _afterAction();
  }

  // newIndex is already adjusted for the removal at oldIndex (onReorderItem).
  void reorderHabits(int oldIndex, int newIndex) {
    final h = habits.removeAt(oldIndex);
    habits.insert(newIndex, h);
    notifyListeners();
    _save();
  }

  void setHabitReminder(Habit h, int? minutes) {
    h.reminderMinutes = minutes;
    notifyListeners();
    _save();
  }

  void editHabit(Habit h,
      {String? name,
      String? rarity,
      String? icon,
      bool? aiRated,
      String? reason}) {
    if (name != null) h.name = name;
    if (rarity != null) h.rarity = rarity;
    if (icon != null) h.icon = icon;
    if (aiRated != null) h.aiRated = aiRated;
    if (reason != null) h.difficultyReason = reason;
    notifyListeners();
    _save();
  }

  void deleteHabit(Habit h) {
    habits.removeWhere((x) => x.id == h.id);
    _afterAction();
  }

  void addReflection(String text,
      {int day = 0, int energy = 0, int mood = 0, int focus = 0}) {
    reflections.insert(
        0,
        Reflection(
          date: dateKey(DateTime.now()),
          text: text,
          day: day,
          energy: energy,
          mood: mood,
          focus: focus,
        ));
    totalXp += 20;
    coins += 4;
    _logDay(xp: 20);
    _afterAction();
  }

  void updateReflection(Reflection old, String text,
      {int day = 0, int energy = 0, int mood = 0, int focus = 0}) {
    final i = reflections.indexOf(old);
    if (i < 0) return;
    reflections[i] = Reflection(
      date: old.date,
      text: text,
      day: day,
      energy: energy,
      mood: mood,
      focus: focus,
    );
    notifyListeners();
    _save();
  }

  void deleteReflection(Reflection r) {
    reflections.remove(r);
    notifyListeners();
    _save();
  }

  // Grant a co-op quest reward once (keyed per party+week+quest).
  void claimCoopQuest(String key, int reward) {
    if (claimedQuests.contains(key)) return;
    claimedQuests.add(key);
    coins += reward;
    notifyListeners();
    _save();
  }

  // Chat moderation: hide all messages from a user on this device.
  bool isBlocked(String id) => id.isNotEmpty && blockedUsers.contains(id);
  void blockUser(String id) {
    if (id.isEmpty || !blockedUsers.add(id)) return;
    notifyListeners();
    _save();
  }

  void unblockUser(String id) {
    if (blockedUsers.remove(id)) {
      notifyListeners();
      _save();
    }
  }

  void addFood(String name, double cal, double p, double c, double f) {
    foodLog.insert(
        0,
        FoodEntry(
            id: newId(),
            name: name,
            calories: cal,
            protein: p,
            carbs: c,
            fat: f,
            date: dateKey(DateTime.now())));
    _afterAction();
  }

  void deleteFood(FoodEntry e) {
    foodLog.removeWhere((x) => x.id == e.id);
    _afterAction();
  }

  // ── Focus session ──────────────────────────────────────────────────────────
  bool get focusRunning =>
      focusSessionActive && focusSessionDeadline.isNotEmpty;
  bool get focusPaused =>
      focusSessionActive && focusSessionDeadline.isEmpty;

  /// Seconds left in the active session, from the wall-clock deadline (running)
  /// or the frozen value (paused). 0 once the deadline has passed; 0 when idle.
  int get focusRemainingSeconds {
    if (!focusSessionActive) return 0;
    if (focusSessionDeadline.isEmpty) return focusSessionPausedRemaining;
    final d = DateTime.tryParse(focusSessionDeadline);
    if (d == null) return 0;
    final secs = d.difference(focusNow()).inSeconds;
    return secs < 0 ? 0 : secs;
  }

  /// Begin a [minutes]-long session, ending at now + minutes (a real deadline).
  void startFocus(int minutes, {int mode = 0}) {
    focusSessionActive = true;
    focusSessionMinutes = minutes;
    focusSessionMode = mode;
    focusSessionDeadline =
        focusNow().add(Duration(minutes: minutes)).toIso8601String();
    focusSessionPausedRemaining = 0;
    notifyListeners();
    _save();
  }

  /// Freeze the countdown: remember the seconds left and drop the deadline.
  void pauseFocus() {
    if (!focusRunning) return;
    focusSessionPausedRemaining = focusRemainingSeconds;
    focusSessionDeadline = '';
    notifyListeners();
    _save();
  }

  /// Resume from a pause: a fresh deadline of now + the frozen remaining.
  void resumeFocus() {
    if (!focusPaused) return;
    focusSessionDeadline = focusNow()
        .add(Duration(seconds: focusSessionPausedRemaining))
        .toIso8601String();
    focusSessionPausedRemaining = 0;
    notifyListeners();
    _save();
  }

  /// Abandon the session without granting anything.
  void resetFocus() {
    if (!focusSessionActive) return;
    _clearFocusSession();
    notifyListeners();
    _save();
  }

  void _clearFocusSession() {
    focusSessionActive = false;
    focusSessionDeadline = '';
    focusSessionPausedRemaining = 0;
    focusSessionMinutes = 0;
  }

  /// Grant a running session that has reached its deadline — EXACTLY once — and
  /// return the XP gained; otherwise null. Safe to call repeatedly (every UI
  /// tick, on resume, and at launch): the session is consumed before the grant,
  /// so no resume / restart / repeated-resume path can credit it twice. This is
  /// also how a session whose deadline passed in the background gets credited.
  int? reconcileFocus() {
    if (!focusRunning) return null;
    if (focusRemainingSeconds > 0) return null;
    final minutes = focusSessionMinutes;
    _clearFocusSession(); // consume FIRST — the once-only guard
    return completeFocus(minutes); // adds minutes + XP + coins, then saves
  }

  /// Rewards a completed focus session (~2 XP per minute).
  int completeFocus(int minutes) {
    final today = dateKey(DateTime.now());
    if (focusDateKey != today) {
      focusDateKey = today;
      focusMinutesToday = 0;
    }
    focusMinutesToday += minutes;
    final gain = minutes * 2;
    totalXp += gain;
    coins += gain ~/ 5;
    _logDay(xp: gain, focus: minutes);
    _afterAction();
    return gain;
  }
}

// ── Daily quests — ported from lib/progression.ts DAILY_QUESTS ──────────────
class QuestDef {
  const QuestDef(this.id, this.title, this.xp, this.done);
  final String id;
  final String title;
  final int xp;
  final bool Function(AppState) done;
}

const List<QuestDef> kQuests = [
  QuestDef('q1', 'Complete 5 habits today', 100, _q1),
  QuestDef('q2', 'Log a 25-min focus session', 60, _q2),
  QuestDef('q3', 'Write a reflection', 40, _q3),
  QuestDef('q4', 'Achieve a 3-habit combo', 80, _q4),
  QuestDef('q5', 'Hit 80% daily score', 120, _q5),
];

bool _q1(AppState s) => s.doneTodayCount >= 5;
bool _q2(AppState s) => s.focusMinutesToday >= 25;
bool _q3(AppState s) =>
    s.reflections.any((r) => r.date == dateKey(DateTime.now()));
bool _q4(AppState s) => s.doneTodayCount >= 3;
bool _q5(AppState s) => s.victory().score >= 80;

// ── Achievements (computed from state) ───────────────────────────────────────
class Achievement {
  const Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.rarity,
    required this.unlocked,
  });
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final String rarity;
  final bool Function(AppState) unlocked;
  String get imageAsset => 'assets/achievements/$id.png';
}

const List<Achievement> kAchievements = [
  Achievement(
      id: 'first',
      title: 'First Step',
      description: 'Complete your first habit',
      icon: Icons.flag_rounded,
      rarity: 'common',
      unlocked: _firstStep),
  Achievement(
      id: 'xp100',
      title: 'Getting Started',
      description: 'Earn 100 total XP',
      icon: Icons.bolt_rounded,
      rarity: 'common',
      unlocked: _xp100),
  Achievement(
      id: 'lvl5',
      title: 'Acolyte',
      description: 'Reach Level 5',
      icon: Icons.military_tech_rounded,
      rarity: 'rare',
      unlocked: _lvl5),
  Achievement(
      id: 'lvl15',
      title: 'Operator',
      description: 'Reach Level 15',
      icon: Icons.workspace_premium_rounded,
      rarity: 'epic',
      unlocked: _lvl15),
  Achievement(
      id: 'streak7',
      title: 'Week Warrior',
      description: 'Hit a 7-day streak',
      icon: Icons.local_fire_department_rounded,
      rarity: 'rare',
      unlocked: _streak7),
  Achievement(
      id: 'streak30',
      title: 'Unstoppable',
      description: 'Hit a 30-day streak',
      icon: Icons.whatshot_rounded,
      rarity: 'legendary',
      unlocked: _streak30),
  Achievement(
      id: 'collector',
      title: 'Collector',
      description: 'Track 5 habits',
      icon: Icons.widgets_rounded,
      rarity: 'common',
      unlocked: _collector),
  Achievement(
      id: 'perfect',
      title: 'Perfect Day',
      description: 'Complete every habit in one day',
      icon: Icons.verified_rounded,
      rarity: 'epic',
      unlocked: _perfect),
  Achievement(
      id: 'elite',
      title: 'Elite Day',
      description: 'Hit a 90+ Victory Score',
      icon: Icons.auto_awesome_rounded,
      rarity: 'epic',
      unlocked: _elite),
  Achievement(
      id: 'boss',
      title: 'Boss Slayer',
      description: 'Defeat the weekly boss',
      icon: Icons.shield_rounded,
      rarity: 'legendary',
      unlocked: _boss),
];

bool _firstStep(AppState s) => s.totalXp > 0;
bool _xp100(AppState s) => s.totalXp >= 100;
bool _lvl5(AppState s) => s.level >= 5;
bool _lvl15(AppState s) => s.level >= 15;
bool _streak7(AppState s) => s.bestStreak >= 7;
bool _streak30(AppState s) => s.bestStreak >= 30;
bool _collector(AppState s) => s.habits.length >= 5;
bool _perfect(AppState s) =>
    s.habits.isNotEmpty && s.doneTodayCount == s.habits.length;
bool _elite(AppState s) => s.victory().score >= 90;
bool _boss(AppState s) => s.perfectDaysThisWeek() >= kBossGoal;

// ── Companions — ported from lib/companion.ts ───────────────────────────────
class CompanionDef {
  const CompanionDef(this.type, this.name, this.tagline, this.color, this.icon,
      this.unlockLevel);
  final String type;
  final String name;
  final String tagline;
  final Color color;
  final IconData icon;
  final int unlockLevel;
  String get imageAsset => 'assets/companions/$type.png';
}

const List<CompanionDef> kCompanions = [
  CompanionDef('drone', 'Unit-7', 'Mechanical · Precise', Color(0xFF00D4FF),
      Icons.smart_toy_rounded, 1),
  CompanionDef('wolf', 'Fenrir', 'Primal · Instinct-Driven', Color(0xFFA855F7),
      Icons.pets_rounded, 1),
  CompanionDef('phoenix', 'Ember', 'Rebirth · Prestige-Aligned',
      Color(0xFFFF6B35), Icons.local_fire_department_rounded, 1),
  CompanionDef('ghost', 'Shade', 'Minimal · Silent', Color(0xFFF0E6FF),
      Icons.blur_on_rounded, 1),
  CompanionDef('lynx', 'Nyx', 'Stealthy · Precise', Color(0xFF10B981),
      Icons.nightlight_round, 10),
  CompanionDef('titan', 'Ironclad', 'Unwavering · Iron-Willed',
      Color(0xFFF59E0B), Icons.shield_rounded, 15),
  CompanionDef('serpent', 'Vex', 'Calculated · Cold', Color(0xFF22C55E),
      Icons.waves_rounded, 20),
  CompanionDef('dragon', 'Kael', 'Ancient · Legendary', Color(0xFFDC2626),
      Icons.whatshot_rounded, 30),
  CompanionDef('specter', 'Revenant', 'Relentless · Undying', Color(0xFF7C3AED),
      Icons.visibility_off_rounded, 50),
  CompanionDef('wraith', 'Void', 'Mythic · Transcendent', Color(0xFFF472B6),
      Icons.auto_awesome_rounded, 75),
];

CompanionDef companionByType(String t) =>
    kCompanions.firstWhere((c) => c.type == t, orElse: () => kCompanions.first);

// ── Cosmetic classes (player identity; flavor only, never affects rewards) ──
class ClassDef {
  const ClassDef(this.id, this.name, this.tagline, this.emoji, this.color);
  final String id;
  final String name;
  final String tagline;
  final String emoji;
  final Color color;
}

const List<ClassDef> kClasses = [
  ClassDef('wanderer', 'Wanderer', 'Your own path — no label needed', '🧭',
      Color(0xFF94A3B8)),
  ClassDef('warrior', 'Warrior', 'Discipline through sheer will', '⚔️',
      Color(0xFFF59E0B)),
  ClassDef('mage', 'Mage', 'Progress through deep focus', '🔮',
      Color(0xFFA855F7)),
  ClassDef('ranger', 'Ranger', 'Steady and consistent in the wild', '🏹',
      Color(0xFF10B981)),
  ClassDef('healer', 'Healer', 'Growth through self-care', '✨',
      Color(0xFF22D3EE)),
  ClassDef('rogue', 'Rogue', 'Momentum from the shadows', '🗡️',
      Color(0xFF64748B)),
  ClassDef('monk', 'Monk', 'Calm, deliberate reps', '🧘', Color(0xFFFBBF24)),
];

ClassDef classById(String id) =>
    kClasses.firstWhere((c) => c.id == id, orElse: () => kClasses.first);

// ── Premium companion cosmetics (skins + accessories; purely visual) ────────
class CompanionSkin {
  const CompanionSkin(this.id, this.name, this.color);
  final String id;
  final String name;
  final Color color; // glow tint; 'classic' falls back to the companion's own
}

const List<CompanionSkin> kCompanionSkins = [
  CompanionSkin('classic', 'Classic', Color(0x00000000)),
  CompanionSkin('aqua', 'Aqua', Color(0xFF22D3EE)),
  CompanionSkin('violet', 'Violet', Color(0xFFA855F7)),
  CompanionSkin('ember', 'Ember', Color(0xFFFF6B35)),
  CompanionSkin('gold', 'Gold', Color(0xFFFBBF24)),
  CompanionSkin('mint', 'Mint', Color(0xFF34D399)),
  CompanionSkin('rose', 'Rose', Color(0xFFF472B6)),
];

CompanionSkin companionSkinById(String id) => kCompanionSkins
    .firstWhere((s) => s.id == id, orElse: () => kCompanionSkins.first);

/// The glow colour for a companion given the chosen skin ('classic' = native).
Color companionGlowColor(String skinId, Color native) =>
    skinId == 'classic' ? native : companionSkinById(skinId).color;

class CompanionAccessory {
  const CompanionAccessory(this.id, this.name, this.emoji);
  final String id;
  final String name;
  final String emoji; // '' = none
}

const List<CompanionAccessory> kCompanionAccessories = [
  CompanionAccessory('none', 'None', ''),
  CompanionAccessory('crown', 'Crown', '👑'),
  CompanionAccessory('tophat', 'Top hat', '🎩'),
  CompanionAccessory('star', 'Star', '⭐'),
  CompanionAccessory('shades', 'Shades', '🕶️'),
  CompanionAccessory('bow', 'Bow', '🎀'),
  CompanionAccessory('sparkle', 'Sparkle', '✨'),
];

CompanionAccessory companionAccessoryById(String id) => kCompanionAccessories
    .firstWhere((a) => a.id == id, orElse: () => kCompanionAccessories.first);

/// A companion stage: reached at [minLevel], with a look that builds on the
/// one before (drawn by _EvolutionAura in main.dart).
class CompanionStageDef {
  const CompanionStageDef(this.name, this.minLevel, this.look);
  final String name;
  final int minLevel;
  final String look; // what it gains, e.g. "orbiting sparks"
}

const List<CompanionStageDef> kCompanionStages = [
  CompanionStageDef('Hatchling', 1, 'its first form'),
  CompanionStageDef('Bonded', 10, 'a soft aura'),
  CompanionStageDef('Awakened', 25, 'orbiting sparks'),
  CompanionStageDef('Ascended', 50, 'twin golden rings'),
  CompanionStageDef('Mythic', 75, 'a prismatic halo'),
];

int companionStage(int level) =>
    kCompanionStages.lastIndexWhere((st) => level >= st.minLevel).clamp(0, 4);

const Map<String, Map<String, String>> kCompanionLines = {
  'drone': {
    'elite_day': 'Peak output logged. Elite day confirmed.',
    'boss_defeat': 'Target neutralized. Threat: zero.',
    'streak_7': 'Seven-day streak. This unit approves.',
    'streak_30': 'Thirty days logged. Reliability: high.',
    'level_up': 'Upgrade installed. Recalibrating.',
    'prestige': 'Full reset. Parameters improved.',
    'challenge_done': 'Challenge complete. Objective met.',
    'reminder': 'Scheduled task due. Awaiting your input.',
    'streak_risk': 'Streak integrity at risk. Action advised.',
    'comeback': 'Systems idle. Ready when you are.',
    'evolve': 'Evolution complete. New systems online.',
  },
  'wolf': {
    'elite_day': 'The pack feasts tonight.',
    'boss_defeat': 'The prey falls. The hunt ends.',
    'streak_7': 'Seven days. The trail stays warm.',
    'streak_30': 'Thirty days. You are the hunt now.',
    'level_up': 'Stronger. The forest knows.',
    'prestige': 'Reborn — wilder than before.',
    'challenge_done': 'The long hunt is won.',
    'reminder': 'The hunt starts now.',
    'streak_risk': 'The trail goes cold at midnight.',
    'comeback': 'The pack is waiting for you.',
    'evolve': 'I feel the wild growing stronger.',
  },
  'phoenix': {
    'elite_day': 'You burned bright today.',
    'boss_defeat': 'Only ashes remain.',
    'streak_7': 'Seven days of flame.',
    'streak_30': 'A month, still burning.',
    'level_up': 'Rising, warmer than before.',
    'prestige': 'From the ashes. Again.',
    'challenge_done': 'You walked through fire — and won.',
    'reminder': 'Time to light the spark.',
    'streak_risk': 'Your flame burns out at midnight.',
    'comeback': 'Every fire starts with one spark.',
    'evolve': 'Burning brighter than ever.',
  },
  'ghost': {
    'elite_day': '…perfect.',
    'boss_defeat': 'Gone.',
    'streak_7': 'Still here. …good.',
    'streak_30': 'A month. …noticed.',
    'level_up': 'Mm. Higher.',
    'prestige': '…again.',
    'challenge_done': 'Done. …quietly.',
    'reminder': '…it\'s time.',
    'streak_risk': '…midnight. Don\'t let it fade.',
    'comeback': '…still here.',
    'evolve': '…I feel… more.',
  },
  'lynx': {
    'elite_day': 'Clean execution. No trace.',
    'boss_defeat': 'It never saw me coming.',
    'streak_7': 'Seven days in the shadows.',
    'streak_30': 'A month unseen. Unstoppable.',
    'level_up': 'Sharper now.',
    'prestige': 'A new skin. Same silence.',
    'challenge_done': 'Target met. Quietly.',
    'reminder': 'Move now. Quietly.',
    'streak_risk': 'One slip and the trail is lost.',
    'comeback': 'The shadows kept your place.',
    'evolve': 'Sharper eyes. Quieter steps.',
  },
  'titan': {
    'elite_day': 'Discipline wins wars.',
    'boss_defeat': 'It was never a contest.',
    'streak_7': 'Seven days. The wall holds.',
    'streak_30': 'Thirty days of iron.',
    'level_up': 'Forged harder.',
    'prestige': 'Reborn. Unbroken.',
    'challenge_done': 'Held the line to the end.',
    'reminder': 'Discipline calls. Answer it.',
    'streak_risk': 'Hold the wall. It falls at midnight.',
    'comeback': 'Iron rusts. Pick it back up.',
    'evolve': 'Stronger armour. Same resolve.',
  },
  'serpent': {
    'elite_day': 'Precision. Every time.',
    'boss_defeat': 'Cold. Calculated. Done.',
    'streak_7': 'Seven days. The pattern holds.',
    'streak_30': 'Thirty days of control.',
    'level_up': 'Evolved.',
    'prestige': 'Shed the skin. Begin again.',
    'challenge_done': 'The plan unfolded. Precisely.',
    'reminder': 'Right on schedule. Proceed.',
    'streak_risk': 'The pattern breaks at midnight.',
    'comeback': 'Patience. Strike when ready.',
    'evolve': 'A new skin. A sharper mind.',
  },
  'dragon': {
    'elite_day': 'The fire never fades.',
    'boss_defeat': 'Ancient power. Clean victory.',
    'streak_7': 'Seven days. Legends start here.',
    'streak_30': 'Thirty days. The world notices.',
    'level_up': 'Power ascending.',
    'prestige': 'A dragon transforms, never retires.',
    'challenge_done': 'Another legend, earned.',
    'reminder': 'Legends are built today.',
    'streak_risk': 'Your legend dims at midnight.',
    'comeback': 'Even dragons rest. Rise again.',
    'evolve': 'Ancient power, awakened further.',
  },
  'specter': {
    'elite_day': 'You cannot rest. Neither can I.',
    'boss_defeat': 'It ends when I say it ends.',
    'streak_7': 'Seven days. I expected no less.',
    'streak_30': 'Thirty days. Barely enough.',
    'level_up': 'Keep going.',
    'prestige': 'Death is just another level.',
    'challenge_done': 'Finished. On to the next.',
    'reminder': 'No excuses. Now.',
    'streak_risk': 'Midnight takes your streak. Don\'t let it.',
    'comeback': 'Rest is over. Return.',
    'evolve': 'More. I can take more.',
  },
  'wraith': {
    'elite_day': 'The void is satisfied.',
    'boss_defeat': 'All things fall to the void.',
    'streak_7': 'Seven days. The void remembers.',
    'streak_30': 'Thirty days in the abyss.',
    'level_up': 'Ascending beyond.',
    'prestige': 'Transcendence. Again.',
    'challenge_done': 'Consumed, whole. Complete.',
    'reminder': 'The void calls. Answer.',
    'streak_risk': 'The void claims it at midnight.',
    'comeback': 'The void remembers you.',
    'evolve': 'The void deepens.',
  },
};

String companionLine(String type, String trigger) =>
    kCompanionLines[type]?[trigger] ?? '';

// ── Buddy streaks (synced by lib/buddies.dart) ──────────────────────────────
// Two friends keep one streak; it grows on days they both check in.

const int kMaxBuddies = 5;

class Buddy {
  const Buddy({
    required this.id,
    required this.friendId,
    required this.name,
    required this.username,
    this.borderId = 'none',
    this.status = 'active',
    this.incoming = false,
    this.startedOn,
    this.myDays = const {},
    this.theirDays = const {},
  });
  final String id;
  final String friendId;
  final String name;
  final String username;
  final String borderId;
  final String status; // 'pending' (invite sent or received) | 'active'
  final bool incoming; // a pending invite this user received
  final String? startedOn; // dateKey the invite was accepted
  final Set<String> myDays; // this user's check-ins the server knows about
  final Set<String> theirDays; // the buddy's check-ins
  bool get active => status == 'active';
}

/// Days in a row both checked in, counting back from today (or from
/// yesterday while today is still open), never before the streak began.
int buddyStreak(
    Set<String> mine, Set<String> theirs, String? startedOn, DateTime now) {
  if (startedOn == null) return 0;
  bool both(String k) => mine.contains(k) && theirs.contains(k);
  var d = DateTime(now.year, now.month, now.day);
  if (!both(dateKey(d))) d = DateTime(d.year, d.month, d.day - 1);
  var n = 0;
  while (dateKey(d).compareTo(startedOn) >= 0 && both(dateKey(d))) {
    n++;
    d = DateTime(d.year, d.month, d.day - 1);
  }
  return n;
}

// ── Phone notifications (planned here, scheduled by lib/notifications.dart) ──
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.payload,
  });
  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String payload; // 'habit:<id>' (has a "Mark done" button) or 'streak'
  String? get habitId => payload.startsWith('habit:') ? payload.substring(6) : null;
}

/// A content signature for a planned notification: its id plus everything the
/// user would see. Two plans with the same signature need no reschedule.
String notifSig(PlannedNotification p) =>
    '${p.id}|${p.at.millisecondsSinceEpoch}|${p.title}|${p.body}|${p.payload}';

/// A STABLE notification id for a reminder, derived from its identity
/// ([payload] + [day]) rather than its position in the plan. The same reminder
/// keeps the same id across replans and app restarts, so a replan can update or
/// cancel exactly the request that changed — never churn unrelated ones. FNV-1a
/// is used (not String.hashCode) because it's deterministic across runs.
int notifId(String payload, int day) {
  var h = 0x811c9dc5;
  for (final u in '$payload#$day'.codeUnits) {
    h = (h ^ u) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff; // non-negative 31-bit
}

/// iOS keeps only the 64 most recently scheduled notifications.
const int kMaxPlannedNotifications = 60;

/// Habit reminders reach a week ahead, so they still arrive if the app isn't
/// opened, then stop instead of nagging forever.
const int kReminderDaysAhead = 7;

/// Every notification to schedule from [now]: habit reminders at each habit's
/// reminder time, and a streak alert before an open streak breaks. Completing
/// a habit replans, which drops its reminder and any alert it settles.
List<PlannedNotification> planNotifications(AppState s, DateTime now,
    {List<Buddy> buddies = const []}) {
  final out = <PlannedNotification>[];
  final c = companionByType(s.activeCompanion);
  String voice(String trigger) => '${c.name}: ${companionLine(c.type, trigger)}';
  DateTime at(int day, int minutes) =>
      DateTime(now.year, now.month, now.day + day, minutes ~/ 60, minutes % 60);
  String key(int day) => dateKey(DateTime(now.year, now.month, now.day + day));
  final today = key(0), yesterday = key(-1);
  bool doneToday(Habit h) => h.lastCompletedDate == today;

  // Today for streaks still open; tomorrow for the ones kept today. Later days
  // can't be at risk: by then the streak is either kept or already gone.
  // One alert a day covers both a habit streak and a buddy streak.
  if (s.streakAlertOn) {
    final checkedIn = s.activeDays;
    for (final day in [0, 1]) {
      final t = at(day, s.streakAlertMinutes);
      if (!t.isAfter(now)) continue;
      final atRisk = s.restDays.contains(key(day))
          ? const <Habit>[]
          : s.habits
              .where((h) => day == 0
                  ? !doneToday(h) && h.lastCompletedDate == yesterday
                  : doneToday(h))
              .where((h) => h.streak >= 2)
              .toList();
      final top = atRisk.isEmpty ? 0 : atRisk.map((h) => h.streak).reduce(max);
      // A buddy streak is open today until this user checks in; tomorrow's
      // is at risk once both kept it today.
      Buddy? buddy;
      var buddyTop = 0;
      for (final b in buddies.where((b) => b.active)) {
        final mine = {...checkedIn, ...b.myDays};
        final n = buddyStreak(mine, b.theirDays, b.startedOn, now);
        final open = day == 0
            ? !mine.contains(today)
            : mine.contains(today) && b.theirDays.contains(today);
        if (open && n >= 2 && n > buddyTop) (buddy, buddyTop) = (b, n);
      }
      if (top == 0 && buddy == null) continue;
      final buddyFirst = buddy != null && buddyTop > top;
      final left = s.habits.where((h) => !doneToday(h)).length;
      out.add(PlannedNotification(
        id: notifId('streak', day),
        at: t,
        title: buddyFirst
            ? '🔥 Your $buddyTop-day buddy streak with ${buddy.name} ends at midnight'
            : '🔥 Your $top-day streak ends at midnight',
        body: [
          voice('streak_risk'),
          if (day == 0 && top > 0) '$left ${left == 1 ? 'habit' : 'habits'} left today.',
          if (buddy != null && !buddyFirst) '${buddy.name} is counting on you too.',
          if (buddy != null && buddyFirst && day == 0 && buddy.theirDays.contains(today))
            '${buddy.name} already checked in.',
        ].join(' '),
        payload: 'streak',
      ));
    }
  }

  if (s.remindersOn) {
    final timed = s.habits.where((h) => h.reminderMinutes != null).toList();
    final days = timed.isEmpty
        ? 0
        : ((kMaxPlannedNotifications - out.length) ~/ timed.length)
            .clamp(1, kReminderDaysAhead);
    for (var day = 0; day < days; day++) {
      for (final h in timed) {
        final t = at(day, h.reminderMinutes!);
        if (!t.isAfter(now) || (day == 0 && doneToday(h))) continue;
        // The streak this check-off keeps, while it's still known.
        final streak = (day == 0 && h.lastCompletedDate == yesterday) ||
                (day == 1 && doneToday(h))
            ? h.streak
            : 0;
        out.add(PlannedNotification(
          id: notifId('habit:${h.id}', day),
          at: t,
          title: h.icon.isEmpty ? h.name : '${h.icon} ${h.name}',
          // Two days without opening the app: a welcome back, not a nag.
          body: day >= 2
              ? voice('comeback')
              : streak >= 2
                  ? '${voice('reminder')} Keep your $streak-day streak going.'
                  : voice('reminder'),
          payload: 'habit:${h.id}',
        ));
      }
    }
  }

  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > kMaxPlannedNotifications
      ? out.sublist(0, kMaxPlannedNotifications)
      : out;
}

/// The outcome of a routine replan: which requests to (re)schedule, which to
/// cancel, the resulting live map (id -> signature) to remember, and the plan's
/// signature.
class ReplanDecision {
  const ReplanDecision(
      this.toSchedule, this.toCancel, this.live, this.signature);
  final List<PlannedNotification> toSchedule;
  final List<int> toCancel;
  final Map<int, String> live;
  final String signature;
}

/// Reconcile what the OS currently holds ([live]: stable id -> signature) with a
/// freshly computed [desired] plan as of [now], touching only what actually
/// changed:
///  • an UNCHANGED request is left exactly as-is — including one due within the
///    next few seconds, which must still fire. (The old "cancel everything then
///    reschedule" dropped a reminder due at 18:00 when a replan ran at 17:59:57.)
///  • a request whose reminder CHANGED is rescheduled under its stable id,
///    replacing — never duplicating — the old one;
///  • a request whose reminder is GONE (completed, retimed, disabled) is cancelled;
///  • a brand-new request due too soon to schedule reliably ([now] + 5s) is
///    skipped (the OS rejects a near-past time) but never cancels/duplicates an
///    existing one;
///  • at most [maxPending] soonest requests, to respect the OS limit.
ReplanDecision planReplan({
  required List<PlannedNotification> desired,
  required Map<int, String> live,
  required DateTime now,
  int maxPending = kMaxPlannedNotifications,
}) {
  final soon = now.add(const Duration(seconds: 5));
  final capped = ([...desired]..sort((a, b) => a.at.compareTo(b.at)))
      .take(maxPending)
      .toList();
  final desiredById = {for (final p in capped) p.id: p};
  final newLive = <int, String>{};
  final toSchedule = <PlannedNotification>[];
  final toCancel = <int>[];

  // Cancel only requests whose reminder is no longer in the plan.
  for (final id in live.keys) {
    if (!desiredById.containsKey(id)) toCancel.add(id);
  }
  for (final p in capped) {
    final s = notifSig(p);
    if (live[p.id] == s) {
      newLive[p.id] = s; // unchanged — keep it, even if it's imminent
      continue;
    }
    if (!p.at.isAfter(soon)) {
      // Too soon to (re)schedule reliably. Keep any existing request as-is so a
      // valid imminent reminder still fires; never duplicate or cancel it.
      if (live.containsKey(p.id)) newLive[p.id] = live[p.id]!;
      continue;
    }
    toSchedule.add(p); // new or changed, and far enough out to schedule
    newLive[p.id] = s;
  }
  return ReplanDecision(
      toSchedule, toCancel, newLive, capped.map(notifSig).join('\n'));
}

// ── Co-op quests (shared party boss goals) ──────────────────────────────────
class CoopQuestDef {
  const CoopQuestDef(this.id, this.name, this.emoji, this.target, this.reward);
  final String id;
  final String name; // boss name
  final String emoji;
  final int target; // combined party XP to defeat it
  final int reward; // coins each member claims on defeat
}

const List<CoopQuestDef> kCoopQuests = [
  CoopQuestDef('sloth', 'The Sloth Warden', '🦥', 500, 60),
  CoopQuestDef('hydra', 'Procrastination Hydra', '🐉', 1500, 120),
  CoopQuestDef('golem', 'Doubt Golem', '🗿', 3000, 200),
  CoopQuestDef('leviathan', 'The Burnout Leviathan', '🐋', 6000, 350),
];

CoopQuestDef? coopQuestById(String id) {
  for (final q in kCoopQuests) {
    if (q.id == id) return q;
  }
  return null;
}
