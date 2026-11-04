// Account separation: one account's data must never carry over to, be published
// as, or overwrite the cloud backup of another account on the same device.
//
// The Supabase backend is off in unit tests (no --dart-define creds), so the
// cloud is modelled by [FakeCloud], which mirrors backend.dart's uploadBackup /
// downloadBackup / backupNow / syncAfterSignIn — including the real owner guard
// (`appState.saveOwnerId == signed-in uid`). Every other call is the real
// AppState: adoptOwner, exportSave/importSave, clearForSignOut, migrate, etc.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';

const _journalKey = 'habitrail.journal.v1';

/// Stand-in for the `user_backups` table: uid -> the exported save payload.
class FakeCloud {
  final Map<String, Map<String, String>> rows = {};

  /// Mirrors backend.backupNow(): a save may only ever be written to its
  /// OWNER's row. If the on-device save belongs to someone else, skip — this is
  /// the guard that stops an account-switch window from overwriting a cloud row.
  Future<bool> backupNow(String signedInUid) async {
    if (appState.saveOwnerId != signedInUid) return false;
    rows[signedInUid] = await appState.exportSave();
    await appState.markBackedUp();
    return true;
  }

  /// Mirrors backend.syncAfterSignIn() (adoptOwner has already run): restore
  /// this account's cloud backup onto an empty device, else push the (now
  /// owned) local save up.
  Future<void> _syncAfterSignIn(String uid) async {
    final cloud = rows[uid];
    if (cloud != null && appState.localIsEmpty) {
      await appState.importSave(Map<String, dynamic>.from(cloud));
      await appState.setSaveOwner(uid);
    } else {
      await backupNow(uid);
    }
  }

  /// The full interactive sign-up path (main._submit): claim ownership, start
  /// fresh. A brand-new account has no cloud yet.
  Future<void> signUp(String uid, String name) async {
    appState.saveOwnerId = uid;
    appState.startFreshForAccount(name);
    await appState.setSaveOwner(uid); // persist
  }

  /// The full interactive sign-in path (main._afterSignIn): adopt the account,
  /// THEN sync with the cloud.
  Future<void> signIn(String uid, {String name = ''}) async {
    await appState.adoptOwner(uid, name: name);
    await _syncAfterSignIn(uid);
  }

  /// The sign-out path (auth.signOut hooks): flush a final backup for the
  /// account while it still owns the save, then wipe the device.
  Future<void> signOut(String uid) async {
    await backupNow(uid); // onBeforeSignOut
    await appState.clearForSignOut(); // onAfterSignOut
  }
}

void main() {
  late FakeCloud cloud;

  // A clean, empty, unowned device before each test.
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await appState.load();
    appState.resetAll();
    appState.saveOwnerId = '';
    await appState.setSaveOwner('');
    cloud = FakeCloud();
  });

  // Flush pending (fire-and-forget) saves to the prefs store before a backup
  // reads them back via exportSave.
  Future<void> persist() => appState.setSaveOwner(appState.saveOwnerId);

  bool hasJournal(String text) =>
      appState.reflections.any((r) => r.text == text);

  group('local data does not carry over between accounts', () {
    test('A → logout → B: B starts clean and never sees A\'s data', () async {
      // A signs up and builds real progress across every data type.
      await cloud.signUp('uid-A', 'Alice');
      appState.coins = 1000;
      appState.toggle(appState.habits.first); // habit streak + XP
      appState.addReflection('Alice ran 5k'); // journal
      appState.addFood('Eggs', 200, 20, 2, 14); // nutrition
      appState.buyTheme('tokyo'); // purchase
      await persist();
      final aXp = appState.totalXp;
      expect(aXp, greaterThan(0));
      expect(appState.ownsTheme('tokyo'), isTrue);

      await cloud.signOut('uid-A');
      // Device is wiped and unowned after sign-out.
      expect(appState.saveOwnerId, '');
      expect(appState.localIsEmpty, isTrue);

      // B (a brand-new account, no cloud) signs in on the SAME device.
      await cloud.signIn('uid-B', name: 'Bob');

      expect(appState.saveOwnerId, 'uid-B');
      expect(hasJournal('Alice ran 5k'), isFalse, reason: 'journal leaked');
      expect(appState.foodLog, isEmpty, reason: 'nutrition leaked');
      expect(appState.ownsTheme('tokyo'), isFalse, reason: 'purchase leaked');
      expect(appState.habits.every((h) => h.streak == 0), isTrue);
      expect(appState.totalXp, 0, reason: 'progress leaked');
    });

    test('returning to A restores A\'s own progress, not B\'s', () async {
      // A plays, backs up, logs out.
      await cloud.signUp('uid-A', 'Alice');
      appState.addReflection('Alice ran 5k');
      await persist();
      await cloud.signOut('uid-A');

      // B plays on the same device, backs up, logs out.
      await cloud.signIn('uid-B', name: 'Bob');
      appState.addReflection('Bob meditated');
      await persist();
      await cloud.signOut('uid-B');

      // A comes back on the same device.
      await cloud.signIn('uid-A', name: 'Alice');

      expect(appState.saveOwnerId, 'uid-A');
      expect(hasJournal('Alice ran 5k'), isTrue, reason: 'A not restored');
      expect(hasJournal('Bob meditated'), isFalse, reason: 'B leaked into A');
    });

    test('fresh device: signing into an existing account restores its backup',
        () async {
      // Build an existing cloud backup for A "from another device".
      await cloud.signUp('uid-A', 'Alice');
      appState.addReflection('Alice ran 5k');
      appState.toggle(appState.habits.first);
      await persist();
      await cloud.backupNow('uid-A');
      final aXp = appState.totalXp;

      // Now a genuinely fresh device: empty + unowned, but A's cloud exists.
      await appState.clearForSignOut();
      expect(appState.localIsEmpty, isTrue);

      await cloud.signIn('uid-A', name: 'Alice');

      expect(appState.saveOwnerId, 'uid-A');
      expect(hasJournal('Alice ran 5k'), isTrue);
      expect(appState.totalXp, aXp, reason: 'cloud progress not restored');
    });
  });

  group('one account cannot overwrite another\'s cloud backup', () {
    test('backupNow refuses when the device save belongs to another account',
        () async {
      appState.saveOwnerId = 'uid-A';
      await appState.setSaveOwner('uid-A');
      // B is "signed in" but the on-device save is still A's.
      expect(await cloud.backupNow('uid-B'), isFalse);
      expect(cloud.rows.containsKey('uid-B'), isFalse);
    });

    test('B signing in over A\'s data never pushes A\'s data into B\'s row',
        () async {
      // B already has a real cloud backup (made elsewhere).
      await cloud.signIn('uid-B', name: 'Bob');
      appState.addReflection('Bob meditated');
      await persist();
      await cloud.backupNow('uid-B');
      final bCloudBefore = Map<String, String>.of(cloud.rows['uid-B']!);

      // A's data is now on the device (no clean sign-out — stress the guard).
      await appState.clearForSignOut();
      appState.saveOwnerId = 'uid-A';
      await appState.setSaveOwner('uid-A');
      appState.addReflection('Alice ran 5k');
      await persist();

      // B signs in on A's device.
      await cloud.signIn('uid-B', name: 'Bob');

      expect(hasJournal('Bob meditated'), isTrue, reason: 'B not restored');
      expect(hasJournal('Alice ran 5k'), isFalse, reason: 'A leaked into B');
      expect(cloud.rows['uid-B'], bCloudBefore,
          reason: "A's data overwrote B's cloud backup");
    });

    test('a brand-new B\'s first backup contains B\'s data, never A\'s',
        () async {
      // A's data on the device, owner A. B is brand-new (no cloud).
      appState.saveOwnerId = 'uid-A';
      await appState.setSaveOwner('uid-A');
      appState.addReflection('Alice ran 5k');
      await persist();

      await cloud.signIn('uid-B', name: 'Bob'); // wipes A, backs up fresh as B

      expect(cloud.rows.containsKey('uid-B'), isTrue);
      final bJournal = cloud.rows['uid-B']![_journalKey] ?? '[]';
      expect(bJournal.contains('Alice ran 5k'), isFalse,
          reason: "A's journal reached B's cloud backup");
    });
  });

  group('migration preserves existing progress safely', () {
    test('a pre-stamping save is claimed by the signed-in user at launch',
        () async {
      // Legacy state: data present, owner never stamped ('').
      appState.addReflection('Legacy entry');
      appState.saveOwnerId = '';
      await appState.setSaveOwner('');
      expect(appState.saveOwnerId, '');

      await appState.migrateOwnerAtLaunch('uid-A'); // A is signed in at launch

      expect(appState.saveOwnerId, 'uid-A', reason: 'not claimed for A');
      expect(hasJournal('Legacy entry'), isTrue, reason: 'progress lost');
    });

    test('unattributed data (signed out at launch) is not adopted by the next account',
        () async {
      appState.addReflection('Orphan entry');
      appState.saveOwnerId = '';
      await appState.setSaveOwner('');

      await appState.migrateOwnerAtLaunch(null); // nobody signed in
      expect(appState.saveOwnerId, kUnknownOwner);

      // A later sign-in must NOT adopt the unattributed data.
      await cloud.signIn('uid-B', name: 'Bob');
      expect(hasJournal('Orphan entry'), isFalse);
      expect(appState.saveOwnerId, 'uid-B');
    });
  });
}
