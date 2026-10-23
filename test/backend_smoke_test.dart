// Live smoke test for the Supabase backend. Skipped unless Supabase credentials
// are supplied, so the normal `flutter test` stays offline and green. Run it
// against a real project with:
//
//   flutter test test/backend_smoke_test.dart \
//     --dart-define-from-file=supabase.config.json
//
// It uses plain HTTP (no plugins) to exercise the REST + Auth API exactly as the
// app does: probe the tables, sign up a throwaway user, insert/read/delete that
// user's profile. It leaves one auth user behind (client can't delete those) —
// remove it in Supabase → Authentication → Users.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:habitrail/backend.dart' show backendEnabled;

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  test('live Supabase smoke test (needs --dart-define-from-file keys)',
      () async {
    if (!backendEnabled) {
      markTestSkipped('No SUPABASE_URL / SUPABASE_ANON_KEY — skipping live test.');
      return;
    }

    final base = _url.replaceAll(RegExp(r'/+$'), '');
    final anon = {'apikey': _key, 'Authorization': 'Bearer $_key'};
    final json = {'apikey': _key, 'Content-Type': 'application/json'};

    // 1. Is the profiles table there?
    final probe = await http.get(
        Uri.parse('$base/rest/v1/profiles?select=id&limit=1'),
        headers: anon);
    print('profiles probe → ${probe.statusCode}: ${probe.body}');
    expect(probe.statusCode == 200 || probe.statusCode == 206, isTrue,
        reason: 'profiles table unreachable (did the schema SQL run?).');

    // 2. Sign up a throwaway user.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final email = 'smoke$stamp@mailinator.com';
    final uname = 'smoke$stamp';
    final signup = await http.post(
      Uri.parse('$base/auth/v1/signup'),
      headers: json,
      body: jsonEncode({
        'email': email,
        'password': 'secret123',
        'data': {'username': uname, 'name': uname},
      }),
    );
    print('signup → ${signup.statusCode}: ${signup.body}');
    final sj = jsonDecode(signup.body) as Map<String, dynamic>;
    final token = sj['access_token'] as String?;
    expect(token, isNotNull,
        reason:
            'No session returned — turn OFF "Confirm email" in Auth settings.');
    final uid = (sj['user']?['id'] ?? sj['id']) as String?;
    expect(uid, isNotNull, reason: 'No user id in signup response.');

    final authed = {
      'apikey': _key,
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
    };

    // 3. Insert this user's profile (exercises the RLS insert policy).
    final ins = await http.post(
      Uri.parse('$base/rest/v1/profiles'),
      headers: authed,
      body: jsonEncode({'id': uid, 'username': uname, 'name': uname}),
    );
    print('profile insert → ${ins.statusCode}: ${ins.body}');
    expect(ins.statusCode == 200 || ins.statusCode == 201, isTrue,
        reason: 'profile insert failed: ${ins.body}');

    // 4. Read it back.
    final got = await http.get(
      Uri.parse('$base/rest/v1/profiles?id=eq.$uid&select=*'),
      headers: {'apikey': _key, 'Authorization': 'Bearer $token'},
    );
    print('readback → ${got.statusCode}: ${got.body}');
    expect(got.body.contains(uname), isTrue);

    // 5. Clean up the profile row.
    final del = await http.delete(
      Uri.parse('$base/rest/v1/profiles?id=eq.$uid'),
      headers: {'apikey': _key, 'Authorization': 'Bearer $token'},
    );
    print('cleanup profile → ${del.statusCode}');
  });
}
