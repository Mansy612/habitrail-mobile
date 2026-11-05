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

/// A persistent, account-scoped queue of buddy check-in days awaiting the
/// server's acknowledgement. Pure (no I/O or globals): [BuddyStore] persists it
/// and supplies the sender. A day is "pending" until the server acks it, then
/// "synced" — so an offline check-in is kept and retried, never lost or counted
/// as sent. Idempotent: a synced day is never re-queued, and the server's
/// insert-on-conflict-do-nothing makes repeated sends and duplicate acks safe.
class CheckInQueue {
  CheckInQueue({this.windowDays = 7});
  final int windowDays; // how many recent days a check-in may cover

  String owner = ''; // the account (uid) these days belong to
  final Set<String> pending = {}; // queued, not yet acknowledged
  final Set<String> synced = {}; // acknowledged by the server
  bool _sending = false;

  bool get hasPending => pending.isNotEmpty;

  /// Bind the queue to [uid]; a different owner empties it, so one account can
  /// never send another account's activity.
  void adoptOwner(String uid) {
    if (owner == uid) return;
    owner = uid;
    pending.clear();
    synced.clear();
  }

  void reset() => adoptOwner('');

  /// Queue the recent [activeDays] that aren't already synced/pending. Returns
  /// true if anything new was added. Also forgets synced days older than the
  /// server's catch-up window so the set stays small.
  bool enqueueRecent(Set<String> activeDays, DateTime now) {
    final cutoff =
        dateKey(DateTime(now.year, now.month, now.day - (windowDays + 3)));
    synced.removeWhere((d) => d.compareTo(cutoff) < 0);
    var added = false;
    for (var i = 0; i < windowDays; i++) {
      final d = dateKey(DateTime(now.year, now.month, now.day - i));
      if (!activeDays.contains(d)) continue;
      if (synced.contains(d) || pending.contains(d)) continue;
      pending.add(d);
      added = true;
    }
    return added;
  }

  /// Send the pending days through [send]. On ack they move to synced; on
  /// failure they stay pending for the next retry. Re-entrant-safe, and days
  /// queued while a send is in flight are preserved for the next flush. Returns
  /// true if the server acknowledged.
  Future<bool> flush(Future<bool> Function(List<String> days) send) async {
    if (_sending || pending.isEmpty) return false;
    _sending = true;
    final batch = pending.toList()..sort();
    try {
      final ok = await send(batch);
      if (ok) {
        synced.addAll(batch);
        pending.removeAll(batch);
      }
      return ok;
    } finally {
      _sending = false;
    }
  }

  Map<String, dynamic> toJson() => {
        'owner': owner,
        'pending': pending.toList()..sort(),
        'synced': synced.toList()..sort(),
      };

  /// Restore from [m], but only if it belongs to [uid]; otherwise start empty
  /// bound to [uid] (the stored queue was another account's).
  void loadJson(Map<String, dynamic> m, String uid) {
    if ((m['owner'] ?? '').toString() != uid) {
      adoptOwner(uid);
      return;
    }
    owner = uid;
    pending
      ..clear()
      ..addAll(((m['pending'] as List?) ?? const []).map((e) => e.toString()));
    synced
      ..clear()
      ..addAll(((m['synced'] as List?) ?? const []).map((e) => e.toString()));
  }
}

class BuddyStore extends ChangeNotifier {
  static const _key = 'buddies_v1';
  static const _queueKey = 'buddy_checkins_v1';
  final List<Buddy> _list = [];
  final CheckInQueue _queue = CheckInQueue();
  bool _queueLoaded = false;
  AppLifecycleListener? _lifecycle;
  bool loaded = false;

  /// True while this device has check-ins the server hasn't acknowledged yet
  /// (so the UI can distinguish pending activity from synced activity).
  bool get hasPendingCheckIns => _queue.hasPending;
  Set<String> get pendingCheckInDays => {..._queue.pending};

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

  /// After a sign-out: that account's buddies and pending check-ins aren't the
  /// next account's.
  void clear() {
    _list.clear();
    _queue.reset();
    unawaited(_saveQueue());
    notifyListeners();
  }

  /// Sends check-ins as they happen, retries when the app comes back (a chance
  /// connectivity is restored), and reloads the buddy list on resume.
  void attach() {
    appState.addListener(_sendCheckIns);
    _lifecycle = AppLifecycleListener(onResume: () async {
      await refresh();
      await _flush();
    });
    unawaited(_initQueue());
  }

  Future<void> _initQueue() async {
    await _loadQueue(); // restore the pending queue persisted before a restart
    _queueLoaded = true;
    _sendCheckIns(); // queue current activity and flush, now that we're loaded
  }

  // Queue the week's check-ins (so a few offline days still reach the server),
  // then try to send. A day is marked synced only once the server acks it; an
  // unsent one stays pending and is retried on activity, resume, or restart.
  void _sendCheckIns() {
    if (!backend.backendEnabled || !_queueLoaded) return;
    _queue.adoptOwner(backend.currentUserId ?? '');
    if (_queue.enqueueRecent(appState.activeDays, DateTime.now())) {
      unawaited(_saveQueue());
    }
    unawaited(_flush());
  }

  /// Send the pending queue; persist and notify only if something synced.
  Future<void> _flush() async {
    if (!backend.backendEnabled || !_queueLoaded) return;
    _queue.adoptOwner(backend.currentUserId ?? '');
    final ok = await _queue.flush(backend.checkIn);
    if (ok) {
      await _saveQueue();
      notifyListeners();
    }
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = backend.currentUserId ?? '';
    try {
      final raw = prefs.getString(_queueKey);
      if (raw != null && raw.isNotEmpty) {
        _queue.loadJson((jsonDecode(raw) as Map).cast<String, dynamic>(), uid);
      } else {
        _queue.adoptOwner(uid);
      }
    } catch (_) {
      _queue.adoptOwner(uid); // corrupt payload: start clean for this account
    }
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey, jsonEncode(_queue.toJson()));
  }

  /// Starts a buddy streak with [f]: an invite they accept, or straight away
  /// for the demo friends. Returns an error to show, or null.
  Future<String?> invite(Friend f) async {
    if (forFriend(f.id) != null) return null;
    if (full) return _friendly('buddy limit');
    if (backend.backendEnabled) {
      final err = await backend.inviteBuddy(f.id, _today);
      if (err != null) return _friendly(err);
      _sendCheckIns(); // make sure today's check-in is queued and sent
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
