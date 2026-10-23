import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart' show isValidUsername;

/// A friend in the social graph. Until a real backend is wired, a friend's
/// progress is synthetic but *deterministic* — derived from their username so
/// the same handle always shows the same stats across launches. Real stats will
/// replace these when cross-device sync lands.
class Friend {
  const Friend({
    required this.id,
    required this.username,
    required this.name,
    required this.totalXp,
    required this.streak,
    required this.prestige,
    required this.borderId,
    this.sample = false,
  });

  final String id;
  final String username;
  final String name;
  final int totalXp;
  final int streak;
  final int prestige;
  final String borderId;
  final bool sample; // true for the seeded demo friends

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'name': name,
        'totalXp': totalXp,
        'streak': streak,
        'prestige': prestige,
        'borderId': borderId,
        'sample': sample,
      };

  factory Friend.fromJson(Map<String, dynamic> m) => Friend(
        id: (m['id'] as String?) ?? 'u0',
        username: (m['username'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        totalXp: (m['totalXp'] as num?)?.toInt() ?? 0,
        streak: (m['streak'] as num?)?.toInt() ?? 0,
        prestige: (m['prestige'] as num?)?.toInt() ?? 0,
        borderId: (m['borderId'] as String?) ?? 'none',
        sample: (m['sample'] as bool?) ?? false,
      );
}

// A small, fully-deterministic string hash (String.hashCode isn't guaranteed
// stable, and we want a friend's stats to be reproducible).
int _hash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

String _prettyName(String username) {
  final base = username.split(RegExp(r'[_0-9]')).firstWhere(
        (p) => p.isNotEmpty,
        orElse: () => username,
      );
  if (base.isEmpty) return username;
  return base[0].toUpperCase() + base.substring(1);
}

const List<String> _borderPool = [
  'none',
  'cyan',
  'gold',
  'violet',
  'crimson',
  'aurora',
  'prism',
];

Friend _synthFriend(String username, {bool sample = false, String? name}) {
  final h = _hash(username.toLowerCase());
  return Friend(
    id: 'u$h',
    username: username,
    name: name ?? _prettyName(username),
    totalXp: 100 + h % 6000,
    streak: (h ~/ 7) % 41,
    prestige: (h % 100) < 12 ? 1 : 0,
    borderId: _borderPool[(h ~/ 13) % _borderPool.length],
    sample: sample,
  );
}

/// On-device friends list (stub). Seeds a few sample friends on first run so the
/// leaderboard feels alive, and persists adds/removes to SharedPreferences.
class FriendsStore extends ChangeNotifier {
  FriendsStore({this.serviceForTest});

  /// Test seam — not used in production.
  final SharedPreferences? serviceForTest;

  static const _key = 'friends_v1';

  final List<Friend> _friends = [];
  bool loaded = false;

  List<Friend> get friends => List.unmodifiable(_friends);

  Future<SharedPreferences> get _prefs async =>
      serviceForTest ?? await SharedPreferences.getInstance();

  Future<void> load() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key);
    if (raw == null) {
      _friends
        ..clear()
        ..addAll(_seed());
      await _save();
    } else {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => Friend.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        _friends
          ..clear()
          ..addAll(list);
      } catch (_) {
        // Corrupt payload — start from the seed rather than crashing.
        _friends
          ..clear()
          ..addAll(_seed());
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await _prefs;
    await prefs.setString(
        _key, jsonEncode(_friends.map((f) => f.toJson()).toList()));
  }

  /// Adds a friend by username. Returns an error string, or null on success.
  String? addByUsername(String username) {
    final u = username.trim();
    if (!isValidUsername(u)) {
      return 'Enter a valid username (3–20 letters, numbers, _).';
    }
    if (_friends.any((f) => f.username.toLowerCase() == u.toLowerCase())) {
      return '@$u is already in your friends.';
    }
    _friends.add(_synthFriend(u));
    _save();
    notifyListeners();
    return null;
  }

  void remove(String id) {
    _friends.removeWhere((f) => f.id == id);
    _save();
    notifyListeners();
  }

  List<Friend> _seed() => [
        _synthFriend('maya', sample: true, name: 'Maya'),
        _synthFriend('leo_fit', sample: true, name: 'Leo'),
        _synthFriend('priya99', sample: true, name: 'Priya'),
        _synthFriend('samski', sample: true, name: 'Sam'),
      ];
}

/// App-wide friends store.
final friends = FriendsStore();
