// Account deletion must report success ONLY after the backend confirms it, and
// must keep the user signed in on any failure (network, server rejection, or a
// missing deletion endpoint). No real account is ever touched: a fake
// AuthService stands in for the backend, and the status→message mapping is a
// pure function tested directly.
import 'package:flutter_test/flutter_test.dart';

import 'package:habitrail/auth.dart';
import 'package:habitrail/backend.dart' show deleteAccountError;

AuthUser _user() => const AuthUser(
      id: 'uid-1',
      email: 'a@b.com',
      username: 'userA',
      name: 'Alice',
      createdAt: '2026-01-01T00:00:00.000Z',
    );

/// Stand-in backend. [deleteResult] is exactly what `deleteAccount` returns:
/// null = the backend confirmed deletion; a string = a retryable failure.
class FakeAuthService implements AuthService {
  FakeAuthService({this.deleteResult});

  String? deleteResult;
  int deleteCalls = 0;
  int signOutCalls = 0;

  @override
  bool get isRemote => true;

  @override
  Future<String?> deleteAccount() async {
    deleteCalls++;
    return deleteResult;
  }

  @override
  Future<void> signOut() async => signOutCalls++;

  @override
  Future<AuthUser?> currentUser() async => _user();

  @override
  Future<AuthResult> signIn(
          {required String email, required String password}) async =>
      AuthResult.ok(_user());

  @override
  Future<AuthResult> signUp(
          {required String email,
          required String password,
          required String username}) async =>
      AuthResult.ok(_user());

  @override
  Future<AuthResult> resetPassword(
          {required String email,
          required String code,
          required String newPassword}) async =>
      AuthResult.ok(_user());

  @override
  Future<String?> sendPasswordReset(String email) async => null;

  @override
  Future<void> updateName(String name) async {}

  @override
  Future<bool> isUsernameAvailable(String username) async => true;
}

void main() {
  // A signed-in Auth over the fake, with a flag that records the device-wipe
  // hook (onAfterSignOut) so we can assert it fires only on success.
  Future<(Auth, FakeAuthService, List<bool>)> signedIn(
      {String? deleteResult}) async {
    final fake = FakeAuthService(deleteResult: deleteResult);
    final auth = Auth(fake);
    final wiped = <bool>[];
    auth.onAfterSignOut = () async => wiped.add(true);
    await auth.init(); // fake.currentUser → signed in
    expect(auth.status, AuthStatus.signedIn);
    return (auth, fake, wiped);
  }

  group('Auth.deleteAccount', () {
    test('success: signs out, wipes the device, returns null', () async {
      final (auth, _, wiped) = await signedIn(deleteResult: null);

      final err = await auth.deleteAccount();

      expect(err, isNull);
      expect(auth.status, AuthStatus.signedOut);
      expect(auth.user, isNull);
      expect(wiped, [true], reason: 'device save wiped on confirmed delete');
    });

    test('network failure: keeps the session, no wipe, returns the error',
        () async {
      final (auth, fake, wiped) = await signedIn(
          deleteResult:
              'Could not reach the server to delete your account. '
              'Check your connection and try again.');

      final err = await auth.deleteAccount();

      expect(err, isNotNull);
      expect(auth.status, AuthStatus.signedIn, reason: 'still signed in');
      expect(auth.user, isNotNull);
      expect(wiped, isEmpty, reason: 'device data must not be wiped on failure');
      expect(fake.deleteCalls, 1);
    });

    test('server rejection: keeps the session and returns the error', () async {
      final (auth, _, wiped) =
          await signedIn(deleteResult: deleteAccountError(500));

      final err = await auth.deleteAccount();

      expect(err, deleteAccountError(500));
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user, isNotNull);
      expect(wiped, isEmpty);
    });

    test('missing deletion endpoint (404): keeps the session, returns an error',
        () async {
      final (auth, _, wiped) =
          await signedIn(deleteResult: deleteAccountError(404));

      final err = await auth.deleteAccount();

      expect(err, deleteAccountError(404));
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user, isNotNull);
      expect(wiped, isEmpty);
    });

    test('a failed delete can be retried and then succeed', () async {
      final (auth, fake, wiped) =
          await signedIn(deleteResult: deleteAccountError(404));

      expect(await auth.deleteAccount(), isNotNull);
      expect(auth.status, AuthStatus.signedIn);

      fake.deleteResult = null; // endpoint now reachable / deployed
      final err = await auth.deleteAccount();

      expect(err, isNull);
      expect(auth.status, AuthStatus.signedOut);
      expect(wiped, [true]);
      expect(fake.deleteCalls, 2);
    });
  });

  group('deleteAccountError mapping', () {
    test('a missing endpoint (404) is retryable and distinct', () {
      final m = deleteAccountError(404);
      expect(m, isNotEmpty);
      expect(m.toLowerCase(), contains('try again'));
      expect(m, isNot(deleteAccountError(500)));
    });

    test('an expired session (401/403) tells the user to sign in again', () {
      expect(deleteAccountError(401).toLowerCase(), contains('sign in'));
      expect(deleteAccountError(403), deleteAccountError(401));
    });

    test('a server error names the status; an unknown status does not', () {
      expect(deleteAccountError(500), contains('500'));
      expect(deleteAccountError(null), isNot(contains('(error')));
      expect(deleteAccountError(null), isNotEmpty);
    });
  });
}
