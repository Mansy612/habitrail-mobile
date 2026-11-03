import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import 'ai.dart';
import 'auth.dart';
import 'core.dart' show appState;

// ── Supabase backend (social layer) ──────────────────────────────────────────
//
// Real accounts, a real user directory, friendships and a live leaderboard.
// Habit progress stays on-device; only a public snapshot (name + stats) is
// mirrored to the user's `profiles` row so friends can see it.
//
// Credentials are compile-time, via --dart-define:
//   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// With no credentials the whole app falls back to the on-device stubs, so it
// keeps working offline and in tests. See docs/SUPABASE_SETUP.md for the schema.

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// True once Supabase credentials are provided at build time.
bool get backendEnabled => _url.isNotEmpty && _anonKey.isNotEmpty;

/// Initialise Supabase (no-op when credentials aren't set).
Future<void> initBackend() async {
  if (!backendEnabled) return;
  await Supabase.initialize(url: _url, publishableKey: _anonKey);
  wireRemoteAi();
}

/// Route the AI functions through the `ai-proxy` Edge Function (which proxies to
/// a hosted Ollama) whenever the backend is on. The call carries the signed-in
/// user's JWT so the server can require auth; a failure or a missing function
/// returns null, and ai.dart falls back to local Ollama / the offline heuristic.
void wireRemoteAi() {
  if (!backendEnabled) return;
  aiRemoteChat = ({
    required String system,
    required String user,
    required String model,
    required bool jsonFormat,
    required double temperature,
  }) async {
    try {
      final res = await _sb.functions.invoke('ai-proxy', body: {
        'system': system,
        'prompt': user,
        'model': model,
        'json': jsonFormat,
        'temperature': temperature,
      });
      final data = res.data;
      if (data is Map && data['content'] is String) {
        final s = (data['content'] as String).trim();
        return s.isEmpty ? null : s;
      }
      return null;
    } catch (_) {
      return null;
    }
  };
}

SupabaseClient get _sb => Supabase.instance.client;

String? get _uid => _sb.auth.currentUser?.id;

/// The signed-in user's id (null when signed out or the backend is off).
String? get currentUserId =>
    backendEnabled ? _sb.auth.currentUser?.id : null;

// ── Auth ─────────────────────────────────────────────────────────────────────

/// Supabase-backed auth. Drops in behind [AuthService]; the UI is unchanged.
class SupabaseAuthService implements AuthService {
  @override
  bool get isRemote => true;

  @override
  Future<bool> isUsernameAvailable(String username) async {
    final u = username.trim();
    if (u.isEmpty) return false;
    try {
      final row =
          await _sb.from('profiles').select('id').ilike('username', u).maybeSingle();
      return row == null;
    } catch (_) {
      return false; // be conservative if we can't check
    }
  }

  @override
  Future<AuthResult> signUp(
      {required String email,
      required String password,
      required String username}) async {
    final uname = username.trim();
    if (!isValidUsername(uname)) {
      return const AuthResult.fail(
          'Username must be 3–20 letters, numbers, or underscores.');
    }
    final err = validateCredentials(email, password);
    if (err != null) return AuthResult.fail(err);
    try {
      if (!await isUsernameAvailable(uname)) {
        return const AuthResult.fail('That username is already taken.');
      }
      final res = await _sb.auth.signUp(
          email: email.trim(),
          password: password,
          data: {'username': uname, 'name': uname});
      final u = res.user;
      if (u == null) {
        return const AuthResult.fail(
            'Check your email to confirm your account, then sign in.');
      }
      await _sb
          .from('profiles')
          .insert({'id': u.id, 'username': uname, 'name': uname});
      return AuthResult.ok(_toAuthUser(u, username: uname, name: uname));
    } on AuthException catch (e) {
      return AuthResult.fail(e.message);
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        return const AuthResult.fail('That username is already taken.');
      }
      return AuthResult.fail(e.message);
    } catch (_) {
      return const AuthResult.fail('Could not create your account. Try again.');
    }
  }

  @override
  Future<AuthResult> signIn(
      {required String email, required String password}) async {
    final err = validateCredentials(email, password);
    if (err != null) return AuthResult.fail(err);
    try {
      final res = await _sb.auth
          .signInWithPassword(email: email.trim(), password: password);
      final u = res.user;
      if (u == null) return const AuthResult.fail('Incorrect email or password.');
      // A ban normally stops sign-in in Supabase Auth itself; this catches a
      // ban that only reached the database (see the admin console migration).
      if (await _isBanned()) {
        await signOut();
        return const AuthResult.fail(kSuspendedMessage);
      }
      final profile = await _profile(u.id);
      return AuthResult.ok(_toAuthUser(u,
          username: profile?['username'] as String?,
          name: profile?['name'] as String?));
    } on AuthException catch (e) {
      if (e.code == 'user_banned' || e.message.toLowerCase().contains('banned')) {
        return const AuthResult.fail(kSuspendedMessage);
      }
      return AuthResult.fail(e.message);
    } catch (_) {
      return const AuthResult.fail('Could not sign in. Try again.');
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _sb.auth.signOut();
    } catch (_) {}
  }

  @override
  Future<AuthUser?> currentUser() async {
    final u = _sb.auth.currentUser;
    if (u == null) return null;
    if (await _isBanned()) {
      await signOut(); // banned since the last launch
      return null;
    }
    final profile = await _profile(u.id);
    return _toAuthUser(u,
        username: profile?['username'] as String?,
        name: profile?['name'] as String?);
  }

  /// Offline, or the migration not deployed, reads as not banned.
  Future<bool> _isBanned() async =>
      (await fetchAccountStatus())?['banned'] == true;

  @override
  Future<String?> sendPasswordReset(String email) async {
    if (!isValidEmail(email)) return 'Enter a valid email address.';
    try {
      // The "Reset password" email template must include {{ .Token }} so the
      // email carries the code (docs/SUPABASE_SETUP.md, 2k).
      await _sb.auth.resetPasswordForEmail(email.trim());
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not send the code. Check your connection and try again.';
    }
  }

  @override
  Future<AuthResult> resetPassword(
      {required String email,
      required String code,
      required String newPassword}) async {
    final err = validateCredentials(email, newPassword);
    if (err != null) return AuthResult.fail(err);
    if (!isValidResetCode(code)) return const AuthResult.fail(kBadResetCode);
    final User? u;
    try {
      // A valid recovery code signs the user in; then the password is set.
      final res = await _sb.auth.verifyOTP(
          email: email.trim(), token: code.trim(), type: OtpType.recovery);
      u = res.user;
    } on AuthException catch (e) {
      if (e.code == 'user_banned') return const AuthResult.fail(kSuspendedMessage);
      return const AuthResult.fail(kBadResetCode);
    } catch (_) {
      return const AuthResult.fail('Could not check the code. Try again.');
    }
    if (u == null) return const AuthResult.fail(kBadResetCode);
    if (await _isBanned()) {
      await signOut();
      return const AuthResult.fail(kSuspendedMessage);
    }
    try {
      await _sb.auth.updateUser(UserAttributes(password: newPassword));
    } on AuthException catch (e) {
      // Choosing the old password again still leaves them signed in with it.
      if (e.code != 'same_password') {
        await signOut();
        return AuthResult.fail('${e.message} Request a new code and try again.');
      }
    } catch (_) {
      await signOut();
      return const AuthResult.fail(
          'Could not set the new password. Request a new code and try again.');
    }
    final profile = await _profile(u.id);
    return AuthResult.ok(_toAuthUser(u,
        username: profile?['username'] as String?,
        name: profile?['name'] as String?));
  }

  @override
  Future<void> updateName(String name) async {
    final id = _uid;
    if (id == null) return;
    try {
      await _sb.from('profiles').update({'name': name.trim()}).eq('id', id);
    } catch (_) {}
  }

  @override
  Future<void> deleteAccount() async {
    final id = _uid;
    if (id != null) {
      // Fully delete the auth user (and all cascading rows) via the privileged
      // 'delete-account' Edge Function. If it isn't deployed, fall back to
      // removing the profile row so the account at least leaves the app.
      var deleted = false;
      try {
        final res = await _sb.functions.invoke('delete-account');
        deleted = res.status == 200;
      } catch (_) {}
      if (!deleted) {
        try {
          await _sb.from('profiles').delete().eq('id', id);
        } catch (_) {}
      }
    }
    await signOut();
  }

  Future<Map<String, dynamic>?> _profile(String id) async {
    try {
      return await _sb.from('profiles').select().eq('id', id).maybeSingle();
    } catch (_) {
      return null;
    }
  }

  AuthUser _toAuthUser(User u, {String? username, String? name}) => AuthUser(
        id: u.id,
        email: u.email ?? '',
        username:
            username ?? (u.userMetadata?['username'] as String?) ?? '',
        name: name ??
            (u.userMetadata?['name'] as String?) ??
            username ??
            '',
        createdAt: u.createdAt,
      );
}

// ── Profile stat sync ────────────────────────────────────────────────────────

/// Mirror the current user's public stats to their profile row so friends see
/// up-to-date numbers. No-op when signed out or the backend is off.
Future<void> pushProfileStats({
  required int totalXp,
  required int streak,
  required int prestige,
  required String borderId,
  String? name,
}) async {
  if (!backendEnabled) return;
  final id = _uid;
  if (id == null) return;
  try {
    final data = <String, dynamic>{
      'total_xp': totalXp,
      'streak': streak,
      'prestige': prestige,
      'border_id': borderId,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (name != null && name.isNotEmpty) data['name'] = name;
    await _sb.from('profiles').update(data).eq('id', id);
  } catch (_) {}
}

// ── Friends / directory (raw rows; mapped to Friend in friends.dart) ─────────

/// Profiles of everyone the current user has added.
Future<List<Map<String, dynamic>>> fetchFriendProfiles() async {
  final id = _uid;
  if (id == null) return const [];
  try {
    final fr =
        await _sb.from('friendships').select('friend_id').eq('user_id', id);
    final ids =
        (fr as List).map((e) => (e['friend_id'] as String)).toList();
    if (ids.isEmpty) return const [];
    final profs = await _sb.from('profiles').select().inFilter('id', ids);
    return (profs as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Looks up a single user by exact (case-insensitive) username.
Future<Map<String, dynamic>?> findProfileByUsername(String username) async {
  try {
    return await _sb
        .from('profiles')
        .select()
        .ilike('username', username.trim())
        .maybeSingle();
  } catch (_) {
    return null;
  }
}

Future<void> addFriendship(String friendId) async {
  final id = _uid;
  if (id == null) return;
  try {
    await _sb
        .from('friendships')
        .insert({'user_id': id, 'friend_id': friendId});
  } catch (_) {}
}

Future<void> removeFriendship(String friendId) async {
  final id = _uid;
  if (id == null) return;
  try {
    await _sb
        .from('friendships')
        .delete()
        .eq('user_id', id)
        .eq('friend_id', friendId);
  } catch (_) {}
}

/// Recently-active users you haven't added yet (for the "Suggested" section).
Future<List<Map<String, dynamic>>> fetchSuggestionProfiles(
    Set<String> excludeIds) async {
  final id = _uid;
  if (id == null) return const [];
  try {
    final profs = await _sb
        .from('profiles')
        .select()
        .neq('id', id)
        .order('updated_at', ascending: false)
        .limit(20);
    return (profs as List)
        .cast<Map<String, dynamic>>()
        .where((p) => !excludeIds.contains(p['id']))
        .take(8)
        .toList();
  } catch (_) {
    return const [];
  }
}

// ── Parties (co-op) ──────────────────────────────────────────────────────────
// All calls go through SECURITY DEFINER RPCs (see
// supabase/migrations/..._parties.sql); they no-op when the backend is off.

/// Create a party; returns the new party row, or null on failure / backend off.
Future<Map<String, dynamic>?> createParty(String name) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('create_party', params: {'p_name': name});
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Join a party by invite code; returns the party row, or null if not found.
Future<Map<String, dynamic>?> joinParty(String code) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('join_party', params: {'p_code': code});
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

Future<void> leaveParty(String partyId) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('leave_party', params: {'p_id': partyId});
  } catch (_) {}
}

/// The caller's current party row, or null when they're not in one.
Future<Map<String, dynamic>?> myParty() async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('my_party');
    if (r is List) {
      return r.isEmpty ? null : (r.first as Map).cast<String, dynamic>();
    }
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Member profiles (+ xp_baseline) for a party the caller belongs to.
Future<List<Map<String, dynamic>>> partyMembers(String partyId) async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb.rpc('party_members_info', params: {'p_id': partyId});
    return (r as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Owner-only: set the shared weekly XP goal (rebaselines everyone to now).
Future<Map<String, dynamic>?> setPartyGoal(
    String partyId, int target, String week) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('set_party_goal',
        params: {'p_id': partyId, 'p_target': target, 'p_week': week});
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Owner-only: start/change the party's co-op quest (sets the boss + target
/// and rebaselines everyone). Returns the updated party row.
Future<Map<String, dynamic>?> setPartyQuest(
    String partyId, String questId, int target, String week) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('set_party_quest', params: {
      'p_id': partyId,
      'p_quest': questId,
      'p_target': target,
      'p_week': week,
    });
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Record a report of a chat message (App Store 1.2). Best-effort insert into
/// content_reports; any signed-in user may file one. No-ops if not deployed.
Future<void> reportMessage(
    String scope, String messageId, String authorId) async {
  if (!backendEnabled || _uid == null) return;
  try {
    await _sb.from('content_reports').insert({
      'reporter_id': _uid,
      'scope': scope,
      'message_id': messageId,
      'author_id': authorId.isEmpty ? null : authorId,
    });
  } catch (_) {}
}

/// Recent messages for a party (oldest → newest), readable by members via RLS.
Future<List<Map<String, dynamic>>> partyMessages(String partyId) async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb
        .from('party_messages')
        .select()
        .eq('party_id', partyId)
        .order('created_at', ascending: false)
        .limit(100);
    return (r as List).cast<Map<String, dynamic>>().reversed.toList();
  } catch (_) {
    return const [];
  }
}

/// Send a party message (membership enforced server-side).
Future<void> sendPartyMessage(String partyId, String body) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('send_party_message',
        params: {'p_id': partyId, 'p_body': body});
  } catch (_) {}
}

/// Subscribe to new messages in [partyId]; returns an unsubscribe callback, or
/// null when the backend is off / on error. Keeps realtime types out of the UI.
Future<void> Function()? subscribePartyMessages(
    String partyId, void Function(Map<String, dynamic>) onInsert) {
  if (!backendEnabled) return null;
  try {
    final ch = _sb.channel('party-chat-$partyId');
    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'party_messages',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'party_id',
          value: partyId),
      callback: (payload) {
        try {
          onInsert(Map<String, dynamic>.from(payload.newRecord));
        } catch (_) {}
      },
    ).subscribe();
    return () async {
      try {
        await _sb.removeChannel(ch);
      } catch (_) {}
    };
  } catch (_) {
    return null;
  }
}

// ── Guilds (public groups) ────────────────────────────────────────────────────

Future<Map<String, dynamic>?> createGuild(String name, String desc) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb
        .rpc('create_guild', params: {'p_name': name, 'p_desc': desc});
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

Future<void> joinGuild(String guildId) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('join_guild', params: {'g_id': guildId});
  } catch (_) {}
}

Future<void> leaveGuild(String guildId) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('leave_guild', params: {'g_id': guildId});
  } catch (_) {}
}

/// Public guilds matching [query] (empty = all), with member counts.
Future<List<Map<String, dynamic>>> discoverGuilds(String query) async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb.rpc('discover_guilds', params: {'p_query': query});
    return (r as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Guilds the caller belongs to.
Future<List<Map<String, dynamic>>> myGuilds() async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb.rpc('my_guilds');
    return (r as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Roster (profile snapshots + goal baseline) for a guild.
Future<List<Map<String, dynamic>>> guildMembers(String guildId) async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb.rpc('guild_members_info', params: {'g_id': guildId});
    return (r as List).cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Owner-only: set the guild's shared weekly XP goal (rebaselines everyone).
Future<Map<String, dynamic>?> setGuildGoal(
    String guildId, int target, String week) async {
  if (!backendEnabled) return null;
  try {
    final r = await _sb.rpc('set_guild_goal',
        params: {'g_id': guildId, 'p_target': target, 'p_week': week});
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Recent messages for a guild (oldest → newest), readable by members via RLS.
Future<List<Map<String, dynamic>>> guildMessages(String guildId) async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb
        .from('guild_messages')
        .select()
        .eq('guild_id', guildId)
        .order('created_at', ascending: false)
        .limit(100);
    return (r as List).cast<Map<String, dynamic>>().reversed.toList();
  } catch (_) {
    return const [];
  }
}

/// Send a guild message (membership enforced server-side).
Future<void> sendGuildMessage(String guildId, String body) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('send_guild_message',
        params: {'g_id': guildId, 'p_body': body});
  } catch (_) {}
}

/// Subscribe to new messages in [guildId]; returns an unsubscribe callback, or
/// null when the backend is off / on error.
Future<void> Function()? subscribeGuildMessages(
    String guildId, void Function(Map<String, dynamic>) onInsert) {
  if (!backendEnabled) return null;
  try {
    final ch = _sb.channel('guild-chat-$guildId');
    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'guild_messages',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'guild_id',
          value: guildId),
      callback: (payload) {
        try {
          onInsert(Map<String, dynamic>.from(payload.newRecord));
        } catch (_) {}
      },
    ).subscribe();
    return () async {
      try {
        await _sb.removeChannel(ch);
      } catch (_) {}
    };
  } catch (_) {
    return null;
  }
}

// ── Global chat ───────────────────────────────────────────────────────────────

/// Recent global messages (oldest → newest).
Future<List<Map<String, dynamic>>> globalMessages() async {
  if (!backendEnabled) return const [];
  try {
    final r = await _sb
        .from('global_messages')
        .select()
        .order('created_at', ascending: false)
        .limit(100);
    return (r as List).cast<Map<String, dynamic>>().reversed.toList();
  } catch (_) {
    return const [];
  }
}

Future<void> sendGlobalMessage(String body) async {
  if (!backendEnabled) return;
  try {
    await _sb.rpc('send_global_message', params: {'p_body': body});
  } catch (_) {}
}

/// Subscribe to new global messages; returns an unsubscribe callback or null.
Future<void> Function()? subscribeGlobalMessages(
    void Function(Map<String, dynamic>) onInsert) {
  if (!backendEnabled) return null;
  try {
    final ch = _sb.channel('global-chat');
    ch.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'global_messages',
      callback: (payload) {
        try {
          onInsert(Map<String, dynamic>.from(payload.newRecord));
        } catch (_) {}
      },
    ).subscribe();
    return () async {
      try {
        await _sb.removeChannel(ch);
      } catch (_) {}
    };
  } catch (_) {
    return null;
  }
}

// ── Cloud backup / restore ────────────────────────────────────────────────────

/// Upserts the backup row. Returns false when it couldn't be saved.
Future<bool> uploadBackup(Map<String, dynamic> data) async {
  if (!backendEnabled) return false;
  final id = _uid;
  if (id == null) return false;
  try {
    await _sb.from('user_backups').upsert({
      'user_id': id,
      'data': data,
      'updated_at': DateTime.now().toIso8601String(),
    });
    return true;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>?> downloadBackup() async {
  if (!backendEnabled) return null;
  final id = _uid;
  if (id == null) return null;
  try {
    final r = await _sb
        .from('user_backups')
        .select('data, updated_at')
        .eq('user_id', id)
        .maybeSingle();
    return r?.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

/// Back up the full local save to the user's account.
/// Backs the full save up to the account. Returns whether it was saved; only
/// a successful upload updates "last backed up".
Future<bool> backupNow() async {
  if (!backendEnabled || _uid == null) return false;
  final save = await appState.exportSave();
  final ok = await uploadBackup({'v': 1, 'save': save});
  if (ok) await appState.markBackedUp();
  return ok;
}

/// Replace the local save with the cloud backup. Returns false if none exists.
Future<bool> restoreFromCloud() async {
  final cloud = await downloadBackup();
  final data = cloud?['data'];
  if (data is Map && data['save'] is Map) {
    await appState.importSave((data['save'] as Map).cast<String, dynamic>());
    return true;
  }
  return false;
}

/// After sign-in: restore the cloud backup onto a fresh device, otherwise push
/// this device's save up. Never overwrites existing local progress.
Future<void> syncAfterSignIn() async {
  if (!backendEnabled || _uid == null) return;
  final cloud = await downloadBackup();
  final data = cloud?['data'];
  final hasCloud = data is Map && data['save'] is Map;
  if (hasCloud && appState.localIsEmpty) {
    await appState.importSave((data['save'] as Map).cast<String, dynamic>());
  } else {
    await backupNow();
  }
}

// ── Account status + admin console ────────────────────────────────────────────
// Moderation is enforced server-side (supabase/migrations/..._admin_console.sql):
// every admin_* RPC refuses non-admins, and banned accounts can't write chat,
// party or guild rows. lib/admin.dart builds the app side on these calls.

/// The signed-in user's own status: admin flag, ban, Premium override and
/// coin adjustments not yet applied. Null when signed out, offline, or the
/// migration isn't deployed.
Future<Map<String, dynamic>?> fetchAccountStatus() async {
  if (!backendEnabled || _uid == null) return null;
  try {
    final r = await _sb.rpc('my_account_status');
    return r is Map ? r.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Marks coin adjustments as applied on this device. False if it didn't land.
Future<bool> ackCoinGrants(List<String> ids) async {
  if (!backendEnabled || _uid == null || ids.isEmpty) return false;
  try {
    await _sb.rpc('ack_coin_grants', params: {'p_ids': ids});
    return true;
  } catch (_) {
    return false;
  }
}

/// Reports this device's coin balance and own Premium state, so the admin
/// console can show them (coins live on-device). Display only.
Future<void> reportAccountSnapshot(
    {required int coins, required bool premium}) async {
  if (!backendEnabled || _uid == null) return;
  try {
    await _sb.rpc('report_account_snapshot',
        params: {'p_coins': coins, 'p_premium': premium});
  } catch (_) {}
}

const _adminSignedOut = 'Sign in to use the admin console.';
const _adminOffline = 'Could not reach the server. Try again.';

/// Accounts matching [query] (username, name or email; blank = recently
/// active), or the server's error.
Future<(List<Map<String, dynamic>>, String?)> adminSearchUsers(
    String query) async {
  if (!backendEnabled || _uid == null) {
    return (const <Map<String, dynamic>>[], _adminSignedOut);
  }
  try {
    final r = await _sb.rpc('admin_search_users', params: {'p_query': query});
    return ((r as List).cast<Map<String, dynamic>>(), null);
  } on PostgrestException catch (e) {
    return (const <Map<String, dynamic>>[], e.message);
  } catch (_) {
    return (const <Map<String, dynamic>>[], _adminOffline);
  }
}

/// Runs an admin RPC; null on success, otherwise the error to show.
Future<String?> _adminCall(String fn, Map<String, dynamic> params) async {
  if (!backendEnabled || _uid == null) return _adminSignedOut;
  try {
    await _sb.rpc(fn, params: params);
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (_) {
    return _adminOffline;
  }
}

Future<String?> adminAdjustCoins(String userId, int amount, String note) =>
    _adminCall('admin_adjust_coins',
        {'p_user': userId, 'p_amount': amount, 'p_note': note});

/// [state] is 'grant', 'revoke' or 'none' (back to the device's own state).
Future<String?> adminSetPremium(String userId, String state) =>
    _adminCall('admin_set_premium', {'p_user': userId, 'p_state': state});

/// Bans or unbans. authBlocked is true when Supabase Auth itself now refuses
/// the account's sign-in (not only the app and RLS).
Future<({String? error, bool authBlocked})> adminSetBan(
    String userId, bool banned, String reason) async {
  if (!backendEnabled || _uid == null) {
    return (error: _adminSignedOut, authBlocked: false);
  }
  try {
    final r = await _sb.rpc('admin_set_ban',
        params: {'p_user': userId, 'p_banned': banned, 'p_reason': reason});
    return (error: null, authBlocked: r == true);
  } on PostgrestException catch (e) {
    return (error: e.message, authBlocked: false);
  } catch (_) {
    return (error: _adminOffline, authBlocked: false);
  }
}
