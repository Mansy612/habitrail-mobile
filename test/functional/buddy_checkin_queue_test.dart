// Offline buddy check-in syncing: a check-in is only "synced" after the server
// acknowledges it; otherwise it stays in a persistent, account-scoped pending
// queue and is retried (on activity, resume, or restart). Retries are
// idempotent (a day can't be counted twice) and never carry one account's
// activity to another. Driven with a mocked sender and a simulated clock — no
// real buddy activity.
import 'package:flutter_test/flutter_test.dart';

import 'package:habitrail/buddies.dart';
import 'package:habitrail/core.dart' show dateKey;

/// Mocked server sender. Toggle [online] to simulate connectivity; [serverDays]
/// is the server's record — a Set, so repeated sends / duplicate acks of the
/// same day can't double-count (mirrors `insert ... on conflict do nothing`).
class FakeSender {
  bool online = true;
  final List<List<String>> batches = []; // every batch we attempted to send
  final Set<String> serverDays = {}; // what the server actually recorded
  int acks = 0;

  Future<bool> send(List<String> days) async {
    batches.add(List.of(days));
    if (!online) return false; // offline → no acknowledgement
    serverDays.addAll(days); // idempotent union
    acks++;
    return true;
  }
}

void main() {
  final now = DateTime(2026, 1, 10, 9, 0);
  String day(int ago) =>
      dateKey(DateTime(now.year, now.month, now.day - ago));

  group('ack gating + retry', () {
    test('an offline check-in stays pending, then syncs on reconnect', () async {
      final q = CheckInQueue()..adoptOwner('A');
      final s = FakeSender()..online = false;

      expect(q.enqueueRecent({day(0)}, now), isTrue);
      expect(q.hasPending, isTrue);

      expect(await q.flush(s.send), isFalse, reason: 'offline → not acked');
      expect(q.hasPending, isTrue, reason: 'kept pending after failure');
      expect(q.synced, isEmpty, reason: 'not synced until acknowledged');

      s.online = true; // connectivity returns
      expect(await q.flush(s.send), isTrue);
      expect(q.hasPending, isFalse);
      expect(q.synced, contains(day(0)));
      expect(s.serverDays, contains(day(0)));
    });

    test('repeated failures keep retrying the same day with no loss', () async {
      final q = CheckInQueue()..adoptOwner('A');
      final s = FakeSender()..online = false;
      q.enqueueRecent({day(0)}, now);

      for (var i = 0; i < 3; i++) {
        expect(await q.flush(s.send), isFalse);
      }
      expect(q.pending, {day(0)});
      expect(q.synced, isEmpty);

      s.online = true;
      expect(await q.flush(s.send), isTrue);
      expect(q.pending, isEmpty);
      expect(q.synced, {day(0)});
      expect(s.serverDays, {day(0)});
    });

    test('restarting before a retry preserves the pending queue', () async {
      final q = CheckInQueue()..adoptOwner('A');
      final s = FakeSender()..online = false;
      q.enqueueRecent({day(0), day(1)}, now);
      await q.flush(s.send); // fails, stays pending
      final saved = q.toJson();

      // "Restart": a fresh queue restores from storage for the same account.
      final q2 = CheckInQueue();
      q2.loadJson(saved, 'A');
      expect(q2.pending, {day(0), day(1)});
      expect(q2.synced, isEmpty);

      s.online = true;
      expect(await q2.flush(s.send), isTrue);
      expect(q2.pending, isEmpty);
      expect(q2.synced, containsAll([day(0), day(1)]));
    });
  });

  group('idempotency', () {
    test('a synced day is never re-queued, and duplicate acks do not double-count',
        () async {
      final q = CheckInQueue()..adoptOwner('A');
      final s = FakeSender();
      q.enqueueRecent({day(0)}, now);
      expect(await q.flush(s.send), isTrue);
      expect(q.synced, {day(0)});

      // The same day coming back from activity must not re-queue.
      expect(q.enqueueRecent({day(0)}, now), isFalse);
      expect(q.hasPending, isFalse);
      expect(await q.flush(s.send), isFalse, reason: 'nothing to send');

      // Even forcing the same batch through twice leaves one server record.
      await s.send([day(0)]);
      await s.send([day(0)]);
      expect(s.serverDays, {day(0)});
    });

    test('only days within the recent window are queued', () async {
      final q = CheckInQueue(windowDays: 7)..adoptOwner('A');
      final added = q.enqueueRecent({day(0), day(3), day(10)}, now);
      expect(added, isTrue);
      expect(q.pending, {day(0), day(3)});
      expect(q.pending, isNot(contains(day(10))), reason: 'outside the window');
    });
  });

  group('account scoping', () {
    test('switching accounts drops the previous account\'s pending days',
        () async {
      final q = CheckInQueue()..adoptOwner('A');
      final s = FakeSender()..online = false;
      q.enqueueRecent({day(0)}, now); // A active, offline
      expect(q.pending, {day(0)});

      q.adoptOwner('B'); // account switch
      expect(q.owner, 'B');
      expect(q.pending, isEmpty, reason: "A's pending days are not B's");
      expect(q.synced, isEmpty);

      // B, now online, checks in on a different day.
      s.online = true;
      q.enqueueRecent({day(1)}, now);
      await q.flush(s.send);
      expect(s.serverDays, {day(1)});
      expect(s.serverDays, isNot(contains(day(0))), reason: "A's day never sent");
    });

    test('loading another account\'s stored queue starts empty', () {
      final aSaved = {
        'owner': 'A',
        'pending': [day(0)],
        'synced': [day(1)],
      };
      final q = CheckInQueue();
      q.loadJson(aSaved, 'B'); // B restoring, but the payload is A's
      expect(q.owner, 'B');
      expect(q.pending, isEmpty);
      expect(q.synced, isEmpty);

      // The owner matches → it restores.
      final q2 = CheckInQueue();
      q2.loadJson(aSaved, 'A');
      expect(q2.pending, {day(0)});
      expect(q2.synced, {day(1)});
    });
  });
}
