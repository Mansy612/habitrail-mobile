// Forgot password: Log in → "Forgot password?" → email a code → enter the
// code and a new password → signed in. Driven through the real screens with
// the on-device stub auth, which hands tests the code it would have emailed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/auth.dart';
import 'package:habitrail/core.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';

import '../support/app_fonts.dart';

final _nav = GlobalKey<NavigatorState>();

Future<void> _settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  expect(f, findsWidgets, reason: 'nothing to tap for $f');
  await t.tap(f.first, warnIfMissed: false);
  await _settle(t);
}

Finder _field(int i) => find.byType(TextField).at(i);

/// A signed-out app with one account (sam@example.com / oldpass1), on Log in.
Future<StubAuthService> _login(WidgetTester t) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.runAsync(loadAppFonts);
  SharedPreferences.setMockInitialValues({});
  final stub = StubAuthService();
  await t.runAsync(() async {
    await appState.load();
    await stub.signUp(
        email: 'sam@example.com', password: 'oldpass1', username: 'sam');
    await stub.signOut();
  });
  auth.useService(stub);
  auth.user = null;
  auth.status = AuthStatus.signedOut;
  await t.pumpWidget(MaterialApp(
    navigatorKey: _nav,
    theme: hrTheme(),
    home: const Scaffold(body: Center(child: Text('home'))),
  ));
  _nav.currentState!
      .push(MaterialPageRoute<void>(builder: (_) => const LoginScreen()));
  await _settle(t);
  return stub;
}

/// From Log in, open Forgot password and send a code to [email].
Future<void> _sendCode(WidgetTester t, String email) async {
  await _tap(t, find.text('Forgot password?'));
  await t.enterText(_field(0), email);
  await _tap(t, find.text('Send code'));
}

void main() {
  testWidgets('the link carries the typed email over', (t) async {
    await _login(t);
    await t.enterText(_field(0), 'sam@example.com');
    await _tap(t, find.text('Forgot password?'));
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    expect(find.text('Reset password'), findsOneWidget);
    expect(find.text('sam@example.com'), findsOneWidget);
  });

  testWidgets('a code and a new password sign you in', (t) async {
    final stub = await _login(t);
    await _sendCode(t, 'sam@example.com');
    expect(find.text('Check your email'), findsOneWidget);
    await t.enterText(_field(0), stub.lastResetCode!);
    await t.enterText(_field(1), 'newpass1');
    await _tap(t, find.text('Set new password'));
    expect(auth.status, AuthStatus.signedIn);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('Password updated'), findsOneWidget);
    // The new password is the one that works from now on.
    await t.runAsync(() async {
      await auth.signOut();
      expect(await auth.signIn('sam@example.com', 'oldpass1'), isNotNull);
      expect(await auth.signIn('sam@example.com', 'newpass1'), isNull);
    });
  });

  testWidgets('a wrong code shows an error and keeps you signed out', (t) async {
    await _login(t);
    await _sendCode(t, 'sam@example.com');
    await t.enterText(_field(0), '000000');
    await t.enterText(_field(1), 'newpass1');
    await _tap(t, find.text('Set new password'));
    expect(find.text(kBadResetCode), findsOneWidget);
    expect(auth.status, AuthStatus.signedOut);
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
  });

  testWidgets('a new code replaces the old one', (t) async {
    final stub = await _login(t);
    await _sendCode(t, 'sam@example.com');
    final first = stub.lastResetCode!;
    String second;
    do {
      await _tap(t, find.text("Didn't get it? Send a new code"));
      second = stub.lastResetCode!;
    } while (second == first); // codes are random; a repeat is astronomically rare
    expect(find.text('New code sent'), findsOneWidget);
    await t.enterText(_field(0), first);
    await t.enterText(_field(1), 'newpass1');
    await _tap(t, find.text('Set new password'));
    expect(find.text(kBadResetCode), findsOneWidget);
  });

  testWidgets('an unknown email gets the same reply as a real one', (t) async {
    final stub = await _login(t);
    await _sendCode(t, 'nobody@example.com');
    expect(find.text('Check your email'), findsOneWidget);
    expect(stub.lastResetCode, isNull);
  });

  testWidgets('a bad email is caught; you can switch email', (t) async {
    await _login(t);
    await _sendCode(t, 'not-an-email');
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    await t.enterText(_field(0), 'sam@example.com');
    await _tap(t, find.text('Send code'));
    await _tap(t, find.text('Use a different email'));
    expect(find.text('Reset password'), findsOneWidget);
  });
}
