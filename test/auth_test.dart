import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/auth.dart';

void main() {
  // Auth reads/writes SharedPreferences; give every test a fresh mock store.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('credential validation', () {
    test('email format', () {
      expect(isValidEmail('a@b.com'), isTrue);
      expect(isValidEmail('nope'), isFalse);
      expect(isValidEmail('a b@c.com'), isFalse);
    });
    test('username format', () {
      expect(isValidUsername('sam_92'), isTrue);
      expect(isValidUsername('ab'), isFalse); // too short
      expect(isValidUsername('has space'), isFalse);
      expect(isValidUsername('bad!'), isFalse);
      expect(isValidUsername('a' * 21), isFalse); // too long
    });
    test('email/password rules flag bad input', () {
      expect(validateCredentials('a@b.com', '123456'), isNull);
      expect(validateCredentials('bad', '123456'), isNotNull);
      expect(validateCredentials('a@b.com', '123'), isNotNull);
    });
  });

  group('StubAuthService', () {
    test('sign up creates an account and a session', () async {
      final s = StubAuthService();
      final r = await s.signUp(
          email: 'Sam@Example.com', password: 'secret1', username: 'Sam_92');
      expect(r.ok, isTrue);
      expect(r.user!.email, 'sam@example.com'); // normalized to lowercase
      expect(r.user!.username, 'Sam_92');
      expect(r.user!.name, 'Sam_92'); // display name starts as the username
      expect(await s.currentUser(), isNotNull);
    });

    test('an invalid username is rejected', () async {
      final s = StubAuthService();
      final r =
          await s.signUp(email: 'a@b.com', password: 'secret1', username: 'no');
      expect(r.ok, isFalse);
      expect(r.error, contains('Username'));
    });

    test('duplicate email fails', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'userA');
      final r = await s.signUp(
          email: 'a@b.com', password: 'secret1', username: 'userB');
      expect(r.ok, isFalse);
      expect(r.error, contains('email'));
    });

    test('duplicate username fails (case-insensitive)', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'Taken');
      final r = await s.signUp(
          email: 'b@b.com', password: 'secret1', username: 'taken');
      expect(r.ok, isFalse);
      expect(r.error, contains('taken'));
    });

    test('sign in verifies the password', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'userA');
      await s.signOut();
      expect((await s.signIn(email: 'a@b.com', password: 'wrong')).ok, isFalse);
      final good = await s.signIn(email: 'a@b.com', password: 'secret1');
      expect(good.ok, isTrue);
      expect(good.user!.username, 'userA');
    });

    test('sign in fails for an unknown email', () async {
      final s = StubAuthService();
      final r = await s.signIn(email: 'ghost@b.com', password: 'secret1');
      expect(r.ok, isFalse);
      expect(r.error, contains('No account'));
    });

    test('sign out clears the session', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'userA');
      await s.signOut();
      expect(await s.currentUser(), isNull);
    });

    test('updateName changes the display name but not the handle', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'userA');
      await s.updateName('Alice');
      final u = await s.currentUser();
      expect(u!.name, 'Alice');
      expect(u.username, 'userA'); // the unique handle is unchanged
    });

    test('deleteAccount removes the account and its session', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', username: 'userA');
      await s.deleteAccount();
      expect(await s.currentUser(), isNull);
      // The account record is gone, so a later sign-in fails.
      expect((await s.signIn(email: 'a@b.com', password: 'secret1')).ok, isFalse);
    });
  });

  group('Auth state', () {
    test('init resolves to signedOut with no session', () async {
      final a = Auth(StubAuthService());
      await a.init();
      expect(a.status, AuthStatus.signedOut);
      expect(a.isAuthed, isFalse);
    });

    test('sign up signs in, sign out signs out', () async {
      final a = Auth(StubAuthService());
      await a.init();
      final err = await a.signUp('userA', 'a@b.com', 'secret1');
      expect(err, isNull);
      expect(a.status, AuthStatus.signedIn);
      expect(a.user!.email, 'a@b.com');
      expect(a.user!.username, 'userA');
      await a.signOut();
      expect(a.status, AuthStatus.signedOut);
      expect(a.user, isNull);
    });

    test('a failed sign in surfaces the error and stays signed out', () async {
      final a = Auth(StubAuthService());
      await a.init();
      final err = await a.signIn('ghost@b.com', 'secret1');
      expect(err, isNotNull);
      expect(a.status, AuthStatus.signedOut);
    });

    test('guest mode persists across launches', () async {
      final a = Auth(StubAuthService());
      await a.init();
      await a.continueAsGuest();
      expect(a.guest, isTrue);
      final b = Auth(StubAuthService());
      await b.init();
      expect(b.guest, isTrue);
    });
  });
}
