// A backup that can't be saved must not look like it succeeded.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/backend.dart';
import 'package:habitrail/core.dart';

void main() {
  test('backupNow reports failure and leaves "last backed up" unset', () async {
    SharedPreferences.setMockInitialValues({});
    await appState.load();
    appState.startFreshForAccount('Tester');
    // No backend / no signed-in user in tests → nothing can be uploaded.
    expect(await backupNow(), isFalse);
    expect(appState.lastBackupAt, isEmpty);
  });
}
