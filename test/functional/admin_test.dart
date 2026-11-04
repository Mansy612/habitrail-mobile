// Admin console: the admins-only Settings entry, the console screens driven
// against a fake server, and the app-side sync that applies what an admin did
// to this account. Enforcement itself lives in the SQL migration, so the last
// group checks that the migration keeps every admin RPC and every chat /
// party / guild write RPC guarded.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/admin.dart';
import 'package:habitrail/auth.dart';
import 'package:habitrail/core.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';
import 'package:habitrail/ui/hr_widgets.dart';

import '../support/app_fonts.dart';
import '../support/fake_admin.dart';

final _nav = GlobalKey<NavigatorState>();

Future<void> _settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  await appState.load();
  appState.startFreshForAccount('Tester');
  appState.cancelPremium();
  appState.aiEnabled = false;
  adminAccess.value = false;
}

/// A fresh app showing [home], with [api] as the server.
Future<FakeAdminApi> _app(WidgetTester t, Widget home, {FakeAdminApi? api}) async {
  t.view.physicalSize = const Size(390 * 2, 2400 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.runAsync(loadAppFonts);
  await t.runAsync(_fresh);
  final fake = api ?? FakeAdminApi();
  adminApi = fake;
  await t.pumpWidget(MaterialApp(navigatorKey: _nav, theme: hrTheme(), home: home));
  await _settle(t);
  return fake;
}

Future<void> _tap(WidgetTester t, Finder f) async {
  expect(f, findsWidgets, reason: 'nothing to tap for $f');
  await t.tap(f.first, warnIfMissed: false);
  await _settle(t);
}

Finder _field(String label) => find.widgetWithText(TextField, label);

HrButton _button(WidgetTester t, String label) =>
    t.widget<HrButton>(find.widgetWithText(HrButton, label));

/// Opens one account from the console list.
Future<FakeAdminApi> _openUser(WidgetTester t, String name,
    {FakeAdminApi? api}) async {
  final fake = await _app(t, const AdminScreen(), api: api);
  await _tap(t, find.text(name));
  expect(find.byType(AdminUserScreen), findsOneWidget);
  return fake;
}

/// Lets un-awaited saves land before a reload reads them back.
Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => adminApi = const SupabaseAdminApi());

  group('Settings entry', () {
    testWidgets('only admins see the Admin console row', (t) async {
      await _app(t, const AppSettingsScreen());
      expect(find.text('Admin console'), findsNothing);
      adminAccess.value = true;
      await _settle(t);
      expect(find.text('Admin console'), findsOneWidget);
      await _tap(t, find.text('Admin console'));
      expect(find.byType(AdminScreen), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
      // Losing admin access (sign-out / demotion) hides the row again.
      _nav.currentState!.pop();
      adminAccess.value = false;
      await _settle(t);
      expect(find.text('Admin console'), findsNothing);
    });
  });

  group('Console list', () {
    testWidgets('lists accounts with their coins, plan and ban state', (t) async {
      await _app(t, const AdminScreen());
      expect(find.text('Recently active'), findsOneWidget);
      for (final n in ['Maya', 'Leo', 'Noor', 'Sam', 'kai']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      expect(find.text('1,240'), findsOneWidget); // Maya's reported coins
      expect(find.text('—'), findsOneWidget); // Kai never reported a balance
      expect(find.text('Banned'), findsOneWidget); // Leo
      expect(find.text('Admin'), findsOneWidget); // Sam
      // Maya bought Premium, Noor was granted it.
      expect(find.text('Premium'), findsNWidgets(2));
    });

    testWidgets('search narrows by username, name or email', (t) async {
      await _app(t, const AdminScreen());
      await t.enterText(find.byType(TextField), 'leo');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await _settle(t);
      expect(find.text('1 result'), findsOneWidget);
      expect(find.text('Leo'), findsOneWidget);
      expect(find.text('Maya'), findsNothing);

      await t.enterText(find.byType(TextField), 'noor@example');
      await _tap(t, find.byTooltip('Search'));
      expect(find.text('Noor'), findsOneWidget);

      await t.enterText(find.byType(TextField), 'zzz');
      await _tap(t, find.byTooltip('Search'));
      expect(find.text('No accounts match "zzz".'), findsOneWidget);
    });

    testWidgets("a non-admin sees the server's refusal, not data", (t) async {
      await _app(t, const AdminScreen(), api: FakeAdminApi()..failWith = 'admins only');
      expect(find.text('admins only'), findsOneWidget);
      expect(find.text('Maya'), findsNothing);
    });
  });

  group('Account actions', () {
    testWidgets('give and take coins records ledger entries', (t) async {
      final fake = await _openUser(t, 'Maya');
      await t.enterText(_field('Amount'), '250');
      await t.enterText(_field('Note (optional)'), 'Contest prize');
      await _tap(t, find.text('Give'));
      expect(fake.coinCalls, [('u-maya', 250, 'Contest prize')]);
      expect(find.text('+250 waiting to apply'), findsOneWidget);
      expect(find.text('Gave 250 coins to @maya_runs'), findsOneWidget);

      await t.enterText(_field('Amount'), '100');
      await _tap(t, find.text('Take'));
      expect(fake.coinCalls.last, ('u-maya', -100, ''));
      expect(find.text('+150 waiting to apply'), findsOneWidget);

      // Taking more than was given shows a pending deduction.
      await t.enterText(_field('Amount'), '400');
      await _tap(t, find.text('Take'));
      expect(find.text('−250 waiting to apply'), findsOneWidget);
    });

    testWidgets('an empty amount does nothing', (t) async {
      final fake = await _openUser(t, 'Maya');
      await _tap(t, find.text('Give'));
      expect(fake.coinCalls, isEmpty);
      expect(find.text('Enter how many coins first.'), findsOneWidget);
    });

    testWidgets('grant, revoke and hand Premium back to the device', (t) async {
      final fake = await _openUser(t, 'kai');
      expect(find.widgetWithText(HrStatTile, 'Free'), findsOneWidget);
      await _tap(t, find.text('Granted'));
      expect(fake.premiumCalls, [('u-kai', 'grant')]);
      expect(find.widgetWithText(HrStatTile, 'Premium'), findsOneWidget);
      expect(find.text("Premium is on for them, whatever they've bought."),
          findsOneWidget);

      await _tap(t, find.text('Revoked'));
      expect(fake.premiumCalls.last, ('u-kai', 'revoke'));
      expect(find.widgetWithText(HrStatTile, 'Free'), findsOneWidget);

      await _tap(t, find.text('Device'));
      expect(fake.premiumCalls.last, ('u-kai', 'none'));
      expect(find.text('Their own purchase decides: Free right now.'),
          findsOneWidget);
    });

    testWidgets('ban asks first, then unban restores the account', (t) async {
      final fake = await _openUser(t, 'kai');
      await t.enterText(_field('Reason (optional)'), 'Spam');
      await _tap(t, find.widgetWithText(HrButton, 'Ban account'));
      expect(find.text('Ban @kai?'), findsOneWidget);
      // Cancel leaves the account alone.
      await _tap(t, find.text('Cancel'));
      expect(fake.banCalls, isEmpty);

      await _tap(t, find.widgetWithText(HrButton, 'Ban account'));
      await _tap(t, find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Ban account')));
      expect(fake.banCalls, [('u-kai', true, 'Spam')]);
      expect(find.text('Reason: Spam'), findsOneWidget);
      expect(find.text('Banned @kai'), findsOneWidget);

      await _tap(t, find.text('Unban account'));
      expect(fake.banCalls.last, ('u-kai', false, ''));
      expect(find.widgetWithText(HrStatTile, 'Active'), findsOneWidget);
    });

    testWidgets('says so when only the app can block sign-in', (t) async {
      await _openUser(t, 'kai', api: FakeAdminApi()..authBlocks = false);
      await _tap(t, find.widgetWithText(HrButton, 'Ban account'));
      await _tap(t, find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Ban account')));
      expect(find.text('Banned @kai (sign-in blocked by the app only)'),
          findsOneWidget);
    });

    testWidgets("admins can't be banned", (t) async {
      await _openUser(t, 'Sam');
      expect(find.text("Admins can't be banned. Remove their admin access first."),
          findsOneWidget);
      expect(_button(t, 'Ban account').onPressed, isNull);
    });

    testWidgets("your own account can't be banned", (t) async {
      await _openUser(t, 'Maya', api: FakeAdminApi(me: 'u-maya'));
      expect(find.text("You can't ban your own account."), findsOneWidget);
      expect(_button(t, 'Ban account').onPressed, isNull);
      expect(find.text('YOU'), findsOneWidget);
    });

    testWidgets('a refused action shows the error and changes nothing', (t) async {
      final fake = await _openUser(t, 'Maya');
      fake.failWith = 'admins only';
      await t.enterText(_field('Amount'), '10');
      await _tap(t, find.text('Give'));
      expect(fake.coinCalls, isEmpty);
      expect(find.text('admins only'), findsOneWidget);
      expect(find.textContaining('waiting to apply'), findsNothing);
    });
  });

  group('Account status sync', () {
    setUp(() async {
      await _fresh();
      appState.coins = 100;
    });

    test('applies coin adjustments and the Premium override, then acks', () async {
      final fake = adminApi = FakeAdminApi(
          status: const AccountStatus(
              isAdmin: true,
              premiumOverride: 'grant',
              coinGrants: [CoinGrant('g1', 300), CoinGrant('g2', -50)]));
      await syncAccountStatus();
      expect(appState.coins, 350);
      expect(appState.isPremium, isTrue);
      expect(appState.storeEntitlementActive, isFalse);
      expect(adminAccess.value, isTrue);
      expect(fake.acked, ['g1', 'g2']);
      expect(appState.appliedCoinGrants, isEmpty);
    });

    test('an adjustment applies once even if the ack fails', () async {
      final fake = adminApi = FakeAdminApi(
          status: const AccountStatus(coinGrants: [CoinGrant('g3', 200)]))
        ..ackOk = false;
      await syncAccountStatus();
      await syncAccountStatus(); // the server still lists it as pending
      expect(appState.coins, 300);
      expect(appState.appliedCoinGrants, {'g3'});

      fake.ackOk = true;
      await syncAccountStatus();
      expect(appState.coins, 300);
      expect(fake.acked, ['g3']);
      expect(appState.appliedCoinGrants, isEmpty);
    });

    test('the applied set survives a restart', () async {
      adminApi = FakeAdminApi(
          status: const AccountStatus(coinGrants: [CoinGrant('g4', 40)]))
        ..ackOk = false;
      await syncAccountStatus();
      await _flush();
      await appState.load();
      await syncAccountStatus();
      expect(appState.coins, 140);
    });

    test('taking coins never leaves a negative balance', () async {
      appState.coins = 30;
      adminApi = FakeAdminApi(
          status: const AccountStatus(coinGrants: [CoinGrant('g5', -100)]));
      await syncAccountStatus();
      expect(appState.coins, 0);
    });

    test('revoke beats a purchase and drops the Premium-only theme', () async {
      appState.activatePremium('annual');
      appState.setTheme(kPremiumThemeId);
      expect(appState.themeId, kPremiumThemeId);
      adminApi = FakeAdminApi(
          status: const AccountStatus(premiumOverride: 'revoke'));
      await syncAccountStatus();
      expect(appState.storeEntitlementActive, isTrue);
      expect(appState.isPremium, isFalse);
      expect(appState.themeId, isNot(kPremiumThemeId));

      // Clearing the override hands Premium back to the purchase.
      adminApi = FakeAdminApi(status: const AccountStatus());
      await syncAccountStatus();
      expect(appState.isPremium, isTrue);
    });

    test('the override is kept across restarts but not for a new account', () async {
      adminApi = FakeAdminApi(status: const AccountStatus(premiumOverride: 'grant'));
      await syncAccountStatus();
      await _flush();
      await appState.load();
      expect(appState.isPremium, isTrue);
      appState.startFreshForAccount('Someone else');
      expect(appState.isPremium, isFalse);
    });

    test('signing out drops admin access and the override', () async {
      adminApi = FakeAdminApi(
          status: const AccountStatus(isAdmin: true, premiumOverride: 'grant'));
      await syncAccountStatus();
      clearAccountStatus();
      expect(adminAccess.value, isFalse);
      expect(appState.isPremium, isFalse);
    });

    test('a banned account is signed out', () async {
      auth.status = AuthStatus.signedIn;
      adminAccess.value = true;
      adminApi = FakeAdminApi(
          status: const AccountStatus(
              banned: true, coinGrants: [CoinGrant('g6', 999)]));
      await syncAccountStatus();
      expect(auth.status, AuthStatus.signedOut);
      expect(adminAccess.value, isFalse);
      expect(appState.coins, 100); // nothing applied for a banned account
    });

    test('offline changes nothing', () async {
      appState.setPremiumOverride('grant');
      adminAccess.value = true;
      adminApi = FakeAdminApi(); // myStatus() → null
      expect(await syncAccountStatus(), isNull);
      expect(appState.isPremium, isTrue);
      expect(adminAccess.value, isTrue);
    });
  });

  group('Migration guards', () {
    final dir = Directory('supabase/migrations');
    final sql =
        File('${dir.path}/20261103000000_admin_console.sql').readAsStringSync();
    final fnRe = RegExp(
        r'create or replace function public\.(\w+)\s*\(([^)]*)\)(.*?)\$\$;',
        dotAll: true);
    final fns = {for (final m in fnRe.allMatches(sql)) m[1]!: m[0]!};
    String params(String def) => fnRe
        .firstMatch(def)![2]!
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    test('every admin RPC checks the caller is an admin', () {
      final admin = fns.keys.where((n) => n.startsWith('admin_')).toList();
      expect(admin, containsAll(['admin_search_users', 'admin_adjust_coins',
          'admin_set_premium', 'admin_set_ban']));
      for (final n in admin) {
        expect(fns[n], contains('perform public.assert_admin();'), reason: n);
        expect(fns[n], contains('security definer'), reason: n);
        expect(sql, contains('revoke execute on function public.$n('),
            reason: '$n must not be callable by anon');
      }
    });

    test('chat, party and guild writes refuse banned accounts', () {
      const writes = [
        'create_party', 'join_party', 'set_party_goal', 'set_party_quest',
        'send_party_message', 'create_guild', 'join_guild', 'set_guild_goal',
        'send_guild_message', 'send_global_message',
      ];
      for (final n in writes) {
        expect(fns[n], isNotNull, reason: '$n is not re-created');
        expect(fns[n], contains('perform public.assert_not_banned();'), reason: n);
      }
      for (final t in ['party_messages', 'guild_messages', 'global_messages',
          'parties', 'party_members', 'guilds', 'guild_members']) {
        expect(sql, contains("'$t'"), reason: '$t has no ban policy');
      }
    });

    test('re-created RPCs keep their existing signatures', () {
      // create or replace only replaces a function with the same parameter
      // names and types; anything else would add an unguarded overload.
      final earlier = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql') && !f.path.contains('admin_console'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final latest = <String, String>{};
      for (final f in earlier) {
        for (final m in fnRe.allMatches(f.readAsStringSync())) {
          latest[m[1]!] = m[0]!;
        }
      }
      final recreated = fns.keys.where(latest.containsKey).toList();
      expect(recreated.length, greaterThanOrEqualTo(10));
      for (final n in recreated) {
        expect(params(fns[n]!), params(latest[n]!), reason: n);
      }
    });

    test('every new table has RLS on, and nobody is made admin', () {
      final tables = RegExp(r'create table if not exists public\.(\w+)')
          .allMatches(sql)
          .map((m) => m[1]!);
      for (final t in tables) {
        expect(sql, contains('alter table public.$t enable row level security;'),
            reason: t);
      }
      expect(sql.contains(RegExp(r'insert into (public\.)?admins')), isFalse);
      expect(sql.contains(RegExp(r'create policy[^;]*on public\.admins')),
          isFalse, reason: 'admins must have no client-facing policy');
    });
  });
}
