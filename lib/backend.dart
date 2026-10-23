import 'package:supabase_flutter/supabase_flutter.dart' hide AuthUser;

import 'auth.dart';

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
      final profile = await _profile(u.id);
      return AuthResult.ok(_toAuthUser(u,
          username: profile?['username'] as String?,
          name: profile?['name'] as String?));
    } on AuthException catch (e) {
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
    final profile = await _profile(u.id);
    return _toAuthUser(u,
        username: profile?['username'] as String?,
        name: profile?['name'] as String?);
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
      // Removes the profile (friendships cascade). Fully deleting the auth user
      // needs a privileged call; see docs/SUPABASE_SETUP.md.
      try {
        await _sb.from('profiles').delete().eq('id', id);
      } catch (_) {}
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
