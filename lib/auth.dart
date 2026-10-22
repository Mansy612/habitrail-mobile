import 'dart:convert';

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
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String name;
  final String createdAt; // ISO-8601

  Map<String, dynamic> toMap() =>
      {'id': id, 'email': email, 'name': name, 'createdAt': createdAt};

  factory AuthUser.fromMap(Map<String, dynamic> m) => AuthUser(
        id: (m['id'] ?? '').toString(),
        email: (m['email'] ?? '').toString(),
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

/// A password/credential error message, or null when the inputs look valid.
String? validateCredentials(String email, String password, {String? name}) {
  if (name != null && name.trim().isEmpty) return 'Enter your name.';
  if (!isValidEmail(email)) return 'Enter a valid email address.';
  if (password.length < 6) return 'Password must be at least 6 characters.';
  return null;
}

/// The seam the real Supabase backend will implement later.
abstract class AuthService {
  /// true once a real cloud backend is wired (so the UI can hide the
  /// "local account" notices). The stub is false.
  bool get isRemote;
  Future<AuthResult> signUp(
      {required String email, required String password, required String name});
  Future<AuthResult> signIn({required String email, required String password});
  Future<void> signOut();
  Future<AuthUser?> currentUser();
  Future<void> updateName(String name);
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
      required String name}) async {
    final err = validateCredentials(email, password, name: name);
    if (err != null) return AuthResult.fail(err);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final p = await SharedPreferences.getInstance();
    final accounts = await _accounts(p);
    final key = email.trim().toLowerCase();
    if (accounts.containsKey(key)) {
      return const AuthResult.fail('An account with this email already exists.');
    }
    final user = AuthUser(
      id: _newId(),
      email: key,
      name: name.trim(),
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
  final AuthService _service;
  static const _guestKey = 'auth.guest.v1';

  AuthStatus status = AuthStatus.unknown;
  AuthUser? user;
  bool guest = false; // "continue without an account"
  bool busy = false;

  bool get isRemote => _service.isRemote;
  bool get isAuthed => status == AuthStatus.signedIn;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    guest = p.getBool(_guestKey) ?? false;
    user = await _service.currentUser();
    status = user != null ? AuthStatus.signedIn : AuthStatus.signedOut;
    notifyListeners();
  }

  Future<String?> signUp(String email, String password, String name) =>
      _run(() => _service.signUp(email: email, password: password, name: name));

  Future<String?> signIn(String email, String password) =>
      _run(() => _service.signIn(email: email, password: password));

  /// Runs an auth call, updates state, returns null on success or the error.
  Future<String?> _run(Future<AuthResult> Function() call) async {
    busy = true;
    notifyListeners();
    final r = await call();
    if (r.ok) {
      user = r.user;
      status = AuthStatus.signedIn;
      await _setGuest(false);
    }
    busy = false;
    notifyListeners();
    return r.error;
  }

  Future<void> signOut() async {
    await _service.signOut();
    user = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  Future<void> updateName(String name) async {
    await _service.updateName(name);
    final u = user;
    if (u != null) {
      user = AuthUser(
          id: u.id, email: u.email, name: name.trim(), createdAt: u.createdAt);
    }
    notifyListeners();
  }

  Future<void> continueAsGuest() async {
    await _setGuest(true);
    notifyListeners();
  }

  Future<void> _setGuest(bool v) async {
    guest = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_guestKey, v);
  }
}

/// The single shared auth object. Swap [StubAuthService] for a Supabase-backed
/// service later and the rest of the app is unchanged.
final auth = Auth(StubAuthService());
