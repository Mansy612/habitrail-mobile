// Buddy streaks: invite a friend, then keep one streak going together. The
// rules (core.dart buddyStreak) are the same with or without an account; this
// store syncs with Supabase when signed in, and plays the demo friends
// on-device otherwise (they accept at once and check in on most days).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend.dart' as backend;
import 'core.dart';
import 'friends.dart';

class BuddyStore extends ChangeNotifier {
  static const _key = 'buddies_v1';
  final List<Buddy> _list = [];
  String _sent = ''; // the check-in days last sent to the server
  AppLifecycleListener? _lifecycle;
  bool loaded = false;

  List<Buddy> get list => List.unmodifiable(_list);
  List<Buddy> get active => _list.where((b) => b.active).toList();
  bool get full => _list.length >= kMaxBuddies;
  Buddy? forFriend(String friendId) =>
      _list.where((b) => b.friendId == friendId).firstOrNull;

  // This user's check-ins: what the server has, plus activity on this device
  // (so finishing a habit shows at once, before the next sync).
  Set<String> _mine(Buddy b) => {...appState.activeDays, ...b.myDays};
  String get _today => dateKey(DateTime.now());
  int streakOf(Buddy b) =>
      buddyStreak(_mine(b), b.theirDays, b.startedOn, DateTime.now());
  bool meToday(Buddy b) => _mine(b).contains(_today);
  bool themToday(Buddy b) => b.theirDays.contains(_today);

  Future<void> load() async {
    if (backend.backendEnabled) {
      final rows = await backend.myBuddies();
      if (rows != null) {
        _list
          ..clear()
          ..addAll(rows.map(_fromRow));
      }
    } else {
      await _loadLocal();
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> refresh() => load();

  /// After a sign-out: that account's buddies aren't this device's.
  void clear() {
    _list.clear();
    _sent = '';
    notifyListeners();
  }

  /// Sends check-ins as they happen, and refreshes when the app comes back.
  void attach() {
    appState.addListener(_sendCheckIns);
    _lifecycle = AppLifecycleListener(onResume: refresh);
    _sendCheckIns();
  }

  // The last week, so a few offline days still reach the server.
  void _sendCheckIns() {
    if (!backend.backendEnabled) return;
    final now = DateTime.now();
    final days = appState.activeDays;
    final recent = [
      for (var i = 0; i < 7; i++)
        dateKey(DateTime(now.year, now.month, now.day - i)),
    ].where(days.contains).toList();
    final sig = recent.join(',');
    if (recent.isEmpty || sig == _sent) return;
    _sent = sig;
    backend.checkIn(recent);
  }

  /// Starts a buddy streak with [f]: an invite they accept, or straight away
  /// for the demo friends. Returns an error to show, or null.
  Future<String?> invite(Friend f) async {
    if (forFriend(f.id) != null) return null;
    if (full) return _friendly('buddy limit');
    if (backend.backendEnabled) {
      final err = await backend.inviteBuddy(f.id, _today);
      if (err != null) return _friendly(err);
      _sent = ''; // make sure the server has today's check-in
      _sendCheckIns();
      await load();
      return null;
    }
    _list.add(_demoBuddy(f.id, f.name, f.username, f.borderId, _today));
    await _saveLocal();
    notifyListeners();
    return null;
  }

  /// Accepts or declines an invite this user received.
  Future<String?> respond(Buddy b, bool accept) async {
    final err = await backend.respondBuddy(b.id, accept, _today);
    if (err != null) return _friendly(err);
    if (accept) {
      _sent = '';
      _sendCheckIns();
    }
    await load();
    return null;
  }

  /// Ends a buddy streak, or withdraws an invite.
  Future<void> end(Buddy b) async {
    _list.removeWhere((x) => x.id == b.id);
    notifyListeners();
    if (backend.backendEnabled) {
      await backend.endBuddy(b.id);
    } else {
      await _saveLocal();
    }
  }

  String _friendly(String err) => switch (err) {
        'buddy limit' => 'You can have up to $kMaxBuddies buddy streaks.',
        'not friends' => 'Add them as a friend first.',
        'offline' => 'Couldn\'t reach the server. Try again.',
        _ => 'Couldn\'t start the buddy streak. Try again.',
      };

  Buddy _fromRow(Map<String, dynamic> r) {
    String? day(Object? v) {
      final s = v?.toString() ?? '';
      return s.length >= 10 ? s.substring(0, 10) : null;
    }

    Set<String> days(Object? v) =>
        {for (final d in (v as List?) ?? const []) ?day(d)};
    return Buddy(
      id: '${r['id']}',
      friendId: '${r['buddy_id']}',
      name: (r['name'] ?? '').toString(),
      username: (r['username'] ?? '').toString(),
      borderId: (r['border_id'] ?? 'none').toString(),
      status: (r['status'] ?? 'pending').toString(),
      incoming: r['incoming'] == true,
      startedOn: day(r['started_on']),
      myDays: days(r['my_days']),
      theirDays: days(r['their_days']),
    );
  }

  // ── Demo mode (no account): kept on this device ───────────────────────────

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    _list.clear();
    try {
      for (final e in (jsonDecode(prefs.getString(_key) ?? '[]') as List)) {
        final m = (e as Map).cast<String, dynamic>();
        _list.add(_demoBuddy(
          m['friendId'] as String,
          m['name'] as String,
          m['username'] as String,
          (m['borderId'] as String?) ?? 'none',
          m['startedOn'] as String,
        ));
      }
    } catch (_) {
      _list.clear(); // corrupt payload: start over rather than crash
    }
  }

  Future<void> _saveLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([
        for (final b in _list)
          {
            'friendId': b.friendId,
            'name': b.name,
            'username': b.username,
            'borderId': b.borderId,
            'startedOn': b.startedOn,
          },
      ]),
    );
  }

  // A demo friend checks in on about four days in five, the same days every
  // time (derived from their username), so the streak behaves like a real one.
  Buddy _demoBuddy(
      String friendId, String name, String username, String borderId, String startedOn) {
    final start = DateTime.parse(startedOn);
    final now = DateTime.now();
    final theirs = <String>{};
    for (var d = start;
        !d.isAfter(now);
        d = DateTime(d.year, d.month, d.day + 1)) {
      final k = dateKey(d);
      if (_hash('$username|$k') % 5 != 0) theirs.add(k);
    }
    return Buddy(
      id: 'demo-$friendId',
      friendId: friendId,
      name: name,
      username: username,
      borderId: borderId,
      startedOn: startedOn,
      theirDays: theirs,
    );
  }

  static int _hash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    appState.removeListener(_sendCheckIns);
    super.dispose();
  }
}

final buddies = BuddyStore();
