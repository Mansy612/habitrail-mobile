import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Accounts / authentication ────────────────────────────────────────────────
//
// The web app authenticates with Supabase (email sessions + profile sync). The
// mobile app mirrors that flow, but the backend is wired later: [AuthService]
// is the swap-in seam. Today a [StubAuthService] keeps accounts on the device
// so the whole Welcome → Sign up → Log in → Account flow is real and testable;
// later a `SupabaseAuthService implements AuthService` drops in with no UI
// changes. The stub is NOT secure storage — it exists only to exercise the UI.

enum AuthStatus { unknown, signedOut, signedIn }

class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.username,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String username; // unique handle (@username)
  final String name; // editable display name (starts as the username)
  final String createdAt; // ISO-8601

  Map<String, dynamic> toMap() => {
        'id': id,
        'email': email,
        'username': username,
        'name': name,
        'createdAt': createdAt,
      };

  factory AuthUser.fromMap(Map<String, dynamic> m) => AuthUser(
        id: (m['id'] ?? '').toString(),
        email: (m['email'] ?? '').toString(),
        username: (m['username'] ?? m['name'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        createdAt: (m['createdAt'] ?? '').toString(),
      );
}

class AuthResult {
  const AuthResult.ok(this.user) : error = null;
  const AuthResult.fail(this.error) : user = null;
  final AuthUser? user;
  final String? error;
  bool get ok => user != null;
}

bool isValidEmail(String email) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());

/// Usernames: 3–20 characters, letters/numbers/underscores only.
bool isValidUsername(String username) =>
    RegExp(r'^[a-zA-Z0-9_]{3,20}$').hasMatch(username.trim());

/// An email/password error message, or null when both look valid.
String? validateCredentials(String email, String password) {
  if (!isValidEmail(email)) return 'Enter a valid email address.';
  if (password.length < 6) return 'Password must be at least 6 characters.';
  return null;
}

/// Shown when a banned account tries to sign in (see lib/admin.dart).
const kSuspendedMessage = 'This account has been suspended.';

/// Shown when a password-reset code doesn't match (or has expired).
const kBadResetCode = 'That code is wrong or has expired.';

/// Reset codes are digits only; Supabase sends 6 by default (up to 10).
bool isValidResetCode(String code) => RegExp(r'^\d{6,10}$').hasMatch(code.trim());

/// The seam the real Supabase backend will implement later.
abstract class AuthService {
  /// true once a real cloud backend is wired (so the UI can hide the
  /// "local account" notices). The stub is false.
  bool get isRemote;
  Future<AuthResult> signUp(
      {required String email,
      required String password,
      required String username});
  Future<AuthResult> signIn({required String email, required String password});
  Future<void> signOut();
  Future<AuthUser?> currentUser();
  Future<void> updateName(String name);
  Future<void> deleteAccount();
  Future<bool> isUsernameAvailable(String username);

  /// Emails a one-time code for choosing a new password. Null on success —
  /// including when no account has that email, so nobody can probe for one.
  Future<String?> sendPasswordReset(String email);

  /// Checks the emailed [code], sets [newPassword] and signs the user in.
  Future<AuthResult> resetPassword(
      {required String email,
      required String code,
      required String newPassword});
}

/// On-device stand-in for Supabase auth. Accounts + the current session live in
/// shared_preferences. Passwords are only lightly obscured — this is a stub to
/// drive the UI, never a security boundary; the real backend never stores them.
class StubAuthService implements AuthService {
  static const _accountsKey = 'auth.accounts.v1'; // email -> account map
  static const _sessionKey = 'auth.session.v1'; // current email

  @override
  bool get isRemote => false;

  String _obscure(String pw) => base64Encode(utf8.encode('hx1:$pw'));
  String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<Map<String, dynamic>> _accounts(SharedPreferences p) async {
    final raw = p.getString(_accountsKey);
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
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
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final p = await SharedPreferences.getInstance();
    final accounts = await _accounts(p);
    final key = email.trim().toLowerCase();
    if (accounts.containsKey(key)) {
      return const AuthResult.fail('An account with this email already exists.');
    }
    final taken = accounts.values.any((a) =>
        a is Map &&
        (a['username'] ?? '').toString().toLowerCase() == uname.toLowerCase());
    if (taken) return const AuthResult.fail('That username is already taken.');
    final user = AuthUser(
      id: _newId(),
      email: key,
      username: uname,
      name: uname,
      createdAt: DateTime.now().toIso8601String(),
    );
    accounts[key] = {...user.toMap(), 'pw': _obscure(password)};
    await p.setString(_accountsKey, jsonEncode(accounts));
    await p.setString(_sessionKey, key);
    return AuthResult.ok(user);
  }

  @override
  Future<AuthResult> signIn(
      {required String email, required String password}) async {
    final err = validateCredentials(email, password);
    if (err != null) return AuthResult.fail(err);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final p = await SharedPreferences.getInstance();
    final accounts = await _accounts(p);
    final key = email.trim().toLowerCase();
    final acc = accounts[key];
    if (acc is! Map) {
      return const AuthResult.fail('No account found for this email.');
    }
    if ((acc['pw'] ?? '') != _obscure(password)) {
      return const AuthResult.fail('Incorrect password.');
    }
    await p.setString(_sessionKey, key);
    return AuthResult.ok(AuthUser.fromMap(acc.cast<String, dynamic>()));
  }

  @override
  Future<void> signOut() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_sessionKey);
  }

  @override
  Future<void> updateName(String name) async {
    final p = await SharedPreferences.getInstance();
    final key = p.getString(_sessionKey);
    if (key == null) return;
    final accounts = await _accounts(p);
    final acc = accounts[key];
    if (acc is Map) {
      acc['name'] = name.trim();
      accounts[key] = acc;
      await p.setString(_accountsKey, jsonEncode(accounts));
    }
  }

  @override
  Future<void> deleteAccount() async {
    final p = await SharedPreferences.getInstance();
    final key = p.getString(_sessionKey);
    if (key != null) {
      final accounts = await _accounts(p);
      accounts.remove(key);
      await p.setString(_accountsKey, jsonEncode(accounts));
    }
    await p.remove(_sessionKey);
  }

  @override
  Future<bool> isUsernameAvailable(String username) async {
    final u = username.trim().toLowerCase();
    if (u.isEmpty) return false;
    final p = await SharedPreferences.getInstance();
    final accounts = await _accounts(p);
    return !accounts.values.any((a) =>
        a is Map && (a['username'] ?? '').toString().toLowerCase() == u);
  }

  // There's no email on the device, so the stub keeps each code in memory;
  // tests read it from [lastResetCode].
  final Map<String, String> _resetCodes = {};
  @visibleForTesting
  String? lastResetCode;

  @override
  Future<String?> sendPasswordReset(String email) async {
    if (!isValidEmail(email)) return 'Enter a valid email address.';
    final key = email.trim().toLowerCase();
    final p = await SharedPreferences.getInstance();
    if ((await _accounts(p)).containsKey(key)) {
      final code = (Random.secure().nextInt(900000) + 100000).toString();
      _resetCodes[key] = code;
      lastResetCode = code;
    }
    return null;
  }

  @override
  Future<AuthResult> resetPassword(
      {required String email,
      required String code,
      required String newPassword}) async {
    final err = validateCredentials(email, newPassword);
    if (err != null) return AuthResult.fail(err);
    final key = email.trim().toLowerCase();
    if (_resetCodes[key] == null || _resetCodes[key] != code.trim()) {
      return const AuthResult.fail(kBadResetCode);
    }
    _resetCodes.remove(key); // single use
    final p = await SharedPreferences.getInstance();
    final accounts = await _accounts(p);
    final acc = accounts[key];
    if (acc is! Map) return const AuthResult.fail(kBadResetCode);
    acc['pw'] = _obscure(newPassword);
    accounts[key] = acc;
    await p.setString(_accountsKey, jsonEncode(accounts));
    await p.setString(_sessionKey, key);
    return AuthResult.ok(AuthUser.fromMap(acc.cast<String, dynamic>()));
  }

  @override
  Future<AuthUser?> currentUser() async {
    final p = await SharedPreferences.getInstance();
    final key = p.getString(_sessionKey);
    if (key == null || key.isEmpty) return null;
    final acc = (await _accounts(p))[key];
    return acc is Map ? AuthUser.fromMap(acc.cast<String, dynamic>()) : null;
  }
}

/// App-wide auth state. The UI listens to this; it delegates to an
/// [AuthService] so the backend can change without touching screens.
class Auth extends ChangeNotifier {
  Auth(this._service);
  AuthService _service;

  /// Swap the backing service at startup (e.g. the stub → Supabase).
  void useService(AuthService s) => _service = s;

  AuthStatus status = AuthStatus.unknown;
  AuthUser? user;
  bool busy = false;

  /// Wired by the app at startup (main.dart) so sign-out stays decoupled from
  /// the backend and app state. [onBeforeSignOut] runs while the session is
  /// still valid (flush a final cloud backup for the account); [onAfterSignOut]
  /// runs once signed out (wipe the device save so the next account starts
  /// clean and can't inherit this one's data).
  Future<void> Function()? onBeforeSignOut;
  Future<void> Function()? onAfterSignOut;

  bool get isRemote => _service.isRemote;
  bool get isAuthed => status == AuthStatus.signedIn;

  Future<void> init() async {
    user = await _service.currentUser();
    status = user != null ? AuthStatus.signedIn : AuthStatus.signedOut;
    notifyListeners();
  }

  Future<String?> signUp(String username, String email, String password) => _run(
      () => _service.signUp(
          email: email, password: password, username: username));

  Future<String?> signIn(String email, String password) =>
      _run(() => _service.signIn(email: email, password: password));

  Future<String?> sendPasswordReset(String email) =>
      _service.sendPasswordReset(email);

  /// Sets a new password with the emailed code; signs in on success.
  Future<String?> resetPassword(String email, String code, String newPassword) =>
      _run(() => _service.resetPassword(
          email: email, code: code, newPassword: newPassword));

  /// Runs an auth call, updates state, returns null on success or the error.
  Future<String?> _run(Future<AuthResult> Function() call) async {
    busy = true;
    notifyListeners();
    final r = await call();
    if (r.ok) {
      user = r.user;
      status = AuthStatus.signedIn;
    }
    busy = false;
    notifyListeners();
    return r.error;
  }

  Future<void> signOut() async {
    try {
      await onBeforeSignOut?.call(); // flush this account's backup while authed
    } catch (_) {}
    await _service.signOut();
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
    try {
      await onAfterSignOut?.call(); // wipe the device save for the next account
    } catch (_) {}
  }

  Future<void> updateName(String name) async {
    await _service.updateName(name);
    final u = user;
    if (u != null) {
      user = AuthUser(
          id: u.id,
          email: u.email,
          username: u.username,
          name: name.trim(),
          createdAt: u.createdAt);
    }
    notifyListeners();
  }

  Future<void> deleteAccount() async {
    await _service.deleteAccount();
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
    // No pre-flush (the account is gone), but still wipe the device save so a
    // deleted account's data never lingers for the next person to sign in.
    try {
      await onAfterSignOut?.call();
    } catch (_) {}
  }

  Future<bool> isUsernameAvailable(String username) =>
      _service.isUsernameAvailable(username);

}

/// The single shared auth object. Swap [StubAuthService] for a Supabase-backed
/// service later and the rest of the app is unchanged.
final auth = Auth(StubAuthService());
