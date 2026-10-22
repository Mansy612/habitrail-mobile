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
    test('rules flag bad input', () {
      expect(validateCredentials('a@b.com', '123456'), isNull);
      expect(validateCredentials('bad', '123456'), isNotNull);
      expect(validateCredentials('a@b.com', '123'), isNotNull);
      expect(validateCredentials('a@b.com', '123456', name: '  '), isNotNull);
    });
  });

  group('StubAuthService', () {
    test('sign up creates an account and a session', () async {
      final s = StubAuthService();
      final r =
          await s.signUp(email: 'Sam@Example.com', password: 'secret1', name: 'Sam');
      expect(r.ok, isTrue);
      expect(r.user!.email, 'sam@example.com'); // normalized to lowercase
      expect(r.user!.name, 'Sam');
      expect(await s.currentUser(), isNotNull);
    });

    test('duplicate sign up fails', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
      final r = await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
      expect(r.ok, isFalse);
      expect(r.error, contains('already exists'));
    });

    test('sign in verifies the password', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
      await s.signOut();
      expect((await s.signIn(email: 'a@b.com', password: 'wrong')).ok, isFalse);
      final good = await s.signIn(email: 'a@b.com', password: 'secret1');
      expect(good.ok, isTrue);
      expect(good.user!.name, 'A');
    });

    test('sign in fails for an unknown email', () async {
      final s = StubAuthService();
      final r = await s.signIn(email: 'ghost@b.com', password: 'secret1');
      expect(r.ok, isFalse);
      expect(r.error, contains('No account'));
    });

    test('sign out clears the session', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
      await s.signOut();
      expect(await s.currentUser(), isNull);
    });

    test('updateName renames the current account', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
      await s.updateName('Alice');
      expect((await s.currentUser())!.name, 'Alice');
    });

    test('deleteAccount removes the account and its session', () async {
      final s = StubAuthService();
      await s.signUp(email: 'a@b.com', password: 'secret1', name: 'A');
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
      final err = await a.signUp('a@b.com', 'secret1', 'A');
      expect(err, isNull);
      expect(a.status, AuthStatus.signedIn);
      expect(a.user!.email, 'a@b.com');
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
