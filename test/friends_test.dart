import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:habitrail/friends.dart';

void main() {
  // The store persists to SharedPreferences; give each test a fresh store.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('load seeds sample friends on first run', () async {
    final s = FriendsStore();
    await s.load();
    expect(s.friends, isNotEmpty);
    expect(s.friends.every((f) => f.sample), isTrue);
  });

  test('addByUsername only resolves known directory users', () async {
    final s = FriendsStore();
    await s.load();
    final before = s.friends.length;

    // A known handle that isn't already seeded.
    expect(s.addByUsername('samski'), isNull);
    expect(s.friends.length, before + 1);

    expect(s.addByUsername('SamsKi'), isNotNull); // duplicate (case-insensitive)
    expect(s.addByUsername('no'), isNotNull); // invalid format
    // A random name is NOT a real user → rejected (the bug this guards against).
    expect(s.addByUsername('totallyrandom'), isNotNull);
    expect(s.friends.length, before + 1); // none of the above were added
  });

  test('suggestions exclude users already added', () async {
    final s = FriendsStore();
    await s.load();
    expect(s.suggestions().any((f) => f.username == 'kai'), isTrue);
    s.addByUsername('kai');
    expect(s.suggestions().any((f) => f.username == 'kai'), isFalse);
  });

  test('a friend\'s synthetic stats are deterministic from the username',
      () async {
    final s = FriendsStore();
    await s.load();
    s.addByUsername('zoe_runs');
    final first = s.friends.firstWhere((f) => f.username == 'zoe_runs');
    s.remove(first.id);
    s.addByUsername('zoe_runs');
    final second = s.friends.firstWhere((f) => f.username == 'zoe_runs');
    expect(second.totalXp, first.totalXp);
    expect(second.streak, first.streak);
    expect(second.borderId, first.borderId);
  });

  test('remove deletes a friend', () async {
    final s = FriendsStore();
    await s.load();
    s.addByUsername('ravi');
    final f = s.friends.firstWhere((x) => x.username == 'ravi');
    s.remove(f.id);
    expect(s.friends.any((x) => x.id == f.id), isFalse);
  });
}
