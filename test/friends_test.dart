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

  test('addByUsername adds a friend, rejecting duplicates and bad input',
      () async {
    final s = FriendsStore();
    await s.load();
    final before = s.friends.length;

    expect(s.addByUsername('newpal'), isNull); // ok
    expect(s.friends.length, before + 1);

    expect(s.addByUsername('NewPal'), isNotNull); // duplicate, case-insensitive
    expect(s.addByUsername('no'), isNotNull); // too short
    expect(s.friends.length, before + 1); // neither was added
  });

  test('a friend\'s synthetic stats are deterministic from the username',
      () async {
    final s = FriendsStore();
    await s.load();
    s.addByUsername('deterministic');
    final first = s.friends.firstWhere((f) => f.username == 'deterministic');
    s.remove(first.id);
    s.addByUsername('deterministic');
    final second = s.friends.firstWhere((f) => f.username == 'deterministic');
    expect(second.totalXp, first.totalXp);
    expect(second.streak, first.streak);
    expect(second.borderId, first.borderId);
  });

  test('remove deletes a friend', () async {
    final s = FriendsStore();
    await s.load();
    s.addByUsername('tempmate');
    final f = s.friends.firstWhere((x) => x.username == 'tempmate');
    s.remove(f.id);
    expect(s.friends.any((x) => x.id == f.id), isFalse);
  });
}
