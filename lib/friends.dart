import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth.dart' show isValidUsername;
import 'backend.dart' as backend;

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

// The app's "known users" — a stand-in for a server's user directory. You can
// only befriend handles listed here; anything else resolves to no user, just
// like a real backend would reject an unknown username.
const List<({String username, String name})> _directory = [
  (username: 'maya', name: 'Maya'),
  (username: 'leo_fit', name: 'Leo'),
  (username: 'priya99', name: 'Priya'),
  (username: 'samski', name: 'Sam'),
  (username: 'nova_x', name: 'Nova'),
  (username: 'kai', name: 'Kai'),
  (username: 'zoe_runs', name: 'Zoe'),
  (username: 'ravi', name: 'Ravi'),
  (username: 'mia_z', name: 'Mia'),
  (username: 'deepwork_dan', name: 'Dan'),
];

({String username, String name})? _lookup(String username) {
  final u = username.toLowerCase();
  for (final d in _directory) {
    if (d.username.toLowerCase() == u) return d;
  }
  return null;
}

Friend _friendFromDir(({String username, String name}) d) =>
    _synthFriend(d.username, sample: true, name: d.name);

/// On-device friends list (stub). Seeds a few sample friends on first run so the
/// leaderboard feels alive, and persists adds/removes to SharedPreferences.
class FriendsStore extends ChangeNotifier {
  FriendsStore({this.serviceForTest});

  /// Test seam — not used in production.
  final SharedPreferences? serviceForTest;

  static const _key = 'friends_v1';

  final List<Friend> _friends = [];
  List<Friend> _remoteSuggestions = [];
  bool loaded = false;

  List<Friend> get friends => List.unmodifiable(_friends);

  Future<SharedPreferences> get _prefs async =>
      serviceForTest ?? await SharedPreferences.getInstance();

  Future<void> load() async {
    if (backend.backendEnabled) {
      await _loadRemote();
    } else {
      await _loadLocal();
    }
    loaded = true;
    notifyListeners();
  }

  /// Re-fetch from the backend (after stats change, a new sign-in, etc.).
  Future<void> refresh() => load();

  Future<void> _loadRemote() async {
    final profs = await backend.fetchFriendProfiles();
    _friends
      ..clear()
      ..addAll(profs.map(_friendFromProfile));
    final exclude = _friends.map((f) => f.id).toSet();
    final sugg = await backend.fetchSuggestionProfiles(exclude);
    _remoteSuggestions = sugg.map(_friendFromProfile).toList();
  }

  Future<void> _loadLocal() async {
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
  }

  Future<void> _save() async {
    final prefs = await _prefs;
    await prefs.setString(
        _key, jsonEncode(_friends.map((f) => f.toJson()).toList()));
  }

  /// Adds a friend by username. Returns an error string, or null on success.
  /// With the backend on, the username is looked up in the real user directory;
  /// with it off, only the local demo directory resolves — a random name won't,
  /// which is the behaviour a real backend gives too.
  Future<String?> addByUsername(String username) async {
    final u = username.trim();
    if (!isValidUsername(u)) {
      return 'Enter a valid username (3–20 letters, numbers, _).';
    }
    if (_friends.any((f) => f.username.toLowerCase() == u.toLowerCase())) {
      return '@$u is already in your friends.';
    }
    if (backend.backendEnabled) {
      final prof = await backend.findProfileByUsername(u);
      if (prof == null) return 'No user found with the username @$u.';
      final friend = _friendFromProfile(prof);
      if (friend.id == backend.currentUserId) {
        return "That's you — add a friend instead.";
      }
      await backend.addFriendship(friend.id);
      _friends.add(friend);
      _remoteSuggestions.removeWhere((s) => s.id == friend.id);
      notifyListeners();
      return null;
    }
    final d = _lookup(u);
    if (d == null) return 'No user found with the username @$u.';
    _friends.add(_friendFromDir(d));
    await _save();
    notifyListeners();
    return null;
  }

  /// Users you haven't added yet (for the "Suggested" section).
  List<Friend> suggestions() {
    if (backend.backendEnabled) return List.unmodifiable(_remoteSuggestions);
    final have = _friends.map((f) => f.username.toLowerCase()).toSet();
    return [
      for (final d in _directory)
        if (!have.contains(d.username.toLowerCase())) _friendFromDir(d),
    ];
  }

  void remove(String id) {
    _friends.removeWhere((f) => f.id == id);
    if (backend.backendEnabled) {
      backend.removeFriendship(id); // optimistic; deletes remotely in the bg
    } else {
      _save();
    }
    notifyListeners();
  }

  // Start with a few directory users already added; the rest show up as
  // suggestions you can tap to add.
  List<Friend> _seed() => [_directory[0], _directory[1], _directory[2]]
      .map(_friendFromDir)
      .toList();
}

// Maps a Supabase `profiles` row to a Friend.
Friend _friendFromProfile(Map<String, dynamic> p) => Friend(
      id: (p['id'] ?? '').toString(),
      username: (p['username'] ?? '').toString(),
      name: (p['name'] ?? '').toString(),
      totalXp: (p['total_xp'] as num?)?.toInt() ?? 0,
      streak: (p['streak'] as num?)?.toInt() ?? 0,
      prestige: (p['prestige'] as num?)?.toInt() ?? 0,
      borderId: (p['border_id'] ?? 'none').toString(),
      sample: false,
    );

/// App-wide friends store.
final friends = FriendsStore();
