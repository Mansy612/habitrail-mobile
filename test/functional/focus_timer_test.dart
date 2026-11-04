// Focus timer: remaining time is derived from a wall-clock deadline (not a
// per-second tick), so it stays correct across backgrounding, lock, pause and
// app restart. A completed session grants its minutes + XP exactly once, even
// when the deadline passes while the app is away. Time is simulated via the
// injectable `appState.focusNow` clock — no real timers, no flakiness.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';

void main() {
  late DateTime now; // the simulated wall clock

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await appState.load();
    appState.resetAll();
    now = DateTime(2026, 1, 1, 12, 0, 0);
    appState.focusNow = () => now;
  });

  tearDown(() => appState.focusNow = DateTime.now);

  void advance(Duration d) => now = now.add(d); // phone away / backgrounded
  Future<void> flush() => appState.setSaveOwner(appState.saveOwnerId); // await a save

  group('remaining time comes from the deadline', () {
    test('elapsed real time counts even with no ticks', () {
      appState.startFocus(25);
      expect(appState.focusRemainingSeconds, 25 * 60);
      advance(const Duration(minutes: 10));
      expect(appState.focusRemainingSeconds, 15 * 60);
      expect(appState.reconcileFocus(), isNull); // not finished
    });

    test('custom durations are accurate end to end', () {
      appState.startFocus(90);
      expect(appState.focusRemainingSeconds, 90 * 60);
      advance(const Duration(minutes: 90));
      expect(appState.reconcileFocus(), 180); // 90 min * 2 XP
    });
  });

  group('completion is granted exactly once', () {
    test('a deadline reached while backgrounded completes once', () {
      appState.startFocus(25);
      final xp0 = appState.totalXp;
      final min0 = appState.focusMinutesToday;

      advance(const Duration(minutes: 25)); // finished while away
      expect(appState.focusRemainingSeconds, 0);

      final gain = appState.reconcileFocus();
      expect(gain, 50, reason: '25 min * 2 XP');
      expect(appState.focusMinutesToday, min0 + 25);
      expect(appState.totalXp, greaterThanOrEqualTo(xp0 + 50));
      expect(appState.focusSessionActive, isFalse, reason: 'session consumed');

      // Repeated resume events must not grant again.
      final xpAfter = appState.totalXp;
      final minAfter = appState.focusMinutesToday;
      expect(appState.reconcileFocus(), isNull);
      expect(appState.reconcileFocus(), isNull);
      expect(appState.totalXp, xpAfter);
      expect(appState.focusMinutesToday, minAfter);
    });

    test('repeated resume before the deadline never completes or drifts', () {
      appState.startFocus(50);
      advance(const Duration(minutes: 20));
      expect(appState.reconcileFocus(), isNull);
      expect(appState.reconcileFocus(), isNull); // repeated resume
      expect(appState.focusRemainingSeconds, 30 * 60);
    });
  });

  group('pause / resume / reset', () {
    test('pause freezes the remaining time; paused time is not counted', () {
      appState.startFocus(25);
      advance(const Duration(minutes: 5)); // 20 left
      appState.pauseFocus();
      expect(appState.focusPaused, isTrue);
      expect(appState.focusRemainingSeconds, 20 * 60);

      advance(const Duration(minutes: 100)); // long pause
      expect(appState.focusRemainingSeconds, 20 * 60, reason: 'frozen');
      expect(appState.reconcileFocus(), isNull, reason: 'paused never auto-completes');

      appState.resumeFocus();
      expect(appState.focusRunning, isTrue);
      expect(appState.focusRemainingSeconds, 20 * 60);
      advance(const Duration(minutes: 20));
      expect(appState.reconcileFocus(), 50); // the full 25-min session
    });

    test('reset abandons the session without granting anything', () {
      appState.startFocus(25);
      final xp0 = appState.totalXp;
      final min0 = appState.focusMinutesToday;
      advance(const Duration(minutes: 10));

      appState.resetFocus();
      expect(appState.focusSessionActive, isFalse);
      expect(appState.reconcileFocus(), isNull);
      expect(appState.totalXp, xp0);
      expect(appState.focusMinutesToday, min0);
    });
  });

  group('survives an app restart', () {
    test('a running session reloads deadline-accurate and still completes once',
        () async {
      appState.startFocus(25);
      advance(const Duration(minutes: 5));
      await flush(); // persist the session to (mock) storage

      // Simulate a restart: time passes while closed, then reload from storage.
      advance(const Duration(minutes: 3)); // 8 min elapsed total
      await appState.load();

      expect(appState.focusSessionActive, isTrue);
      expect(appState.focusRunning, isTrue);
      expect(appState.focusRemainingSeconds, (25 - 8) * 60,
          reason: 'remaining tracks the real deadline across restart');

      final min0 = appState.focusMinutesToday;
      advance(const Duration(minutes: 20)); // 28 > 25 → finished while away
      expect(appState.reconcileFocus(), 50);
      expect(appState.focusMinutesToday, min0 + 25);
      expect(appState.focusSessionActive, isFalse);
      expect(appState.reconcileFocus(), isNull); // not again
    });

    test('a paused session reloads still paused with its remaining intact',
        () async {
      appState.startFocus(50);
      advance(const Duration(minutes: 10)); // 40 left
      appState.pauseFocus();
      await flush();

      advance(const Duration(hours: 5)); // closed for a long time
      await appState.load();

      expect(appState.focusPaused, isTrue);
      expect(appState.focusRemainingSeconds, 40 * 60, reason: 'paused time frozen');
      expect(appState.reconcileFocus(), isNull);
    });
  });
}
