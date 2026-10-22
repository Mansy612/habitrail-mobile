import 'dart:convert';

import 'package:http/http.dart' as http;

import 'core.dart';

// ── AI difficulty rating via a local Ollama model ───────────────────────────
//
// When the user adds a habit, a local LLM (Ollama, running on their machine)
// *reads* the habit and classifies how hard it is. That classification maps to
// a fixed XP multiplier via [rarityConfig] — the model only ever picks a tier,
// it never invents a number, and the chosen tier is frozen onto the habit at
// creation. Awarding XP later (see AppState.toggle) just reads that stored
// tier, so no model is ever in the reward path: ratings stay deterministic and
// the app works fully offline (it falls back to the keyword heuristic whenever
// Ollama isn't reachable — not installed, offline, or a real iPhone later).

/// Difficulty tiers the AI may choose, easiest → hardest. Each maps 1:1 to a
/// key in [rarityConfig], whose `mult` is the XP multiplier.
const List<String> kDifficultyTiers = [
  'common',
  'rare',
  'epic',
  'legendary',
  'mythic',
];

/// A frozen difficulty decision for one habit.
class DifficultyVerdict {
  const DifficultyVerdict(this.rarity, this.reason, {this.fromAi = false});

  final String rarity; // one of [kDifficultyTiers]
  final String reason; // short, human-readable "why this tier"
  final bool fromAi; // true = a model read it; false = local heuristic

  double get multiplier => rarityConfig[rarity]?.mult ?? 1.0;
  String get label => rarityConfig[rarity]?.label ?? rarity;
}

/// Instant, offline difficulty guess from the keyword heuristic ([inferRarity]).
DifficultyVerdict heuristicVerdict(String name) {
  final rarity = inferRarity(name);
  return DifficultyVerdict(rarity, _tierReason(rarity), fromAi: false);
}

String _tierReason(String rarity) {
  switch (rarity) {
    case 'mythic':
      return 'Extreme, elite effort';
    case 'legendary':
      return 'Hard & demanding';
    case 'epic':
      return 'Takes real discipline';
    case 'rare':
      return 'A light, steady effort';
    default:
      return 'Quick & easy';
  }
}

/// Parses the JSON an Ollama chat response carries in `message.content`.
/// Returns null when the tier is missing/unknown so the caller can fall back.
DifficultyVerdict? parseOllamaVerdict(String content) {
  dynamic data;
  try {
    data = jsonDecode(content);
  } catch (_) {
    return null;
  }
  if (data is! Map) return null;
  final rawTier =
      (data['tier'] ?? data['difficulty'] ?? data['rarity'])?.toString();
  final tier = _canonicalTier(rawTier?.trim().toLowerCase() ?? '');
  if (tier == null) return null;
  var reason = (data['reason'] ?? data['why'] ?? '').toString().trim();
  if (reason.length > 60) reason = '${reason.substring(0, 57)}…';
  if (reason.isEmpty) reason = _tierReason(tier);
  return DifficultyVerdict(tier, reason, fromAi: true);
}

/// Accepts our exact tier names, plus common words a small model may emit.
String? _canonicalTier(String raw) {
  if (raw.isEmpty) return null;
  if (kDifficultyTiers.contains(raw)) return raw;
  const synonyms = {
    'trivial': 'common',
    'easy': 'common',
    'simple': 'common',
    'minimal': 'common',
    'light': 'rare',
    'moderate': 'epic',
    'medium': 'epic',
    'hard': 'legendary',
    'difficult': 'legendary',
    'challenging': 'legendary',
    'intense': 'legendary',
    'extreme': 'mythic',
    'elite': 'mythic',
    'insane': 'mythic',
  };
  return synonyms[raw];
}

const String _systemPrompt =
    'You rate how demanding a personal habit is, for a habit tracker\'s XP '
    'reward. Reply with ONLY a JSON object of the form '
    '{"tier": "<common|rare|epic|legendary|mythic>", "reason": "<max 6 words>"}.\n'
    'Tiers by effort:\n'
    '- common: trivial, seconds of effort (make bed, take vitamins, drink water).\n'
    '- rare: a light daily routine (read, short walk, tidy up, journal).\n'
    '- epic: real effort or focus (workout, study, code, meditate 20 min).\n'
    '- legendary: hard, demanding, or big discipline (long run, cold plunge, deep work, quit sugar).\n'
    '- mythic: extreme or elite feats (marathon, multi-hour training, ultra challenges).\n'
    'Judge the effort it takes, not how healthy or good the habit is. Harder means a higher tier.';

/// Classifies [name] with Ollama when [enabled]; otherwise (or on any error,
/// timeout, or unreachable server) returns the instant heuristic verdict.
Future<DifficultyVerdict> classifyDifficulty(
  String name, {
  required bool enabled,
  required String baseUrl,
  required String model,
  Duration timeout = const Duration(seconds: 20),
  http.Client? client,
}) async {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return const DifficultyVerdict('common', 'Quick & easy');
  if (!enabled) return heuristicVerdict(trimmed);

  final http.Client c = client ?? http.Client();
  try {
    final res = await c
        .post(
          Uri.parse('${_root(baseUrl)}/api/chat'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model.trim().isEmpty ? kDefaultAiModel : model.trim(),
            'stream': false,
            'format': 'json',
            'options': {'temperature': 0},
            'messages': [
              {'role': 'system', 'content': _systemPrompt},
              {'role': 'user', 'content': 'Habit: "$trimmed"'},
            ],
          }),
        )
        .timeout(timeout);
    if (res.statusCode != 200) return heuristicVerdict(trimmed);
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final content = (body is Map && body['message'] is Map)
        ? (body['message']['content'] ?? '').toString()
        : '';
    return parseOllamaVerdict(content) ?? heuristicVerdict(trimmed);
  } catch (_) {
    return heuristicVerdict(trimmed);
  } finally {
    if (client == null) c.close();
  }
}

/// Pings the Ollama server and reports whether [model] is installed.
Future<({bool ok, String message})> testOllama(
    String baseUrl, String model) async {
  try {
    final res = await http
        .get(Uri.parse('${_root(baseUrl)}/api/tags'))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      return (ok: false, message: 'Server responded ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final models = (body is Map && body['models'] is List)
        ? (body['models'] as List)
            .map((m) => m is Map ? (m['name']?.toString() ?? '') : '')
            .where((s) => s.isNotEmpty)
            .toList()
        : <String>[];
    final want = model.trim().isEmpty ? kDefaultAiModel : model.trim();
    final hasModel = models.any((m) => m == want || m.startsWith('$want:'));
    if (models.isEmpty) {
      return (ok: true, message: 'Connected — no models yet. Run: ollama pull $want');
    }
    if (!hasModel) {
      return (ok: true, message: 'Connected — "$want" missing. Run: ollama pull $want');
    }
    return (ok: true, message: 'Connected · "$want" ready (${models.length} models)');
  } catch (_) {
    return (ok: false, message: 'Not reachable — is Ollama running?');
  }
}

String _root(String url) {
  var u = url.trim();
  if (u.isEmpty) u = kDefaultAiBaseUrl;
  if (!u.startsWith('http')) u = 'http://$u';
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

// ── AI nutrition estimation (Ollama) ────────────────────────────────────────
//
// The user types what they ate in plain English and the local model estimates
// the macros for the whole meal. The result just pre-fills the Log-food form —
// the user can adjust every number before saving — so nothing here is in a
// reward path, and when Ollama isn't reachable the form stays fully manual.

class NutritionEstimate {
  const NutritionEstimate({
    required this.name,
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    this.fromAi = true,
  });
  final String name;
  final double calories;
  final double protein;
  final double carbs;
  final double fat;
  final bool fromAi;
}

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) {
    return double.tryParse(v.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;
  }
  return 0;
}

/// Parses the JSON Ollama returns for a meal. Null when there are no usable
/// numbers (all zero or unparseable) so the caller falls back to manual entry.
NutritionEstimate? parseNutritionJson(String content, {String fallbackName = ''}) {
  dynamic data;
  try {
    data = jsonDecode(content);
  } catch (_) {
    return null;
  }
  if (data is! Map) return null;
  double field(List<String> keys) {
    for (final k in keys) {
      if (data[k] != null) return _num(data[k]).clamp(0, 100000).toDouble();
    }
    return 0;
  }

  final cal = field(['calories', 'kcal', 'cal']);
  final protein = field(['protein', 'protein_g', 'proteins']);
  final carbs = field(['carbs', 'carbohydrates', 'carbs_g']);
  final fat = field(['fat', 'fat_g', 'fats']);
  if (cal == 0 && protein == 0 && carbs == 0 && fat == 0) return null;
  var name = (data['name'] ?? data['food'] ?? data['label'] ?? fallbackName)
      .toString()
      .trim();
  if (name.isEmpty) name = fallbackName.trim();
  if (name.length > 40) name = '${name.substring(0, 39)}…';
  return NutritionEstimate(
    name: name.isEmpty ? 'Meal' : name,
    calories: cal,
    protein: protein,
    carbs: carbs,
    fat: fat,
  );
}

const String _nutritionSystemPrompt =
    'You estimate nutrition for a habit tracker. Given a free-text description '
    'of what someone ate, reply with ONLY a JSON object of the form '
    '{"name": "<short label>", "calories": <kcal>, "protein": <grams>, '
    '"carbs": <grams>, "fat": <grams>}. Sum ALL items in the description and '
    'account for the quantities given. Use realistic typical values. The macro '
    'values are plain numbers with no units.';

/// Estimates macros for [description] via Ollama; null when AI is off, the
/// input is empty, the server is unreachable/times out, or nothing usable
/// comes back (the caller then lets the user enter macros by hand).
Future<NutritionEstimate?> estimateNutrition(
  String description, {
  required bool enabled,
  required String baseUrl,
  required String model,
  Duration timeout = const Duration(seconds: 25),
  http.Client? client,
}) async {
  final trimmed = description.trim();
  if (!enabled || trimmed.isEmpty) return null;
  final http.Client c = client ?? http.Client();
  try {
    final res = await c
        .post(
          Uri.parse('${_root(baseUrl)}/api/chat'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model.trim().isEmpty ? kDefaultAiModel : model.trim(),
            'stream': false,
            'format': 'json',
            'options': {'temperature': 0},
            'messages': [
              {'role': 'system', 'content': _nutritionSystemPrompt},
              {'role': 'user', 'content': 'I ate: $trimmed'},
            ],
          }),
        )
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final content = (body is Map && body['message'] is Map)
        ? (body['message']['content'] ?? '').toString()
        : '';
    return parseNutritionJson(content, fallbackName: trimmed);
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
