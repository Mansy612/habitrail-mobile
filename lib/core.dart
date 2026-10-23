import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Exact palette from the web app (tailwind.config.ts) ─────────────────────
const kBase = Color(0xFF07040F);
const kElevated = Color(0xD9221445); // translucent glass (secondary surface)
const kCard = Color(0xCC1A0F34); // translucent glass (primary surface)
const kSurfacePrimary = Color(0xFF0B0420);
const kBorder = Color(0x26FFFFFF); // luminous glass edge (white ~15%)
// Accent trio — mutable so appearance themes can swap them at runtime.
Color kPlasma = const Color(0xFF8B5CF6);
Color kPlasmaBright = const Color(0xFFA78BFA);
Color kPlasmaGlow = const Color(0xFFC4B5FD);
const kCyan = Color(0xFF22D3EE);
const kGold = Color(0xFFFBBF24);
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
  AppThemeDef('violet', 'Habitrail Violet', Color(0xFF8B5CF6), Color(0xFFA78BFA),
      Color(0xFFC4B5FD)),
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
];

AppThemeDef themeById(String id) =>
    kThemes.firstWhere((t) => t.id == id, orElse: () => kThemes.first);

void applyThemeColors(String id) {
  final t = themeById(id);
  kPlasma = t.accent;
  kPlasmaBright = t.bright;
  kPlasmaGlow = t.glow;
}

// ── Cosmetics: profile-picture borders (bought in the Shop) ─────────────────
class BorderDef {
  const BorderDef(this.id, this.name, this.cost, this.colors, {this.glow = false});
  final String id;
  final String name;
  final int cost;
  final List<Color> colors; // 1 color = solid ring, 2+ = gradient
  final bool glow;
}

const List<BorderDef> kBorders = [
  BorderDef('none', 'Simple', 0, [Color(0x4DFFFFFF)]),
  BorderDef('cyan', 'Cyan Pulse', 120, [Color(0xFF3DE7FF)], glow: true),
  BorderDef('gold', 'Gold', 180, [Color(0xFFFFD23F)], glow: true),
  BorderDef('violet', 'Violet', 180, [Color(0xFFC08BFF)], glow: true),
  BorderDef('crimson', 'Crimson', 220, [Color(0xFFFF6B8A)], glow: true),
  BorderDef('aurora', 'Aurora', 400,
      [Color(0xFF3DE7FF), Color(0xFFB06BFF), Color(0xFFFF7AD1)], glow: true),
  BorderDef('prism', 'Prismatic', 700, [
    Color(0xFFFF6B8A),
    Color(0xFFFFD23F),
    Color(0xFF4ADE80),
    Color(0xFF3DE7FF),
    Color(0xFFB06BFF)
  ], glow: true),
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
  Reflection({required this.date, required this.text});
  final String date;
  final String text;
  Map<String, dynamic> toMap() => {'date': date, 'text': text};
  factory Reflection.fromMap(Map<String, dynamic> m) =>
      Reflection(date: m['date'] as String, text: m['text'] as String);
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
        (p.gender == 'male' ? 5 : -161))
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
const kPrestigeMinLevel = 10; // mobile threshold (web gates prestige higher)

// ── Shared app state ─────────────────────────────────────────────────────────
class AppState extends ChangeNotifier {
  static const _habitsKey = 'habitrail.habits.v1';
  static const _metaKey = 'habitrail.meta.v2';
  static const _journalKey = 'habitrail.journal.v1';
  static const _foodKey = 'habitrail.food.v1';
  static const _milestoneKey = 'habitrail.milestones.v1';

  final List<Habit> habits = [];
  final List<Reflection> reflections = [];
  final List<FoodEntry> foodLog = [];
  int totalXp = 0;
  int coins = 100;
  bool loading = true;

  // Economy layer
  int focusMinutesToday = 0;
  String focusDateKey = '';
  final Set<String> perfectDays = {};
  bool bossRewarded = false;
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
  int totalBossDefeats = 0;
  int highestLevel = 1;
  int _prevLevel = 1;
  String displayName = 'Player';
  String lastBriefingDate = '';
  String themeId = 'violet';
  final Map<String, int> dailyScore = {}; // dateKey -> victory score
  int streakShields = 0;
  String? xpBoostDate; // 2x XP active while this == today
  // AI difficulty rating (local Ollama) — see lib/ai.dart.
  bool aiEnabled = true;
  String aiBaseUrl = kDefaultAiBaseUrl;
  String aiModel = kDefaultAiModel;
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
  int get bestStreak =>
      habits.isEmpty ? 0 : habits.map((h) => h.streak).reduce(max);
  int get totalPerfectDays => perfectDays.length;

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
    if (!ownedThemes.contains(id)) return; // must own it (buy in the Shop)
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

  void resetAll() {
    habits
      ..clear()
      ..addAll(_seedHabits());
    reflections.clear();
    foodLog.clear();
    milestoneLog.clear();
    perfectDays.clear();
    questClaimedIds.clear();
    earnedAchievements.clear();
    totalXp = 0;
    coins = 100;
    focusMinutesToday = 0;
    focusDateKey = '';
    bossRewarded = false;
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
    _prevLevel = 1;
    activeCompanion = 'drone';
    lastCompanionLine = '';
    pfpBase64 = '';
    pfpBytes = null;
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
  /// leaves alone, so nothing from a previous user or guest session remains.
  void startFreshForAccount(String name) {
    resetAll();
    dailyScore.clear();
    streakShields = 0;
    xpBoostDate = null;
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

  int perfectDaysThisWeek() {
    final now = DateTime.now();
    int c = 0;
    for (int i = 0; i < 7; i++) {
      if (perfectDays.contains(dateKey(now.subtract(Duration(days: i))))) c++;
    }
    return c;
  }

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
      bossRewarded = (m['bossRewarded'] as bool?) ?? false;
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
      displayName = (m['displayName'] as String?) ?? 'Player';
      lastBriefingDate = (m['lastBriefingDate'] as String?) ?? '';
      themeId = (m['themeId'] as String?) ?? 'violet';
      final ds = m['dailyScore'];
      if (ds is Map) {
        dailyScore.clear();
        ds.forEach((k, v) => dailyScore[k as String] = (v as num).toInt());
      }
      streakShields = (m['streakShields'] as int?) ?? 0;
      xpBoostDate = m['xpBoostDate'] as String?;
      aiEnabled = (m['aiEnabled'] as bool?) ?? true;
      aiBaseUrl = (m['aiBaseUrl'] as String?) ?? kDefaultAiBaseUrl;
      aiModel = (m['aiModel'] as String?) ?? kDefaultAiModel;
      earnedAchievements.addAll(
          ((m['earnedAchievements'] as List?) ?? const []).map((e) => e as String));
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
    _prevLevel = level;
    if (level > highestLevel) highestLevel = level;
    _checkAchievements(silent: true); // backfill anything already satisfied
    loading = false;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _habitsKey, jsonEncode(habits.map((h) => h.toMap()).toList()));
    await prefs.setString(
        _journalKey, jsonEncode(reflections.map((r) => r.toMap()).toList()));
    await prefs.setString(
        _foodKey, jsonEncode(foodLog.map((e) => e.toMap()).toList()));
    await prefs.setString(
        _milestoneKey, jsonEncode(milestoneLog.map((e) => e.toMap()).toList()));
    await prefs.setString(
        _metaKey,
        jsonEncode({
          'totalXp': totalXp,
          'coins': coins,
          'focusMinutesToday': focusMinutesToday,
          'focusDateKey': focusDateKey,
          'bossRewarded': bossRewarded,
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
          'displayName': displayName,
          'lastBriefingDate': lastBriefingDate,
          'themeId': themeId,
          'dailyScore': dailyScore,
          'streakShields': streakShields,
          'xpBoostDate': xpBoostDate,
          'aiEnabled': aiEnabled,
          'aiBaseUrl': aiBaseUrl,
          'aiModel': aiModel,
          'earnedAchievements': earnedAchievements.toList(),
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

  // Returns the achievements earned since the last call, then clears the queue
  // so each unlock is only celebrated once.
  List<Achievement> consumeNewAchievements() {
    if (_pendingAchievements.isEmpty) return const [];
    final ids = _pendingAchievements.toList();
    _pendingAchievements.clear();
    return kAchievements.where((a) => ids.contains(a.id)).toList();
  }

  void _updateBoss() {
    final count = perfectDaysThisWeek();
    if (count >= kBossGoal && !bossRewarded) {
      totalXp += kBossXp;
      coins += kBossCoins;
      bossRewarded = true;
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
    if (count < kBossGoal) bossRewarded = false;
  }

  bool get canPrestige => level >= kPrestigeMinLevel;

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
      h.todayAwardXp = 0;
      h.streak = h.streak > 0 ? h.streak - 1 : 0;
      h.lastCompletedDate = h.streak > 0 ? yesterday : null;
    } else {
      if (h.lastCompletedDate == yesterday) {
        h.streak += 1;
      } else if (h.lastCompletedDate != null && streakShields > 0) {
        h.streak += 1; // streak shield bridges a missed day
        streakShields -= 1;
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

  void addReflection(String text) {
    reflections.insert(
        0, Reflection(date: dateKey(DateTime.now()), text: text));
    totalXp += 20;
    coins += 4;
    _afterAction();
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

int companionStage(int level) {
  if (level >= 75) return 4;
  if (level >= 50) return 3;
  if (level >= 25) return 2;
  if (level >= 10) return 1;
  return 0;
}

const Map<String, Map<String, String>> kCompanionLines = {
  'drone': {
    'elite_day': 'System performance nominal. Elite Day confirmed.',
    'boss_defeat': 'Target eliminated. Threat level: zero.',
    'streak_7': 'Seven consecutive days. This unit approves.',
    'streak_30': 'Thirty days. Sustained performance logged.',
    'level_up': 'Upgrade detected. Systems recalibrating.',
    'prestige': 'Prestige cycle complete. Awaiting new parameters.',
  },
  'wolf': {
    'elite_day': 'The pack runs tonight.',
    'boss_defeat': 'The hunt ends. The prey falls.',
    'streak_7': 'Seven days. The streak holds.',
    'streak_30': 'Thirty days. You have become the hunt.',
    'level_up': 'Stronger. The forest knows.',
    'prestige': 'Born again. Wilder than before.',
  },
  'phoenix': {
    'elite_day': 'You burned bright today.',
    'boss_defeat': 'The ashes of your enemy.',
    'streak_7': 'Seven days of flame.',
    'streak_30': 'A month. Still burning.',
    'level_up': 'Rising.',
    'prestige': 'From the ashes. Again.',
  },
  'ghost': {
    'elite_day': '.',
    'boss_defeat': '.',
    'streak_7': '.',
    'streak_30': '.',
    'level_up': '.',
    'prestige': '.',
  },
  'lynx': {
    'elite_day': 'Clean execution. No trace.',
    'boss_defeat': 'It never saw me coming.',
    'streak_7': 'Seven days in the shadows.',
    'streak_30': 'A month unseen. Unstoppable.',
    'level_up': 'Sharper.',
    'prestige': 'A ghost in a new skin.',
  },
  'titan': {
    'elite_day': 'Discipline wins wars.',
    'boss_defeat': 'It was never a contest.',
    'streak_7': 'Seven days. The wall holds.',
    'streak_30': 'Thirty days of iron.',
    'level_up': 'Forged harder.',
    'prestige': 'Reborn. Stronger than before.',
  },
  'serpent': {
    'elite_day': 'Precision. Every time.',
    'boss_defeat': 'Cold. Calculated. Done.',
    'streak_7': 'Seven days. The pattern holds.',
    'streak_30': 'Thirty days of control.',
    'level_up': 'Evolved.',
    'prestige': 'Shed the skin. Begin again.',
  },
  'dragon': {
    'elite_day': 'The fire never fades.',
    'boss_defeat': 'Ancient power. Ancient victory.',
    'streak_7': 'Seven days. Legends are built this way.',
    'streak_30': 'Thirty days. The world takes notice.',
    'level_up': 'Power ascending.',
    'prestige': 'A dragon does not retire. It transforms.',
  },
  'specter': {
    'elite_day': 'You cannot rest. Neither can I.',
    'boss_defeat': 'It ends when I say it ends.',
    'streak_7': 'Seven days. I expected nothing less.',
    'streak_30': 'Thirty days. Barely enough.',
    'level_up': 'Keep going.',
    'prestige': 'Death is just another level.',
  },
  'wraith': {
    'elite_day': 'The void is satisfied.',
    'boss_defeat': 'All things fall before the void.',
    'streak_7': 'Seven days. The void remembers.',
    'streak_30': 'Thirty days in the abyss.',
    'level_up': 'Ascending beyond.',
    'prestige': 'Transcendence.',
  },
};

String companionLine(String type, String trigger) =>
    kCompanionLines[type]?[trigger] ?? '';
