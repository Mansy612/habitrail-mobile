// Notification replanning must preserve valid pending requests. The old
// scheduler excluded a reminder due within 5 s and then cancelled every pending
// request, so a reminder at 18:00 vanished when a replan ran at 17:59:57. These
// tests drive the pure `planReplan` diff with a simulated clock and a fake
// scheduler (the OS pending set), plus the stable-id scheme in planNotifications.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';

PlannedNotification _n(String payload, DateTime at, {int day = 0}) =>
    PlannedNotification(
      id: notifId(payload, day),
      at: at,
      title: 't',
      body: 'b',
      payload: payload,
    );

/// Mocked scheduler: the set of requests the OS holds, mutated exactly as
/// ReminderNotifications._apply would from a ReplanDecision.
class FakeOs {
  final Map<int, String> pending = {}; // id -> signature currently scheduled
  int scheduleCalls = 0;
  int cancelCalls = 0;

  /// One replan, mirroring _apply: diff, cancel the gone, schedule the changed,
  /// and adopt the decision's live map as the new belief. Returns that belief.
  Map<int, String> replan(
      Map<int, String> live, List<PlannedNotification> desired, DateTime now) {
    final d = planReplan(desired: desired, live: live, now: now);
    for (final id in d.toCancel) {
      pending.remove(id);
      cancelCalls++;
    }
    for (final p in d.toSchedule) {
      pending[p.id] = notifSig(p);
      scheduleCalls++;
    }
    return d.live;
  }
}

void main() {
  final day = DateTime(2026, 1, 1);
  DateTime at(int h, int m, [int s = 0]) =>
      DateTime(day.year, day.month, day.day, h, m, s);

  group('planReplan preserves valid requests', () {
    test('an imminent reminder (18:00) survives a replan at 17:59:57', () {
      final os = FakeOs();
      final r = _n('habit:h1', at(18, 0));
      var live = os.replan({}, [r], at(17, 0)); // scheduled far out
      expect(os.pending.keys, {r.id});
      expect(os.scheduleCalls, 1);

      // Routine replan 3 seconds before it fires — same plan.
      final before = {...os.pending};
      live = os.replan(live, [r], at(17, 59, 57));
      expect(os.pending, before, reason: 'the imminent request is untouched');
      expect(os.cancelCalls, 0, reason: 'nothing cancelled');
      expect(os.scheduleCalls, 1, reason: 'not rescheduled either');
      expect(live.keys, {r.id});
    });

    test('completing a habit cancels only its reminder', () {
      final os = FakeOs();
      final a = _n('habit:a', at(18, 0));
      final b = _n('habit:b', at(19, 0));
      var live = os.replan({}, [a, b], at(9, 0));
      expect(os.pending.keys, {a.id, b.id});
      expect(os.scheduleCalls, 2);

      live = os.replan(live, [b], at(9, 5)); // 'a' completed → dropped
      expect(os.pending.keys, {b.id});
      expect(os.cancelCalls, 1);
      expect(os.scheduleCalls, 2, reason: 'b was left alone, not rescheduled');
    });

    test('changing a reminder time reschedules the same id, no duplicate', () {
      final os = FakeOs();
      final a0 = _n('habit:a', at(18, 0));
      var live = os.replan({}, [a0], at(9, 0));
      final a1 = _n('habit:a', at(19, 0)); // same habit → same id, new time

      live = os.replan(live, [a1], at(9, 5));
      expect(os.pending.length, 1, reason: 'one request, not a duplicate');
      expect(os.pending.keys, {a0.id});
      expect(os.pending[a0.id], notifSig(a1), reason: 'updated to the new time');
      expect(a0.id, a1.id);
    });

    test('disabling notifications cancels everything', () {
      final os = FakeOs();
      var live = os.replan(
          {}, [_n('habit:a', at(18, 0)), _n('habit:b', at(19, 0))], at(9, 0));
      expect(os.pending, isNotEmpty);

      live = os.replan(live, const [], at(9, 5)); // disabled → empty plan
      expect(os.pending, isEmpty);
      expect(live, isEmpty);
    });

    test('a brand-new reminder due within 5 s is not scheduled (and nothing breaks)',
        () {
      final os = FakeOs();
      final soon = _n('habit:s', at(12, 0, 3)); // 3 s away, never scheduled
      final live = os.replan({}, [soon], at(12, 0, 0));
      expect(os.pending, isEmpty, reason: 'too soon to schedule reliably');
      expect(live, isEmpty);
    });

    test('respects the OS pending cap, keeping the soonest', () {
      final desired = [
        for (var i = 0; i < 100; i++)
          _n('habit:h$i', at(0, 0).add(Duration(minutes: 30 + i)))
      ];
      final d = planReplan(
          desired: desired, live: {}, now: at(0, 0), maxPending: 60);
      expect(d.toSchedule.length, 60);
      expect(d.live.length, 60);
      final latest =
          d.toSchedule.map((p) => p.at).reduce((a, b) => a.isAfter(b) ? a : b);
      expect(latest, at(0, 0).add(const Duration(minutes: 30 + 59)));
    });

    test('a restart (seeded from the OS) cancels leftovers and keeps survivors',
        () {
      // The OS still holds two requests after a restart; we seed their ids with
      // an unknown signature, then reconcile against the new plan.
      final survivor = _n('habit:a', at(18, 0));
      final leftover = _n('habit:gone', at(20, 0));
      final seeded = {survivor.id: '\u0000seed', leftover.id: '\u0000seed'};

      final d = planReplan(desired: [survivor], live: seeded, now: at(9, 0));
      expect(d.toCancel, [leftover.id], reason: 'the removed one is cancelled');
      expect(d.toSchedule.map((p) => p.id), [survivor.id],
          reason: 'the survivor is re-asserted under its stable id');
      expect(d.live.keys, {survivor.id});
    });
  });

  group('stable notification ids', () {
    test('notifId is deterministic and distinct per reminder/day', () {
      expect(notifId('habit:x', 0), notifId('habit:x', 0));
      expect(notifId('habit:x', 0), isNot(notifId('habit:y', 0)));
      expect(notifId('habit:x', 0), isNot(notifId('habit:x', 1)));
      expect(notifId('streak', 0), isNot(notifId('habit:x', 0)));
      expect(notifId('habit:x', 0), greaterThanOrEqualTo(0));
    });

    test('a habit keeps its reminder id when another habit is removed', () async {
      SharedPreferences.setMockInitialValues({});
      await appState.load();
      appState.resetAll();
      final now = DateTime(2026, 6, 1, 8, 0, 0);
      appState.addHabit('A', 'common', reminderMinutes: 18 * 60);
      appState.addHabit('B', 'common', reminderMinutes: 19 * 60);
      final a = appState.habits.firstWhere((h) => h.name == 'A');
      final b = appState.habits.firstWhere((h) => h.name == 'B');

      final id1 = planNotifications(appState, now)
          .firstWhere((p) => p.habitId == a.id)
          .id;
      appState.deleteHabit(b); // with sequential ids this would shift A's id
      final id2 = planNotifications(appState, now)
          .firstWhere((p) => p.habitId == a.id)
          .id;

      expect(id2, id1);
      expect(id1, notifId('habit:${a.id}', 0));
    });
  });
}
